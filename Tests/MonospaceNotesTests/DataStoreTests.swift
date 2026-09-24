//
//  DataStoreTests.swift
//  MonospaceNotesTests
//
//  TASK-02-DATA-STORE focused suite — owner OWN-DATA-STORE.
//
//  Covers CON-DATA-NOTE-FILE, CON-DATA-OPEN-DOCUMENT-BUFFER,
//  CON-DATA-TEMPORARY-SAVE-FILE, CON-DATA-TYPOGRAPHY-SETTINGS,
//  CON-DATA-KEYBINDING-SETTINGS, CON-DATA-WORKSPACE-FOLDER-REFERENCE and the
//  matching CON-PERSISTENCE-* contracts, against the real `DataStore` type and
//  real files in unique scratch directories.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import Foundation
import Testing

@testable import MonospaceNotes

// MARK: - File-scope fixtures (unique names: every test file compiles together)

/// `true` when the calling thread is the process' main thread. `Thread.isMainThread`
/// is unavailable from async contexts, which is exactly where this suite must assert it.
private func dataStoreTestIsOnMainThread() -> Bool {
    pthread_main_np() != 0
}

/// A real scratch directory under the system temporary location. Tests only: the
/// store under test never targets that location.
private func dataStoreTestScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("monospace-notes-datastore-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A dedicated, unique `UserDefaults` suite so no test can see another one's state.
private func dataStoreTestSuite() throws -> (name: String, defaults: UserDefaults) {
    let name = "com.monospace.notes.tests.datastore.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name), "A dedicated defaults suite is required")
    return (name, defaults)
}

private func dataStoreTestDiscardSuite(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
    // `removePersistentDomain` clears the values; drop the suite's preferences file
    // as well. macOS may recreate it as an empty plist when the preferences daemon
    // next flushes that domain, which is harmless: no stored values remain.
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
        .path
    if FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func dataStoreTestSetPermissions(_ permissions: Int, of url: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: permissions)],
        ofItemAtPath: url.path
    )
}

/// The text of the store's own source, for the structural placement proof.
private func dataStoreTestSourceText() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot.appendingPathComponent("Sources/MonospaceNotes/Platform/DataStore.swift")
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

/// Runs an operation that is expected to fail and returns the owner's typed error.
private func dataStoreTestOperationError(
    _ operation: @Sendable () async throws -> Void
) async -> DataStore.OperationError? {
    do {
        try await operation()
        Issue.record("Expected a DataStore.OperationError but the operation succeeded")
        return nil
    } catch let error as DataStore.OperationError {
        return error
    } catch {
        Issue.record("Unexpected error type: \(type(of: error))")
        return nil
    }
}

/// A raw value seeded into a defaults suite as if an older or hostile build wrote it.
enum DataStoreTestStoredValue: Sendable, CustomStringConvertible {
    case string(String)
    case number(Double)

    var description: String {
        switch self {
        case .string(let value): return "string \"\(value)\""
        case .number(let value): return "number \(value)"
        }
    }

    func apply(to defaults: UserDefaults, forKey key: String) {
        switch self {
        case .string(let value): defaults.set(value, forKey: key)
        case .number(let value): defaults.set(value, forKey: key)
        }
    }
}

/// A raw blob seeded under the versioned keybinding key.
enum DataStoreTestStoredBlob: Sendable, CustomStringConvertible {
    case rawData(Data)
    case text(String)
    case number(Int)
    case record(version: Int, saveKey: String)
    case truncatedJSON

    var description: String {
        switch self {
        case .rawData: return "raw bytes"
        case .text(let value): return "plain string \"\(value)\""
        case .number(let value): return "number \(value)"
        case .record(let version, let saveKey): return "record version \(version) save key \"\(saveKey)\""
        case .truncatedJSON: return "truncated JSON"
        }
    }

    func apply(to defaults: UserDefaults, forKey key: String) throws {
        switch self {
        case .rawData(let data):
            defaults.set(data, forKey: key)
        case .text(let value):
            defaults.set(value, forKey: key)
        case .number(let value):
            defaults.set(value, forKey: key)
        case .record(let version, let saveKey):
            let record = DataStore.KeybindingRecord(
                version: version,
                openShortcut: DataStore.KeybindingRecord.Shortcut(KeyBinding.open),
                saveShortcut: DataStore.KeybindingRecord.Shortcut(
                    KeyBinding(key: saveKey, command: true)
                ),
                saveAsShortcut: DataStore.KeybindingRecord.Shortcut(KeyBinding.saveAs),
                searchShortcut: DataStore.KeybindingRecord.Shortcut(KeyBinding.search),
                settingsShortcut: DataStore.KeybindingRecord.Shortcut(KeyBinding.settings)
            )
            defaults.set(try JSONEncoder().encode(record), forKey: key)
        case .truncatedJSON:
            let full = try JSONEncoder().encode(DataStore.KeybindingRecord(KeybindingSettings.default))
            defaults.set(full.prefix(full.count / 2), forKey: key)
        }
    }
}

/// Watches the destination directory at the exact moment the atomic save renames
/// its temporary sibling over the destination, then performs the real rename.
private final class DataStoreTestAtomicWriteProbe: @unchecked Sendable {
    struct Observation: Sendable {
        let destinationPath: String
        let renamedFromPath: String
        let temporaryBaseName: String
        let temporaryDirectoryPath: String
        let directoryEntriesDuringWrite: [String]
        let temporaryFileExistedDuringWrite: Bool
    }

    private let lock = NSLock()
    private var recorded: [Observation] = []
    private let performRename: @Sendable (String, String) throws -> Void

    init(performRename: @escaping @Sendable (String, String) throws -> Void = DataStore.posixRename) {
        self.performRename = performRename
    }

    var observations: [Observation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The seam handed to `DataStore(rename:)`.
    func rename(_ from: String, _ to: String) throws {
        let temporaryURL = URL(fileURLWithPath: from)
        let destinationURL = URL(fileURLWithPath: to)
        let directory = destinationURL.deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []

        let observation = Observation(
            destinationPath: destinationURL.path,
            renamedFromPath: temporaryURL.path,
            temporaryBaseName: temporaryURL.lastPathComponent,
            temporaryDirectoryPath: temporaryURL.deletingLastPathComponent().path,
            directoryEntriesDuringWrite: entries.sorted(),
            temporaryFileExistedDuringWrite: FileManager.default.fileExists(atPath: temporaryURL.path)
        )

        lock.lock()
        recorded.append(observation)
        lock.unlock()

        try performRename(from, to)
    }
}

/// Parks a task so a test can cancel it before it reaches the store.
private actor DataStoreTestCancellationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func park() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

// MARK: - Suite

@Suite("DataStore")
struct DataStoreTests {

    // MARK: - Reads (CON-DATA-NOTE-FILE, CON-PERSISTENCE-NOTE-FILE)

    @Test("A real UTF-8 note round trips through the same-directory temporary writer")
    func realUTF8RoundTrip() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let destination = scratch.appendingPathComponent("note.txt")
        let contents = "Úvod — 日本語のメモ — emoji 🅰\r\nsecond line\r\n"

        try await store.writeAtomically(contents, to: destination)

        let onDisk = try Data(contentsOf: destination)
        #expect(onDisk == Data(contents.utf8), "The destination holds exactly the UTF-8 bytes of the buffer")

        let readBack = try await store.readUTF8(from: destination)
        #expect(readBack == contents, "A real UTF-8 read returns exactly what was written")
        #expect(readBack.contains("\r\n"), "CRLF survives the round trip untouched")

        // An empty note round trips to an empty file.
        try await store.writeAtomically("", to: destination)
        #expect(try Data(contentsOf: destination).isEmpty)
        let emptyRead = try await store.readUTF8(from: destination)
        #expect(emptyRead.isEmpty)

        #expect(recorder.totalOperations == 4, "Two writes and two reads were recorded")
        #expect(recorder.mainThreadViolations == 0)
    }

    @Test("A missing file throws and never fabricates text")
    func missingFileThrows() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let missing = scratch.appendingPathComponent("missing.txt")

        let error = await dataStoreTestOperationError { _ = try await store.readUTF8(from: missing) }
        guard case .readFailed(let fileName, let reason)? = error else {
            Issue.record("Expected .readFailed, received \(String(describing: error))")
            return
        }
        #expect(fileName == "missing.txt", "The failure names the note")
        #expect(!reason.isEmpty)
        #expect(!reason.contains(scratch.path), "A failure never carries a directory path")
        #expect(!FileManager.default.fileExists(atPath: missing.path), "A failed read creates nothing")
        #expect(recorder.totalOperations == 1, "The failed read is still recorded")
        #expect(recorder.mainThreadViolations == 0)
    }

    @Test("A file that is not valid UTF-8 throws instead of decoding garbage")
    func invalidUTF8Throws() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let destination = scratch.appendingPathComponent("binary.txt")
        try Data([0xFF, 0xFE, 0x80, 0x81]).write(to: destination)

        let error = await dataStoreTestOperationError { _ = try await store.readUTF8(from: destination) }
        guard case .decodingFailed(let fileName)? = error else {
            Issue.record("Expected .decodingFailed, received \(String(describing: error))")
            return
        }
        #expect(fileName == "binary.txt")
    }

    @Test("A note larger than the read cap is refused instead of loaded")
    func oversizedNoteIsRefused() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let destination = scratch.appendingPathComponent("huge.txt")
        // A sparse file one byte over the cap: no large write is needed.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        try handle.truncate(atOffset: UInt64(DataStore.maximumNoteBytes) + 1)
        try handle.close()

        let error = await dataStoreTestOperationError { _ = try await store.readUTF8(from: destination) }
        guard case .readFailed(let fileName, let reason)? = error else {
            Issue.record("Expected .readFailed, received \(String(describing: error))")
            return
        }
        #expect(fileName == "huge.txt")
        #expect(reason.contains("larger"), "The refusal states the size limit")
    }

    // MARK: - Atomic saves (CON-DATA-TEMPORARY-SAVE-FILE, CON-PERSISTENCE-TEMPORARY-SAVE-FILE)

    @Test("A save writes exactly the contents and leaves no temporary file behind")
    func atomicSaveLeavesNoSibling() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let destination = scratch.appendingPathComponent("note.txt")

        try await store.writeAtomically("first contents", to: destination)

        #expect(try Data(contentsOf: destination) == Data("first contents".utf8))
        let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        #expect(entries.sorted() == ["note.txt"], "The directory holds the destination and nothing else")
        #expect(recorder.totalOperations == 1)
        #expect(recorder.mainThreadViolations == 0)
    }

    @Test("A save replaces an existing destination without leaving the old tail")
    func atomicSaveReplacesExistingDestination() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let destination = scratch.appendingPathComponent("note.txt")
        let original = String(repeating: "a longer original line\n", count: 200)
        try Data(original.utf8).write(to: destination)

        let replacement = "short"
        try await store.writeAtomically(replacement, to: destination)

        #expect(try Data(contentsOf: destination) == Data(replacement.utf8),
                "The destination holds exactly the new contents, with nothing left over")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["note.txt"])
    }

    @Test("One instance serves both protocol seams, as the composition root wires it")
    func storeServesBothProtocolSeams() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let noteFiles: any NoteFileAccess = store
        let settings: any SettingsStoring = store

        let destination = scratch.appendingPathComponent("note.txt")
        try await noteFiles.writeAtomically("through the seam", to: destination)
        let readBack = try await noteFiles.readUTF8(from: destination)
        #expect(readBack == "through the seam")

        let typography = TypographySettings(fontFamily: "Menlo", pointSize: 14)
        try settings.storeTypography(typography)
        #expect(settings.loadTypography() == typography)

        let keybindings = KeybindingSettings(save: KeyBinding(key: "k", command: true))
        try settings.storeKeybindings(keybindings)
        #expect(settings.loadKeybindings() == keybindings)

        #expect(recorder.totalOperations == 2, "Both seam calls are file I/O and both are recorded")
        #expect(recorder.mainThreadViolations == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["note.txt"])
    }

    @Test("The temporary URL is a unique sibling of the destination")
    func temporarySiblingIsASibling() {
        let destination = URL(fileURLWithPath: "/Users/example/Notes/note.txt")
        let first = DataStore.temporarySiblingURL(for: destination)
        let second = DataStore.temporarySiblingURL(for: destination)

        #expect(first.deletingLastPathComponent().path == destination.deletingLastPathComponent().path,
                "The temporary file lives in the destination's own directory")
        #expect(second.deletingLastPathComponent().path == destination.deletingLastPathComponent().path)
        #expect(first.lastPathComponent != destination.lastPathComponent)
        #expect(first != second, "Concurrent saves never collide on the same name")
        #expect(!first.path.hasPrefix("/tmp/"))
    }

    @Test("posixRename replaces a destination and fails honestly for a missing source")
    func posixRenameBehaviour() throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = scratch.appendingPathComponent("pending.txt")
        let destination = scratch.appendingPathComponent("note.txt")
        try Data("new bytes".utf8).write(to: source)
        try Data("original bytes".utf8).write(to: destination)

        try DataStore.posixRename(source.path, destination.path)

        #expect(try Data(contentsOf: destination) == Data("new bytes".utf8))
        #expect(!FileManager.default.fileExists(atPath: source.path), "rename(2) moves rather than copies")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["note.txt"])

        do {
            try DataStore.posixRename(scratch.appendingPathComponent("missing.txt").path, destination.path)
            Issue.record("Expected the rename of a missing source to fail")
        } catch let error as DataStore.OperationError {
            guard case .renameFailed(let fileName, let reason) = error else {
                Issue.record("Expected .renameFailed, received \(error)")
                return
            }
            #expect(fileName == "note.txt")
            #expect(!reason.isEmpty)
        }

        #expect(try Data(contentsOf: destination) == Data("new bytes".utf8),
                "A failed rename leaves the destination unchanged")
    }

    @Test("During a save the temporary file is a sibling in the destination's own directory")
    func temporaryFileIsASiblingDuringTheWrite() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let probe = DataStoreTestAtomicWriteProbe()
        let store = DataStore(
            defaults: defaults,
            recorder: recorder,
            rename: { from, to in try probe.rename(from, to) }
        )
        let destination = scratch.appendingPathComponent("note.txt")
        try Data("original".utf8).write(to: destination)

        try await store.writeAtomically("replacement contents", to: destination)

        let observation = try #require(probe.observations.first, "The probe ran once")
        #expect(probe.observations.count == 1)
        #expect(observation.destinationPath == destination.path)
        #expect(observation.renamedFromPath.hasSuffix(observation.temporaryBaseName),
                "The rename moved the temporary sibling, not some other file")
        #expect(observation.temporaryBaseName.contains("mn-save-"),
                "The temporary sibling is unmistakably this owner's save file")
        #expect(observation.temporaryDirectoryPath == scratch.standardizedFileURL.path,
                "The temporary file was created in the destination's own directory, never a shared temporary location")
        #expect(observation.directoryEntriesDuringWrite.contains(destination.lastPathComponent))
        #expect(observation.directoryEntriesDuringWrite.contains(observation.temporaryBaseName),
                "The directory listing during the write contains the temporary sibling")
        #expect(observation.directoryEntriesDuringWrite.count == 2,
                "Only the destination and its temporary sibling existed during the write")
        #expect(observation.temporaryFileExistedDuringWrite, "The temporary file existed before the rename")

        #expect(try Data(contentsOf: destination) == Data("replacement contents".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["note.txt"],
                "No temporary file is left behind")
    }

    @Test("A failed rename leaves the destination bytes unchanged and removes the temporary file")
    func renameFailureLeavesTheDestinationUntouched() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let destination = scratch.appendingPathComponent("note.txt")
        let original = Data("original bytes".utf8)
        try original.write(to: destination)

        let probe = DataStoreTestAtomicWriteProbe { _, _ in
            throw DataStore.OperationError.renameFailed(fileName: "note.txt", reason: "injected rename failure")
        }
        let store = DataStore(
            defaults: defaults,
            recorder: recorder,
            rename: { from, to in try probe.rename(from, to) }
        )

        let error = await dataStoreTestOperationError {
            try await store.writeAtomically("replacement", to: destination)
        }
        guard case .renameFailed(let fileName, let reason)? = error else {
            Issue.record("Expected .renameFailed, received \(String(describing: error))")
            return
        }
        #expect(fileName == "note.txt")
        #expect(reason == "injected rename failure")
        #expect(!(error?.description.contains(scratch.path) ?? false),
                "A failure never carries a directory path")

        #expect(try Data(contentsOf: destination) == original, "The destination bytes are unchanged")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["note.txt"],
                "The temporary file is removed")

        let observation = try #require(probe.observations.first)
        #expect(observation.temporaryFileExistedDuringWrite,
                "The temporary sibling really existed, in the destination's own directory")
        #expect(observation.temporaryDirectoryPath == scratch.standardizedFileURL.path)
        #expect(recorder.totalOperations == 1)
        #expect(recorder.mainThreadViolations == 0)
    }

    @Test("A temporary-write failure leaves the destination unchanged and no sibling behind")
    func temporaryWriteFailureLeavesNoSibling() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer {
            try? dataStoreTestSetPermissions(0o700, of: scratch)
            try? FileManager.default.removeItem(at: scratch)
        }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let destination = scratch.appendingPathComponent("note.txt")
        let original = Data("original bytes".utf8)
        try original.write(to: destination)

        // Read and execute only: the sibling cannot be created here.
        try dataStoreTestSetPermissions(0o500, of: scratch)

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)

        let error = await dataStoreTestOperationError {
            try await store.writeAtomically("replacement", to: destination)
        }
        guard case .writeFailed(let fileName, let reason)? = error else {
            Issue.record("Expected .writeFailed, received \(String(describing: error))")
            return
        }
        #expect(fileName == "note.txt")
        #expect(!reason.isEmpty)

        #expect(try Data(contentsOf: destination) == original, "The destination bytes are unchanged")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["note.txt"],
                "No temporary file was left behind")
        #expect(recorder.totalOperations == 1)
        #expect(recorder.mainThreadViolations == 0)
    }

    @Test("A blocked cleanup is reported honestly instead of being swallowed")
    func blockedCleanupIsReported() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer {
            try? dataStoreTestSetPermissions(0o700, of: scratch)
            try? FileManager.default.removeItem(at: scratch)
        }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let destination = scratch.appendingPathComponent("note.txt")
        let original = Data("original bytes".utf8)
        try original.write(to: destination)

        // The injected rename first makes the directory unwritable, so the cleanup
        // that follows cannot remove the temporary sibling.
        let recorder = FileIOThreadRecorder()
        let store = DataStore(
            defaults: defaults,
            recorder: recorder,
            rename: { _, _ in
                try dataStoreTestSetPermissions(0o500, of: scratch)
                throw DataStore.OperationError.renameFailed(fileName: "note.txt", reason: "injected rename failure")
            }
        )

        let error = await dataStoreTestOperationError {
            try await store.writeAtomically("replacement", to: destination)
        }
        guard case .cleanupFailed(let fileName, let reason)? = error else {
            Issue.record("Expected .cleanupFailed, received \(String(describing: error))")
            return
        }
        #expect(fileName == "note.txt")
        #expect(reason.contains("injected rename failure"), "The cleanup failure names the failure that preceded it")
        #expect(reason.contains("permission"), "The cleanup failure names the cleanup problem")

        #expect(try Data(contentsOf: destination) == original, "The destination bytes are unchanged")
        let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        #expect(entries.count == 2, "The temporary sibling could not be removed, and that is reported")
        #expect(entries.contains { $0.contains("mn-save-") })
    }

    // MARK: - Thread discipline

    @Test("File I/O driven from the main actor never runs on the main thread")
    @MainActor
    func ioIsRecordedOffTheMainThread() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let destination = scratch.appendingPathComponent("note.txt")
        try Data("original bytes".utf8).write(to: destination)

        // The test body itself is on the main actor / main thread.
        #expect(dataStoreTestIsOnMainThread(), "This test drives the store from the main thread on purpose")

        let readBack = try await store.readUTF8(from: destination)
        #expect(readBack == "original bytes")
        try await store.writeAtomically("updated", to: destination)

        #expect(recorder.totalOperations == 2)
        #expect(recorder.mainThreadViolations == 0, "No read or write ran on the main thread")

        // The failure paths are recorded too, and are also off the main thread.
        _ = await dataStoreTestOperationError {
            _ = try await store.readUTF8(from: scratch.appendingPathComponent("missing.txt"))
        }
        _ = await dataStoreTestOperationError {
            try await store.writeAtomically("x", to: scratch
                .appendingPathComponent("missing-directory")
                .appendingPathComponent("note.txt"))
        }

        #expect(recorder.totalOperations == 4)
        #expect(recorder.mainThreadViolations == 0)
        #expect(dataStoreTestIsOnMainThread(), "The whole test body stayed on the main thread")
    }

    @Test("A cancelled read or write performs no I/O at all")
    func cancelledOperationsPerformNoIO() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let destination = scratch.appendingPathComponent("note.txt")
        let original = "original bytes"
        try Data(original.utf8).write(to: destination)

        let gate = DataStoreTestCancellationGate()
        let readTask = Task { () -> Bool in
            await gate.park()
            do {
                _ = try await store.readUTF8(from: destination)
                return false
            } catch {
                return error is CancellationError
            }
        }
        let writeTask = Task { () -> Bool in
            await gate.park()
            do {
                try await store.writeAtomically("replacement", to: destination)
                return false
            } catch {
                return error is CancellationError
            }
        }

        readTask.cancel()
        writeTask.cancel()
        await gate.open()

        let readWasCancelled = await readTask.value
        let writeWasCancelled = await writeTask.value
        #expect(readWasCancelled, "A cancelled read reports cancellation")
        #expect(writeWasCancelled, "A cancelled write reports cancellation")

        #expect(recorder.totalOperations == 0, "A cancelled operation performs no file I/O")
        #expect(recorder.mainThreadViolations == 0)
        #expect(try Data(contentsOf: destination) == Data(original.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["note.txt"])
    }

    // MARK: - Versioned settings keys

    @Test("Every persisted settings key is versioned under the settings.v1 prefix")
    func settingsKeysAreVersioned() {
        #expect(DataStore.settingsKeyPrefix == "com.monospace.notes.settings.v1.")
        #expect(DataStore.fontFamilyKey == "com.monospace.notes.settings.v1.fontFamily")
        #expect(DataStore.pointSizeKey == "com.monospace.notes.settings.v1.pointSize")
        #expect(DataStore.saveKeybindingKey == "com.monospace.notes.settings.v1.saveKeybinding")
        #expect(DataStore.fontFamilyKey.hasPrefix(LockedIdentity.bundleIdentifier + ".settings.v1."))
        #expect(DataStore.pointSizeKey.hasPrefix(LockedIdentity.bundleIdentifier + ".settings.v1."))
        #expect(DataStore.saveKeybindingKey.hasPrefix(LockedIdentity.bundleIdentifier + ".settings.v1."))
        #expect(DataStore.defaultFontFamily == "Menlo")
        #expect(DataStore.defaultPointSize == 13)
    }

    // MARK: - Typography (CON-DATA-TYPOGRAPHY-SETTINGS, CON-PERSISTENCE-TYPOGRAPHY-SETTINGS)

    @Test("A fresh suite loads Menlo at 13 points and a read writes nothing")
    func typographyDefaultsOnAFreshSuite() throws {
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let typography = store.loadTypography()

        #expect(typography == TypographySettings.default)
        #expect(typography.fontFamily == "Menlo")
        #expect(typography.pointSize == 13)
        #expect(typography.fontFamily == DataStore.defaultFontFamily)
        #expect(typography.pointSize == DataStore.defaultPointSize)

        _ = defaults.synchronize()
        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        #expect(persisted.isEmpty, "Loading settings must not persist anything")
    }

    @Test("Typography round trips through the versioned keys")
    func typographyRoundTrips() throws {
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let chosen = TypographySettings(fontFamily: "Courier New", pointSize: 16)
        try store.storeTypography(chosen)

        #expect(store.loadTypography() == chosen, "The stored typography loads back unchanged")
        #expect(defaults.object(forKey: DataStore.fontFamilyKey) as? String == "Courier New")
        #expect((defaults.object(forKey: DataStore.pointSizeKey) as? NSNumber)?.doubleValue == 16)

        _ = defaults.synchronize()
        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        #expect(Set(persisted.keys) == Set([DataStore.fontFamilyKey, DataStore.pointSizeKey]),
                "Typography uses exactly the two versioned keys")

        // A fresh store over the same suite — a relaunch — sees the stored values.
        let relaunched = try #require(UserDefaults(suiteName: suiteName))
        let relaunchedStore = DataStore(defaults: relaunched, recorder: FileIOThreadRecorder())
        #expect(relaunchedStore.loadTypography() == chosen)

        // The documented upper bound is inclusive; anything above it is not.
        #expect(DataStore.isStorablePointSize(512))
        #expect(!DataStore.isStorablePointSize(512.0001))
        #expect(DataStore.isStorablePointSize(13))
    }

    @Test(
        "An invalid stored point size falls back to 13 points without throwing",
        arguments: [
            DataStoreTestStoredValue.string("thirteen"),
            DataStoreTestStoredValue.number(-4),
            DataStoreTestStoredValue.number(0),
            DataStoreTestStoredValue.number(Double.nan),
            DataStoreTestStoredValue.number(Double.infinity),
            DataStoreTestStoredValue.number(100_000),
        ]
    )
    func invalidStoredPointSizeFallsBackToThirteen(_ stored: DataStoreTestStoredValue) throws {
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        stored.apply(to: defaults, forKey: DataStore.pointSizeKey)

        let typography = store.loadTypography()
        #expect(typography.pointSize == 13, "\(stored) must fall back to 13 points")
        #expect(typography.fontFamily == "Menlo")
        #expect(typography == TypographySettings.default)
    }

    @Test(
        "A missing or unusable stored font family falls back to Menlo",
        arguments: [
            DataStoreTestStoredValue.string(""),
            DataStoreTestStoredValue.string("   "),
            DataStoreTestStoredValue.number(13),
        ]
    )
    func invalidStoredFontFamilyFallsBackToMenlo(_ stored: DataStoreTestStoredValue) throws {
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        stored.apply(to: defaults, forKey: DataStore.fontFamilyKey)
        defaults.set(16.0, forKey: DataStore.pointSizeKey)

        let typography = store.loadTypography()
        #expect(typography.fontFamily == "Menlo", "\(stored) must fall back to Menlo")
        #expect(typography.pointSize == 16, "A valid point size is still honoured")
    }

    @Test("An invalid typography store is rejected and the last valid value is kept")
    func invalidTypographyStoreIsRejected() throws {
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let valid = TypographySettings(fontFamily: "Courier New", pointSize: 16)
        try store.storeTypography(valid)

        let rejected: [TypographySettings] = [
            TypographySettings(fontFamily: "Menlo", pointSize: 0),
            TypographySettings(fontFamily: "Menlo", pointSize: -4),
            TypographySettings(fontFamily: "Menlo", pointSize: Double.nan),
            TypographySettings(fontFamily: "Menlo", pointSize: Double.infinity),
            TypographySettings(fontFamily: "Menlo", pointSize: 100_000),
            TypographySettings(fontFamily: "", pointSize: 16),
            TypographySettings(fontFamily: "   ", pointSize: 16),
        ]

        for settings in rejected {
            do {
                try store.storeTypography(settings)
                Issue.record("Expected storing \(settings) to be rejected")
            } catch let error as DataStore.OperationError {
                guard case .invalidTypography = error else {
                    Issue.record("Expected .invalidTypography, received \(error)")
                    return
                }
            }
        }

        #expect(store.loadTypography() == valid, "The last valid stored typography is preserved")
        #expect(defaults.object(forKey: DataStore.fontFamilyKey) as? String == "Courier New")
        #expect((defaults.object(forKey: DataStore.pointSizeKey) as? NSNumber)?.doubleValue == 16)
    }

    // MARK: - Keybindings (CON-DATA-KEYBINDING-SETTINGS, CON-PERSISTENCE-KEYBINDING-SETTINGS)

    @Test("A fresh suite loads Cmd+O, Cmd+S, Shift+Cmd+S, Cmd+F and Cmd+,")
    func keybindingsDefaultOnAFreshSuite() throws {
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let keybindings = store.loadKeybindings()

        #expect(keybindings == KeybindingSettings.default)
        #expect(keybindings.open == KeyBinding.open)
        #expect(keybindings.save == KeyBinding.save)
        #expect(keybindings.saveAs == KeyBinding.saveAs)
        #expect(keybindings.search == KeyBinding.search)
        #expect(keybindings.settings == KeyBinding.settings)

        #expect(keybindings.save.key == "s")
        #expect(keybindings.save.command)
        #expect(!keybindings.save.shift)
        #expect(!keybindings.save.option)
        #expect(!keybindings.save.control)
        #expect(keybindings.save.displayString == "⌘S", "The default save is Cmd+S")
        #expect(keybindings.open.displayString == "⌘O")
        #expect(keybindings.saveAs.displayString == "⇧⌘S")
        #expect(keybindings.search.displayString == "⌘F")
        #expect(keybindings.settings.displayString == "⌘,")

        _ = defaults.synchronize()
        #expect((defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty,
                "Loading keybindings must not persist anything")
    }

    @Test("Keybindings round trip through the single versioned blob")
    func keybindingsRoundTrip() throws {
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let chosen = KeybindingSettings(
            open: KeyBinding(key: "p", command: true, shift: true),
            save: KeyBinding(key: "k", command: true),
            saveAs: KeyBinding(key: "j", command: true, shift: true),
            search: KeyBinding(key: "l", command: true),
            settings: KeyBinding(key: ";", command: true)
        )
        try store.storeKeybindings(chosen)

        #expect(store.loadKeybindings() == chosen, "The stored keybindings load back unchanged")

        let blob = try #require(defaults.data(forKey: DataStore.saveKeybindingKey),
                                "The keybindings are stored as a blob under the versioned key")
        let record = try JSONDecoder().decode(DataStore.KeybindingRecord.self, from: blob)
        #expect(record.version == DataStore.KeybindingRecord.currentVersion)
        #expect(record.saveShortcut.key == "k")
        #expect(record.saveShortcut.command)

        _ = defaults.synchronize()
        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        #expect(Set(persisted.keys) == Set([DataStore.saveKeybindingKey]),
                "Keybindings use exactly the one versioned key")

        // A fresh store over the same suite — a relaunch — sees the stored values.
        let relaunched = try #require(UserDefaults(suiteName: suiteName))
        let relaunchedStore = DataStore(defaults: relaunched, recorder: FileIOThreadRecorder())
        #expect(relaunchedStore.loadKeybindings() == chosen)
    }

    @Test(
        "A missing, undecodable or wrong-shaped keybinding blob falls back to the documented defaults",
        arguments: [
            DataStoreTestStoredBlob.rawData(Data([0x00, 0x01, 0x02])),
            DataStoreTestStoredBlob.text("not a blob"),
            DataStoreTestStoredBlob.number(13),
            DataStoreTestStoredBlob.record(version: 99, saveKey: "s"),
            DataStoreTestStoredBlob.record(version: 1, saveKey: ""),
            DataStoreTestStoredBlob.truncatedJSON,
        ]
    )
    func undecodableKeybindingBlobFallsBackToDefault(_ stored: DataStoreTestStoredBlob) throws {
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        try stored.apply(to: defaults, forKey: DataStore.saveKeybindingKey)

        let keybindings = store.loadKeybindings()
        #expect(keybindings == KeybindingSettings.default, "\(stored) must fall back to the defaults")
        #expect(keybindings.save == KeyBinding.save)
        #expect(keybindings.save.displayString == "⌘S")
    }

    @Test("Invalid keybindings are rejected and the last valid value is kept")
    func invalidKeybindingsStoreIsRejected() throws {
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let valid = KeybindingSettings(
            open: KeyBinding(key: "p", command: true),
            save: KeyBinding(key: "k", command: true),
            saveAs: KeyBinding(key: "j", command: true, shift: true),
            search: KeyBinding(key: "l", command: true),
            settings: KeyBinding(key: ";", command: true)
        )
        try store.storeKeybindings(valid)

        let rejected = [
            KeybindingSettings(save: KeyBinding(key: "", command: true)),
            KeybindingSettings(open: KeyBinding(key: "   ")),
            KeybindingSettings(settings: KeyBinding(key: "")),
        ]
        for settings in rejected {
            do {
                try store.storeKeybindings(settings)
                Issue.record("Expected storing keybindings with an empty key to be rejected")
            } catch let error as DataStore.OperationError {
                guard case .invalidKeybinding = error else {
                    Issue.record("Expected .invalidKeybinding, received \(error)")
                    return
                }
            }
        }

        #expect(store.loadKeybindings() == valid, "The last valid stored keybindings are preserved")
    }

    // MARK: - Never-persisted state (CON-PERSISTENCE-OPEN-DOCUMENT-BUFFER, -WORKSPACE-FOLDER-REFERENCE)

    @Test("The document buffer and the workspace folder reference are never persisted")
    @MainActor
    func bufferAndWorkspaceAreNeverPersisted() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let noteURL = scratch.appendingPathComponent("note.txt")
        let savedContents = "note contents that are already on disk\n"
        try Data(savedContents.utf8).write(to: noteURL)

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)

        // The composition root wiring this owner is used with.
        let state = AppState(noteFiles: store, settings: store, ioRecorder: recorder)
        #expect(state.documentText.isEmpty, "The buffer starts empty in memory")

        // Use both in-memory values the way the app does: the buffer holds the
        // unsaved edit and the workspace folder is the note's parent folder.
        let unsavedBufferText = "unsaved edit that must never reach disk — 日本語"
        let documentBuffer = state.documentText + unsavedBufferText
        let workspaceFolder = state.workspaceFolder ?? noteURL.deletingLastPathComponent()

        try store.storeTypography(TypographySettings(fontFamily: "Courier New", pointSize: 16))
        try store.storeKeybindings(KeybindingSettings.default)
        let reloaded = try await store.readUTF8(from: noteURL)

        #expect(documentBuffer == unsavedBufferText)
        #expect(workspaceFolder.path == scratch.standardizedFileURL.path)
        #expect(reloaded == savedContents)

        // 1. `UserDefaults` holds ONLY the three versioned settings keys.
        _ = defaults.synchronize()
        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        let expectedKeys = [DataStore.fontFamilyKey, DataStore.pointSizeKey, DataStore.saveKeybindingKey]
        #expect(Set(persisted.keys) == Set(expectedKeys),
                "The suite holds the typography and keybinding keys and nothing else")

        let prefixedKeys = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(DataStore.settingsKeyPrefix) }
        #expect(Set(prefixedKeys) == Set(expectedKeys),
                "No other versioned key exists: neither the buffer nor the workspace folder is stored")

        // 2. No stored value carries the buffer or the folder reference.
        for value in persisted.values {
            let description = String(describing: value)
            #expect(!description.contains(unsavedBufferText))
            #expect(!description.contains(workspaceFolder.path))
        }

        // 3. No file was created for either of them, and the buffer text is on no
        //    file in the workspace folder.
        let entries = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        #expect(entries.sorted() == ["note.txt"],
                "Neither the buffer nor the workspace reference creates a file")
        for entry in entries {
            let bytes = try Data(contentsOf: scratch.appendingPathComponent(entry))
            #expect(!String(decoding: bytes, as: UTF8.self).contains(unsavedBufferText),
                    "The unsaved buffer never reaches a file")
        }

        #expect(recorder.totalOperations == 1, "The only file I/O was the note read")
        #expect(recorder.mainThreadViolations == 0)
    }

    @Test("DataStore never targets a shared temporary location or a support directory")
    func storeSourceUsesSiblingsAndPosixRename() throws {
        let source = try dataStoreTestSourceText()

        for token in [
            "NSTemporaryDirectory",
            "temporaryDirectory",
            "Application Support",
            "ApplicationSupport",
            "NSApplicationSupportDirectory",
            "default.moveItem(",
            "default.replaceItemAt(",
        ] {
            #expect(!source.contains(token), "DataStore.swift must not reference \(token)")
        }

        #expect(source.contains("Darwin.rename("), "The atomic replace is the POSIX rename(2)")
        #expect(source.contains("temporarySiblingURL"), "The temporary file is built as a sibling of the destination")
    }

    // MARK: - Measured numbers

    @Test("Measured: a 1 MiB atomic save round trip on this machine")
    func measuredAtomicSave() async throws {
        let scratch = try dataStoreTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try dataStoreTestSuite()
        defer { dataStoreTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let destination = scratch.appendingPathComponent("large.txt")

        let payload = String(repeating: "a", count: 1_048_576)
        let payloadBytes = payload.utf8.count
        #expect(payloadBytes == 1_048_576)

        let start = ContinuousClock.now
        try await store.writeAtomically(payload, to: destination)
        let duration = ContinuousClock.now - start

        let milliseconds = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        print("MEASURED DataStore atomic write: \(payloadBytes) bytes in \(String(format: "%.2f", milliseconds)) ms")

        let onDisk = try Data(contentsOf: destination)
        #expect(onDisk == Data(payload.utf8), "The 1 MiB payload is written exactly")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).sorted() == ["large.txt"])
        #expect(recorder.mainThreadViolations == 0)
    }
}
