//
//  DataStore.swift
//  MonospaceNotes
//
//  TASK-02-DATA-STORE — owner OWN-DATA-STORE.
//
//  An owner-level service with three jobs:
//
//    1. Real UTF-8 note file reads (CON-DATA-NOTE-FILE).
//    2. Atomic saves: the buffer is written to a sibling file inside the
//       destination's OWN directory and that sibling replaces the destination with
//       rename(2). On any failure the destination bytes are unchanged and the
//       sibling is removed (CON-DATA-TEMPORARY-SAVE-FILE).
//    3. Typography and keybinding settings in UserDefaults under the versioned keys
//       `com.monospace.notes.settings.v1.*` (CON-DATA-TYPOGRAPHY-SETTINGS,
//       CON-DATA-KEYBINDING-SETTINGS).
//
//  Invariants honoured throughout this file:
//
//    * No network APIs and no third-party dependencies.
//    * No file I/O on the main actor. Every read and write records itself in the
//      injected `FileIOThreadRecorder` and performs its work on a detached task, so
//      a main-actor caller can never turn into a main-thread read or write.
//    * The document buffer (CON-DATA-OPEN-DOCUMENT-BUFFER) and the workspace folder
//      reference (CON-DATA-WORKSPACE-FOLDER-REFERENCE) are in-memory state; this
//      owner never writes them to disk and never stores them in `UserDefaults`.
//      `UserDefaults` holds the typography and keybinding settings and nothing else.
//    * Failures carry the note's file name and a short reason only: never note
//      contents and never a directory path.
//

import Darwin
import Foundation

final class DataStore: NoteFileAccess, SettingsStoring, @unchecked Sendable {

    // MARK: - Failures

    /// Every failure this owner reports. The associated `fileName` is the note's
    /// last path component (never a full path) and the `reason` is a short,
    /// content-free explanation.
    enum OperationError: Error, Equatable, Sendable, CustomStringConvertible {
        case readFailed(fileName: String, reason: String)
        case decodingFailed(fileName: String)
        case writeFailed(fileName: String, reason: String)
        case renameFailed(fileName: String, reason: String)
        case cleanupFailed(fileName: String, reason: String)
        case invalidTypography(String)
        case invalidKeybinding(String)

        var description: String {
            switch self {
            case .readFailed(let fileName, let reason):
                return "Could not read “\(fileName)”: \(reason)."
            case .decodingFailed(let fileName):
                return "Could not read “\(fileName)”: the file is not valid UTF-8 text."
            case .writeFailed(let fileName, let reason):
                return "Could not write “\(fileName)”: \(reason)."
            case .renameFailed(let fileName, let reason):
                return "Could not replace “\(fileName)”: \(reason)."
            case .cleanupFailed(let fileName, let reason):
                return "Could not clean up the temporary save file for “\(fileName)”: \(reason)."
            case .invalidTypography(let reason):
                return "Rejected typography settings: \(reason)."
            case .invalidKeybinding(let reason):
                return "Rejected keybinding settings: \(reason)."
            }
        }

        /// The short reason alone, without the operation phrasing, so callers can
        /// embed it in their own message.
        var failureReason: String {
            switch self {
            case .readFailed(_, let reason),
                 .writeFailed(_, let reason),
                 .renameFailed(_, let reason),
                 .cleanupFailed(_, let reason):
                return reason
            case .decodingFailed:
                return "the file is not valid UTF-8 text"
            case .invalidTypography(let reason), .invalidKeybinding(let reason):
                return reason
            }
        }
    }

    // MARK: - Versioned settings keys

    /// `com.monospace.notes.settings.v1.` — every persisted key is versioned.
    nonisolated static let settingsKeyPrefix: String = LockedIdentity.bundleIdentifier + ".settings.v1."
    nonisolated static let fontFamilyKey: String = DataStore.settingsKeyPrefix + "fontFamily"
    nonisolated static let pointSizeKey: String = DataStore.settingsKeyPrefix + "pointSize"
    nonisolated static let saveKeybindingKey: String = DataStore.settingsKeyPrefix + "saveKeybinding"

    /// Menlo at 13 points.
    nonisolated static let defaultFontFamily: String = "Menlo"
    nonisolated static let defaultPointSize: Double = 13

    /// Stored point sizes outside `(0, 512]` are rejected: `loadTypography()`
    /// reports the documented default and `storeTypography(_:)` throws.
    nonisolated static let maximumPointSize: Double = 512

    // MARK: - Dependencies

    private let defaults: UserDefaults
    private let recorder: FileIOThreadRecorder
    private let rename: @Sendable (String, String) throws -> Void

    nonisolated init(defaults: UserDefaults = .standard,
                     recorder: FileIOThreadRecorder = FileIOThreadRecorder(),
                     rename: @escaping @Sendable (String, String) throws -> Void = DataStore.posixRename) {
        self.defaults = defaults
        self.recorder = recorder
        self.rename = rename
    }

    // MARK: - NoteFileAccess: reads

    nonisolated func readUTF8(from url: URL) async throws -> String {
        // Cancellation branch: a cancelled operation performs no I/O at all, so the
        // last valid state (and the file on disk) stays exactly as it was.
        try Task.checkCancellation()
        return try await Self.performOffMain { [self] in
            try readUTF8Synchronously(from: url)
        }
    }

    /// Blocking read; always called off the main actor through `performOffMain`.
    private nonisolated func readUTF8Synchronously(from url: URL) throws -> String {
        // Every file I/O entry point is recorded where the work happens, so a
        // main-actor caller can never be mistaken for a main-thread reader.
        recorder.record()

        let fileName = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OperationError.readFailed(fileName: fileName, reason: Self.reason(for: error))
        }

        // A file that is not valid UTF-8 throws: this owner never fabricates text.
        guard let text = String(data: data, encoding: .utf8) else {
            throw OperationError.decodingFailed(fileName: fileName)
        }
        return text
    }

    // MARK: - NoteFileAccess: atomic saves

    nonisolated func writeAtomically(_ contents: String, to url: URL) async throws {
        // Cancellation branch: nothing is written, so the destination keeps its
        // bytes and no temporary sibling is created.
        try Task.checkCancellation()
        let encoded = Data(contents.utf8)
        try await Self.performOffMain { [self] in
            try writeSynchronously(encoded, to: url)
        }
    }

    /// Blocking write; always called off the main actor through `performOffMain`.
    ///
    /// The destination is only ever touched by `rename(2)`, which the injected
    /// `rename` closure performs, so a failure of either step leaves the
    /// destination bytes unchanged and removes the temporary sibling.
    private nonisolated func writeSynchronously(_ data: Data, to url: URL) throws {
        recorder.record()

        let fileName = url.lastPathComponent
        let temporaryURL = DataStore.temporarySiblingURL(for: url)

        // 1. Write the whole buffer to a sibling of the destination. Until the
        //    rename below, the destination itself is untouched.
        do {
            try data.write(to: temporaryURL)
        } catch {
            let reason = Self.reason(for: error)
            if let cleanupReason = removeTemporarySibling(at: temporaryURL) {
                throw OperationError.cleanupFailed(
                    fileName: fileName,
                    reason: "the temporary save file could not be written (\(reason)) and could not be removed (\(cleanupReason))"
                )
            }
            throw OperationError.writeFailed(fileName: fileName, reason: reason)
        }

        // 2. Replace the destination atomically. The closure is injectable so the
        //    rename-failure branch stays testable.
        do {
            try rename(temporaryURL.path, url.path)
        } catch {
            let reason = (error as? OperationError)?.failureReason ?? Self.reason(for: error)
            if let cleanupReason = removeTemporarySibling(at: temporaryURL) {
                throw OperationError.cleanupFailed(
                    fileName: fileName,
                    reason: "the destination could not be replaced (\(reason)) and the temporary save file could not be removed (\(cleanupReason))"
                )
            }
            throw OperationError.renameFailed(fileName: fileName, reason: reason)
        }
    }

    /// Removes the temporary sibling, returning a short reason when the cleanup
    /// itself failed (so a cleanup failure is reported honestly) and `nil` when the
    /// sibling is gone.
    private nonisolated func removeTemporarySibling(at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            return Self.reason(for: error)
        }
    }

    // MARK: - NoteFileAccess helpers

    /// `rename(2)`: atomically replaces `to` with `from`, creating the destination
    /// when it does not exist yet. Injectable through `init(defaults:recorder:rename:)`.
    nonisolated static func posixRename(_ from: String, _ to: String) throws {
        let result = from.withCString { fromPath in
            to.withCString { toPath in
                Darwin.rename(fromPath, toPath)
            }
        }
        guard result == 0 else {
            throw OperationError.renameFailed(
                fileName: URL(fileURLWithPath: to).lastPathComponent,
                reason: String(cString: strerror(errno))
            )
        }
    }

    /// A fresh temporary file URL in the SAME directory as `url`, so the rename
    /// never crosses a file system boundary. The name is unique per call, which
    /// keeps concurrent saves from colliding.
    nonisolated static func temporarySiblingURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let siblingName = ".\(url.lastPathComponent).mn-save-\(UUID().uuidString)"
        return directory.appendingPathComponent(siblingName)
    }

    // MARK: - SettingsStoring: typography

    nonisolated func loadTypography() -> TypographySettings {
        let family = DataStore.storedFontFamily(defaults.object(forKey: DataStore.fontFamilyKey))
            ?? DataStore.defaultFontFamily
        let pointSize = DataStore.storedPointSize(defaults.object(forKey: DataStore.pointSizeKey))
            ?? DataStore.defaultPointSize
        return TypographySettings(fontFamily: family, pointSize: pointSize)
    }

    nonisolated func storeTypography(_ settings: TypographySettings) throws {
        let family = settings.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !family.isEmpty else {
            throw OperationError.invalidTypography("the font family must not be empty")
        }
        guard DataStore.isStorablePointSize(settings.pointSize) else {
            throw OperationError.invalidTypography(
                "the point size must be a finite value greater than 0 and at most \(DataStore.maximumPointSize)"
            )
        }

        // Nothing is written until both values validated, so a rejected store leaves
        // the last valid stored values untouched.
        defaults.set(family, forKey: DataStore.fontFamilyKey)
        defaults.set(settings.pointSize, forKey: DataStore.pointSizeKey)
    }

    /// A stored font family, or `nil` when it is missing, not a string, or blank.
    nonisolated static func storedFontFamily(_ candidate: Any?) -> String? {
        guard let family = candidate as? String else { return nil }
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A stored point size, or `nil` when it is missing, non-numeric, non-finite,
    /// `<= 0`, or greater than `maximumPointSize`.
    nonisolated static func storedPointSize(_ candidate: Any?) -> Double? {
        guard let number = candidate as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value > 0, value <= DataStore.maximumPointSize else { return nil }
        return value
    }

    /// `true` when a point size can be stored at all.
    nonisolated static func isStorablePointSize(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value <= DataStore.maximumPointSize
    }

    // MARK: - SettingsStoring: keybindings

    nonisolated func loadKeybindings() -> KeybindingSettings {
        guard let blob = defaults.data(forKey: DataStore.saveKeybindingKey),
              let record = try? JSONDecoder().decode(KeybindingRecord.self, from: blob),
              let settings = record.keybindingSettings else {
            return .default
        }
        return settings
    }

    nonisolated func storeKeybindings(_ settings: KeybindingSettings) throws {
        if let reason = DataStore.invalidKeybindingReason(settings) {
            throw OperationError.invalidKeybinding(reason)
        }

        do {
            let blob = try JSONEncoder().encode(KeybindingRecord(settings))
            defaults.set(blob, forKey: DataStore.saveKeybindingKey)
        } catch {
            // The stored blob is left exactly as it was: the last valid state stands.
            throw OperationError.invalidKeybinding("the keybindings could not be encoded")
        }
    }

    /// A short reason when the keybindings are incomplete, `nil` when they are
    /// storable. An empty key can never be triggered, so it is rejected.
    nonisolated static func invalidKeybindingReason(_ settings: KeybindingSettings) -> String? {
        let bindings: [(name: String, binding: KeyBinding)] = [
            ("open", settings.open),
            ("save", settings.save),
            ("save as", settings.saveAs),
            ("search", settings.search),
            ("settings", settings.settings),
        ]
        for (name, binding) in bindings
        where binding.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "the \(name) keybinding has no key"
        }
        return nil
    }

    // MARK: - Off-main execution

    /// Runs blocking file work on a detached task, so no read or write can ever run
    /// on the caller's actor even when the caller is the main actor.
    private nonisolated static func performOffMain<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try work()
        }
        return try await task.value
    }

    // MARK: - Failure reasons

    /// A short, content-free and path-free reason for a failed file operation.
    private nonisolated static func reason(for error: Error) -> String {
        let nsError = error as NSError
        switch (nsError.domain, nsError.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError),
             (NSCocoaErrorDomain, NSFileReadNoSuchFileError),
             (NSPOSIXErrorDomain, Int(ENOENT)):
            return "the file does not exist"
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError),
             (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
             (NSPOSIXErrorDomain, Int(EACCES)),
             (NSPOSIXErrorDomain, Int(EPERM)):
            return "permission was denied"
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
             (NSPOSIXErrorDomain, Int(ENOSPC)):
            return "there was not enough space"
        case (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError),
             (NSPOSIXErrorDomain, Int(EROFS)):
            return "the volume is read-only"
        default:
            return "the file system reported \(nsError.domain) error \(nsError.code)"
        }
    }

    // MARK: - Encoded keybinding record

    /// Versioned representation of `KeybindingSettings` for the single
    /// `saveKeybindingKey` blob. Declared here so the shared types in
    /// `AppState.swift` stay untouched.
    struct KeybindingRecord: Codable, Equatable, Sendable {
        static let currentVersion: Int = 1

        struct Shortcut: Codable, Equatable, Sendable {
            var key: String
            var command: Bool
            var shift: Bool
            var option: Bool
            var control: Bool

            init(key: String, command: Bool, shift: Bool, option: Bool, control: Bool) {
                self.key = key
                self.command = command
                self.shift = shift
                self.option = option
                self.control = control
            }

            init(_ binding: KeyBinding) {
                self.init(
                    key: binding.key,
                    command: binding.command,
                    shift: binding.shift,
                    option: binding.option,
                    control: binding.control
                )
            }

            /// `nil` when the stored shortcut is incomplete (an empty key).
            var keyBinding: KeyBinding? {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return KeyBinding(
                    key: trimmed,
                    command: command,
                    shift: shift,
                    option: option,
                    control: control
                )
            }
        }

        var version: Int
        var openShortcut: Shortcut
        var saveShortcut: Shortcut
        var saveAsShortcut: Shortcut
        var searchShortcut: Shortcut
        var settingsShortcut: Shortcut

        init(version: Int = KeybindingRecord.currentVersion,
             openShortcut: Shortcut,
             saveShortcut: Shortcut,
             saveAsShortcut: Shortcut,
             searchShortcut: Shortcut,
             settingsShortcut: Shortcut) {
            self.version = version
            self.openShortcut = openShortcut
            self.saveShortcut = saveShortcut
            self.saveAsShortcut = saveAsShortcut
            self.searchShortcut = searchShortcut
            self.settingsShortcut = settingsShortcut
        }

        init(_ settings: KeybindingSettings) {
            self.init(
                openShortcut: Shortcut(settings.open),
                saveShortcut: Shortcut(settings.save),
                saveAsShortcut: Shortcut(settings.saveAs),
                searchShortcut: Shortcut(settings.search),
                settingsShortcut: Shortcut(settings.settings)
            )
        }

        /// `nil` when the record is incomplete or from an unknown version, in which
        /// case `loadKeybindings()` reports the documented defaults.
        var keybindingSettings: KeybindingSettings? {
            guard version == Self.currentVersion else { return nil }
            guard let open = openShortcut.keyBinding,
                  let save = saveShortcut.keyBinding,
                  let saveAs = saveAsShortcut.keyBinding,
                  let search = searchShortcut.keyBinding,
                  let settings = settingsShortcut.keyBinding else {
                return nil
            }
            return KeybindingSettings(
                open: open,
                save: save,
                saveAs: saveAs,
                search: search,
                settings: settings
            )
        }
    }
}
