//
//  OpenAndSavePanelsForLocalFilesystemAccessFeatureTests.swift
//  MonospaceNotesTests
//
//  TASK-12-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS focused suite — owner
//  OWN-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS.
//
//  Covers FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS with
//  CON-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-INTERFACE / -RECOVERY,
//  CON-DATA-NOTE-FILE, CON-DATA-TEMPORARY-SAVE-FILE, CON-PERMISSION-FILESYSTEM and
//  CON-DATA-OPEN-DOCUMENT-BUFFER against the real
//  `OpenAndSavePanelsForLocalFilesystemAccessFeature`, the real `PermissionCoordinator`,
//  the real `NativePanelPresenter` and the real `DataStore` writer:
//
//    * ACC-...-01 — the path the fake open panel RECORDED is exactly the path the
//      `NoteFileAccess` seam READ: the same string, the same URL value, compared as
//      standardized paths (URL `==` is not a path comparison on macOS), with a decoy note
//      in the same directory proving nothing else was reached. Repeated against a real
//      file through the real `DataStore`, with the thread recorder proving the read ran
//      off the main thread.
//    * ACC-...-02 — the path the fake save panel recorded is exactly the path the buffer
//      was WRITTEN to: the real destination file holds exactly the UTF-8 bytes of the
//      buffer, the directory holds nothing else (the same-directory temporary file was
//      renamed over the destination, so no sibling survives), and an untouched neighbour
//      keeps its bytes. A second form asserts the write destination value equals the
//      chosen URL exactly and that no other path was ever handed to the seam.
//    * ACC-...-03 — cancelling leaves the current document and its path unchanged, with
//      state `.cancelled`, and nothing read or written: the document this owner last read
//      and its text, the destination it last committed to, the buffer it would commit and
//      the real bytes on disk are all asserted unchanged, and the cancelled attempt is
//      asserted to have reached neither the reader nor the writer.
//    * ACC-...-04 — the open panel lists only `.txt` files as selectable, asserted on the
//      real `NSOpenPanel` / `NSSavePanel` CONFIGURATION built by the production
//      `NativePanelPresenter` (`allowedContentTypes`, the extension of the allowed type,
//      multiple selection, directories, other file types) and on the coordinator's locked
//      `allowedFileExtension`; no UI is ever shown. The restriction is additionally
//      enforced on whatever a presenter returns: a non-`.txt` selection is refused with
//      nothing read and nothing written.
//    * Save As uses the SAME atomic writer as Cmd+S — proved by counting the calls on ONE
//      shared `NoteFileAccess` instance held by both owners (never by inspecting wording),
//      and by asserting with the real `DataStore` that both commands leave the identical
//      on-disk shape.
//
//  Also covered: every failure, cancellation, cleanup and recovery branch of the two
//  contracts — a read that cannot be read, a file that is not valid UTF-8, a write the
//  writer rejects, a rename failure injected into the real `DataStore` (destination bytes
//  unchanged, temporary sibling removed, "Could Not Save Note" naming the path), an
//  interrupted read and an interrupted write, an attempt cancelled before it starts, the
//  explicit retry that follows each failure, the scope that is held during an operation
//  and released on every terminal path (including the scope another operation holds), and
//  the structural proof that this owner reaches disk only through the shared seam.
//
//  No assertion here depends on a wall-clock window and nothing sleeps: cancellation is
//  driven by a deterministic park/open handshake, and ordering (panel before read, panel
//  before write) is asserted from a call log the doubles write themselves.
//
//  Every double is file-private and prefixed `OpenSaveTest`, so it cannot collide with
//  another suite in this module.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import MonospaceNotes

// MARK: - File-scope fixtures (unique names: every test file compiles into one module)

private typealias OpenSaveTestFeature = OpenAndSavePanelsForLocalFilesystemAccessFeature

/// An ordered, thread-safe record of what the doubles were asked to do. "The panel chose the
/// path before anything was read or written" is asserted from this log, never from elapsed
/// time.
private final class OpenSaveTestCallLog: @unchecked Sendable {
    enum Kind: Equatable, Sendable {
        case openPanelAsked
        case savePanelAsked
        case noteRead
        case writeAttempted
    }

    struct Step: Equatable, Sendable {
        let kind: Kind
        let detail: String
    }

    private let lock = NSLock()
    private var steps: [Step] = []

    func record(_ kind: Kind, detail: String = "") {
        lock.lock()
        defer { lock.unlock() }
        steps.append(Step(kind: kind, detail: detail))
    }

    var recorded: [Step] {
        lock.lock()
        defer { lock.unlock() }
        return steps
    }

    var kinds: [Kind] { recorded.map(\.kind) }
    var details: [String] { recorded.map(\.detail) }
}

/// A failure the shared seam could report, carrying its own short reason.
private struct OpenSaveTestFailure: Error, Equatable, Sendable, CustomStringConvertible {
    let reason: String

    var description: String { reason }
}

/// Observes the permission owner and this owner from INSIDE an operation, so "the access
/// scope of the user-selected location is held while the operation runs" and "the attempt is
/// `.active` while it runs" are real observations rather than assumptions about the code.
@MainActor
private final class OpenSaveTestScopeProbe {
    weak var feature: OpenSaveTestFeature?
    weak var permissions: PermissionCoordinator?

    private(set) var scopeCountsAtRead: [Int] = []
    private(set) var scopeCountsAtWrite: [Int] = []
    private(set) var openStatesAtRead: [OperationState] = []
    private(set) var saveStatesAtWrite: [OperationState] = []

    func recordReadEntry() {
        scopeCountsAtRead.append(permissions?.activeScopeCount ?? -1)
        if let feature { openStatesAtRead.append(feature.openState) }
    }

    func recordWriteEntry() {
        scopeCountsAtWrite.append(permissions?.activeScopeCount ?? -1)
        if let feature { saveStatesAtWrite.append(feature.saveState) }
    }
}

/// The panel seam: answers from a queue (an empty queue answers `nil`, i.e. "the user
/// cancelled"), records every path it handed over, and logs the ask. It shows nothing.
private final class OpenSaveTestPanelPresenter: PanelPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private let log: OpenSaveTestCallLog
    private var openAnswers: [URL?]
    private var saveAnswers: [URL?]
    private var openPaths: [String] = []
    private var savePaths: [String] = []
    private var names: [String] = []
    private var openAsks = 0
    private var saveAsks = 0

    init(openAnswers: [URL?] = [], saveAnswers: [URL?] = [], log: OpenSaveTestCallLog) {
        self.openAnswers = openAnswers
        self.saveAnswers = saveAnswers
        self.log = log
    }

    /// Scripts the next open answer. `nil` means "the user cancelled the panel".
    func scriptOpen(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        openAnswers.append(url)
    }

    /// Scripts the next save answer.
    func scriptSave(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        saveAnswers.append(url)
    }

    func chooseExistingNote() async -> URL? {
        let answer = nextOpen()
        log.record(.openPanelAsked, detail: answer?.path ?? "")
        return answer
    }

    func chooseNewNoteDestination(suggestedName: String) async -> URL? {
        let answer = nextSave(suggestedName: suggestedName)
        log.record(.savePanelAsked, detail: answer?.path ?? "")
        return answer
    }

    /// The locked mutations themselves, synchronous so no `NSLock` is used from an async
    /// context.
    private func nextOpen() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        openAsks += 1
        let answer = openAnswers.isEmpty ? nil : openAnswers.removeFirst()
        if let answer { openPaths.append(answer.path) }
        return answer
    }

    private func nextSave(suggestedName: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        saveAsks += 1
        names.append(suggestedName)
        let answer = saveAnswers.isEmpty ? nil : saveAnswers.removeFirst()
        if let answer { savePaths.append(answer.path) }
        return answer
    }

    var openAskCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openAsks
    }

    var saveAskCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return saveAsks
    }

    /// The exact paths this double handed over, in order.
    var recordedOpenPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return openPaths
    }

    var recordedSavePaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return savePaths
    }

    var recordedSuggestedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }
}

/// The note-file seam: records EVERY path this owner reaches (reads and writes, with the
/// payload), can fail a specific path on demand, and — when a real store is attached —
/// forwards the operation to it, so "the exact path the feature reached" and "the real bytes
/// on disk" can be asserted in the same test. It performs no I/O of its own.
private final class OpenSaveTestNoteFileAccess: NoteFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let log: OpenSaveTestCallLog
    private let probe: OpenSaveTestScopeProbe?
    private let forwarding: (any NoteFileAccess)?
    private var texts: [URL: String]
    private var failures: [URL: Error]
    private var readURLs: [URL] = []
    private var writeURLs: [URL] = []
    private var payloads: [String] = []

    init(
        log: OpenSaveTestCallLog,
        probe: OpenSaveTestScopeProbe? = nil,
        forwarding: (any NoteFileAccess)? = nil,
        texts: [URL: String] = [:],
        failures: [URL: Error] = [:]
    ) {
        self.log = log
        self.probe = probe
        self.forwarding = forwarding
        self.texts = texts
        self.failures = failures
    }

    func readUTF8(from url: URL) async throws -> String {
        let pendingFailure = recordRead(url)
        log.record(.noteRead, detail: url.path)

        if let probe {
            await probe.recordReadEntry()
        }

        if let pendingFailure { throw pendingFailure }
        if let forwarding { return try await forwarding.readUTF8(from: url) }
        if let text = text(for: url) { return text }
        throw OpenSaveTestFailure(reason: "this double holds no note for that path")
    }

    func writeAtomically(_ contents: String, to url: URL) async throws {
        let pendingFailure = recordWrite(contents, to: url)
        log.record(.writeAttempted, detail: url.path)

        if let probe {
            await probe.recordWriteEntry()
        }

        if let pendingFailure { throw pendingFailure }
        if let forwarding {
            try await forwarding.writeAtomically(contents, to: url)
        }
    }

    private func recordRead(_ url: URL) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        readURLs.append(url)
        return failures[url]
    }

    private func recordWrite(_ contents: String, to url: URL) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        writeURLs.append(url)
        payloads.append(contents)
        return failures[url]
    }

    private func text(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return texts[url]
    }

    /// Every path this owner reached, in order: reads first, then writes.
    var touchedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return readURLs.map(\.path) + writeURLs.map(\.path)
    }

    var reads: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return readURLs
    }

    var writeDestinations: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return writeURLs
    }

    var writtenPayloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readURLs.count
    }

    /// How many times the one and only write entry point of the seam was called. Counting
    /// this is how "Save As uses the same atomic writer as Cmd+S" is proved: both owners
    /// write through this object, and nothing else here can write.
    var writeAtomicallyCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeURLs.count
    }
}

/// Parks a task so a test can cancel it before it reaches the operation, then releases it —
/// a deterministic handshake instead of a sleep.
private actor OpenSaveTestHandshake {
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

// MARK: - Helpers

/// A real scratch directory under the system temporary location, unique per call.
private func openSaveTestScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("monospace-notes-open-save-panel-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func openSaveTestRemove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// A dedicated, unique `UserDefaults` suite so no test can see another one's state.
private func openSaveTestDefaultsSuite() throws -> (name: String, defaults: UserDefaults) {
    let name = "com.monospace.notes.tests.opensavepanels.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name), "A dedicated defaults suite is required")
    return (name, defaults)
}

private func openSaveTestDiscardSuite(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
        .path
    if FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

@discardableResult
private func openSaveTestWriteNote(named name: String, text: String, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
}

/// Every entry directly under a directory, sorted — the fingerprint a test uses to prove that
/// no temporary file survived an atomic save.
private func openSaveTestEntries(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

/// Both sides of a path comparison are resolved the same way: `temporaryDirectory` is reached
/// through the `/var` → `/private/var` link on macOS, and a deep enumerator reports the
/// resolved spelling.
private func openSaveTestResolvedPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().path
}

/// Every entry under a directory, recursively, as absolute paths.
private func openSaveTestTree(_ root: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
    ) else {
        return []
    }
    return enumerator.compactMap { ($0 as? URL).map(openSaveTestResolvedPath) }.sorted()
}

/// The shared writer's injected rename, failing on purpose, so the whole atomic-save failure
/// branch (destination bytes unchanged, temporary sibling removed, the owner reports the
/// failure) is exercised through the REAL `DataStore` rather than a scripted double.
private func openSaveTestFailingRename(_ from: String, _ to: String) throws {
    throw DataStore.OperationError.renameFailed(
        fileName: URL(fileURLWithPath: to).lastPathComponent,
        reason: "injected rename failure"
    )
}

/// This owner's own source, for the structural proofs.
private func openSaveTestFeatureSource() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot
        .appendingPathComponent("Sources/MonospaceNotes/Features/OpenAndSavePanelsForLocalFilesystemAccessFeature.swift")
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

/// The real panels under test, built once per test run by the production
/// `NativePanelPresenter` and never shown. No sleep is used: the panels are only built once.
@MainActor
private enum OpenSaveTestPanelFixture {
    private static var built: (open: NSOpenPanel, save: NSSavePanel)?

    static func panels() async -> (open: NSOpenPanel, save: NSSavePanel) {
        if let built { return built }

        // AppKit panels need the shared application to exist; this creates it without
        // activating anything.
        _ = NSApplication.shared

        let presenter = NativePanelPresenter()
        let open = presenter.makeOpenPanel()
        // Between constructions, let anything queued run before this suite takes the main
        // actor again: each panel construction blocks the main actor synchronously.
        await Task.yield()
        let save = presenter.makeSavePanel(suggestedName: "Draft.txt")

        built = (open, save)
        return (open, save)
    }
}

// MARK: - Suite

@Suite("FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS open and save panels")
@MainActor
struct OpenAndSavePanelsForLocalFilesystemAccessFeatureTests {

    // MARK: - The vocabulary of an attempt

    @Test("A fresh owner is idle, holds nothing, and offers only plain-text .txt")
    func freshOwnerIsIdleAndOffersOnlyTxt() {
        let permissions = PermissionCoordinator(presenter: OpenSaveTestPanelPresenter(log: OpenSaveTestCallLog()))
        let feature = OpenSaveTestFeature(
            panels: OpenSaveTestPanelPresenter(log: OpenSaveTestCallLog()),
            permissions: permissions,
            noteFiles: OpenSaveTestNoteFileAccess(log: OpenSaveTestCallLog())
        )

        #expect(feature.openState == .idle)
        #expect(feature.saveState == .idle)
        #expect(feature.lastOpenOutcome == nil)
        #expect(feature.lastSaveOutcome == nil)
        #expect(feature.lastErrorAlert == nil)
        #expect(feature.lastReadURL == nil)
        #expect(feature.lastReadText == nil)
        #expect(feature.lastSavedURL == nil)
        #expect(feature.documentText == "")
        #expect(feature.openPanelPresentationCount == 0)
        #expect(feature.savePanelPresentationCount == 0)
        #expect(feature.readAttemptCount == 0)
        #expect(feature.writeAttemptCount == 0)
        #expect(permissions.activeScopeCount == 0)

        // The locked .txt restriction is one value, shared with the permission owner.
        #expect(OpenSaveTestFeature.allowedFileExtension == "txt")
        #expect(OpenSaveTestFeature.allowedFileExtension == PermissionCoordinator.allowedFileExtension,
                "the panel restriction and the acceptance rule are the same value")
        #expect(OpenSaveTestFeature.defaultSuggestedName == "Untitled.txt")
        #expect(OpenSaveTestFeature.suggestedName(for: nil) == "Untitled.txt")
        #expect(OpenSaveTestFeature.suggestedName(for: URL(fileURLWithPath: "/tmp/a/note.txt")) == "note.txt")

        // The locked alert titles.
        #expect(OpenSaveTestFeature.openFailureAlertTitle == "Could Not Open Note")
        #expect(OpenSaveTestFeature.saveFailureAlertTitle == "Could Not Save Note")

        // `cancelled` and `adoptedURL` are derived from the state, so neither can contradict
        // the operation state it describes.
        let succeeded = OpenSaveTestFeature.PanelOutcome(
            state: .succeeded,
            url: URL(fileURLWithPath: "/tmp/note.txt")
        )
        #expect(succeeded.cancelled == false)
        #expect(succeeded.adoptedURL?.path == "/tmp/note.txt")
        #expect(OpenSaveTestFeature.PanelOutcome(state: .failed, url: nil).cancelled == false)
        #expect(OpenSaveTestFeature.PanelOutcome(state: .failed, url: nil).adoptedURL == nil)
        let cancelled = OpenSaveTestFeature.PanelOutcome(state: .cancelled, url: nil)
        #expect(cancelled.cancelled)
        #expect(cancelled.adoptedURL == nil, "a cancelled panel hands nothing to adopt")

        // The neutral defaults can never show a panel: the placeholder presenter cancels.
        let unconfigured = OpenSaveTestFeature()
        #expect(unconfigured.openState == .idle)
        #expect(unconfigured.saveState == .idle)
    }

    // MARK: - ACC-01: the chosen path is the path that is read

    @Test("ACC-...-01: the path the open panel recorded is exactly the path the file seam read")
    func openReadsExactlyThePathThePanelReturned() async throws {
        let scratch = try openSaveTestScratchDirectory()
        defer { openSaveTestRemove(scratch) }

        let note = scratch.appendingPathComponent("chosen note.txt")
        let decoy = scratch.appendingPathComponent("never chosen.txt")
        let contents = "Grüße aus Ljubljana — 日本語のメモ ✓\r\nzweite Zeile\tTab\nletzte Zeile"
        try openSaveTestWriteNote(named: "chosen note.txt", text: contents, in: scratch)
        try openSaveTestWriteNote(named: "never chosen.txt", text: "decoy\n", in: scratch)

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(openAnswers: [note], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, texts: [note: contents])
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)

        let outcome = await feature.chooseOpenDestination()

        // ACC-01: the path the double recorded is the path the seam read — the same value and
        // the same standardized path.
        #expect(panel.recordedOpenPaths == [note.path])
        #expect(seam.reads.map(\.path) == panel.recordedOpenPaths,
                "ACC-01: the path the panel recorded IS the path the file seam read")
        #expect(seam.reads == [note], "the chosen URL reaches the seam unchanged, with no rewriting")
        #expect(seam.reads.first?.hasDirectoryPath == false,
                "the path is the note's file, not its containing folder")

        #expect(outcome.state == .succeeded)
        #expect(outcome.cancelled == false)
        #expect(outcome.url?.path == note.path)
        #expect(outcome.url?.hasDirectoryPath == false)
        #expect(outcome.adoptedURL?.path == note.path)
        #expect(feature.lastReadURL?.path == note.path)
        #expect(feature.lastReadText == contents, "the note's exact UTF-8 text is what was read")
        #expect(feature.lastErrorAlert == nil)
        #expect(feature.openState == .succeeded)
        #expect(feature.openPanelPresentationCount == 1)
        #expect(feature.savePanelPresentationCount == 0)
        #expect(feature.readAttemptCount == 1)
        #expect(feature.writeAttemptCount == 0)

        // The panel chose the path before anything was read or written.
        #expect(log.kinds == [.openPanelAsked, .noteRead])
        #expect(log.details == [note.path, note.path])

        // Nothing outside the user's selection was touched.
        #expect(seam.touchedPaths == [note.path], "only the user's selection was reached")
        #expect(seam.writeDestinations.isEmpty, "opening a note writes nothing")
        #expect(try openSaveTestEntries(scratch) == ["chosen note.txt", "never chosen.txt"])
        #expect(try Data(contentsOf: decoy) == Data("decoy\n".utf8),
                "the note the user did not choose is untouched")
        #expect(try Data(contentsOf: note) == Data(contents.utf8), "the read did not change the note")

        // Every terminal path releases the access scope the attempt began.
        #expect(permissions.activeScopeCount == 0)
    }

    @Test("ACC-...-01: with the real store the chosen real file is read off the main thread and nothing else is touched")
    func openReadsTheChosenRealFileThroughTheSharedStore() async throws {
        let scratch = try openSaveTestScratchDirectory()
        let (suiteName, defaults) = try openSaveTestDefaultsSuite()
        defer {
            openSaveTestRemove(scratch)
            openSaveTestDiscardSuite(suiteName)
        }

        let contents = "Ünicode — ✓ note\r\nwith CRLF\n"
        let note = try openSaveTestWriteNote(named: "real note.txt", text: contents, in: scratch)
        let treeBefore = openSaveTestTree(scratch)

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(openAnswers: [note], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, forwarding: store)
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)

        let outcome = await feature.chooseOpenDestination()

        #expect(panel.recordedOpenPaths == [note.path])
        #expect(seam.reads.map(\.path) == [note.path])
        #expect(outcome.state == .succeeded)
        #expect(outcome.url?.path == note.path)
        #expect(feature.lastReadText == contents, "the real file's exact UTF-8 text was read")
        #expect(try Data(contentsOf: note) == Data(contents.utf8))
        #expect(openSaveTestTree(scratch) == treeBefore, "reading reaches nothing new")

        // The read went through the shared, off-main-actor store: it recorded itself and no
        // main-thread violation.
        #expect(recorder.totalOperations == 1, "exactly one file operation was performed, and it was recorded")
        #expect(recorder.mainThreadViolations == 0, "no file I/O on the main thread")
        #expect(permissions.activeScopeCount == 0)
    }

    // MARK: - ACC-02: the chosen path is the path that is written

    @Test("ACC-...-02: Save As writes exactly the buffer to exactly the chosen path, atomically")
    func saveAsWritesTheBufferToExactlyTheChosenPath() async throws {
        let scratch = try openSaveTestScratchDirectory()
        let (suiteName, defaults) = try openSaveTestDefaultsSuite()
        defer {
            openSaveTestRemove(scratch)
            openSaveTestDiscardSuite(suiteName)
        }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let neighbour = try openSaveTestWriteNote(named: "neighbour.txt", text: "neighbour keeps its bytes\n", in: scratch)
        let destination = scratch.appendingPathComponent("Saved note.txt")

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(saveAnswers: [destination], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, forwarding: store)
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)

        let buffer = "Úvod — 日本語のメモ 🅰\r\nrevision two\n"
        feature.documentText = buffer

        let outcome = await feature.chooseSaveDestination(suggestedName: "Saved.txt")

        #expect(panel.recordedSavePaths == [destination.path])
        #expect(panel.recordedSuggestedNames == ["Saved.txt"], "the suggested name reaches the panel verbatim")
        #expect(outcome.state == .succeeded)
        #expect(outcome.url?.path == destination.path,
                "ACC-02: the app wrote to exactly the path the save panel returned")
        #expect(outcome.url?.hasDirectoryPath == false)
        #expect(outcome.adoptedURL?.path == destination.path)
        #expect(feature.lastSavedURL?.path == destination.path)
        #expect(feature.lastErrorAlert == nil)
        #expect(feature.saveState == .succeeded)
        #expect(feature.savePanelPresentationCount == 1)
        #expect(feature.openPanelPresentationCount == 0)
        #expect(feature.writeAttemptCount == 1)

        // The real destination holds exactly the buffer, and the atomic writer left nothing
        // behind: its same-directory temporary file was renamed over the destination.
        #expect(seam.writeDestinations.map(\.path) == [destination.path])
        #expect(try Data(contentsOf: destination) == Data(buffer.utf8))
        #expect(try openSaveTestEntries(scratch) == ["Saved note.txt", "neighbour.txt"],
                "no temporary save file survives in the destination's own directory")
        #expect(try Data(contentsOf: neighbour) == Data("neighbour keeps its bytes\n".utf8),
                "the file the user did not select is untouched")

        // The panel chose the destination before anything was written.
        #expect(log.kinds == [.savePanelAsked, .writeAttempted])
        #expect(log.details == [destination.path, destination.path])

        #expect(recorder.totalOperations == 1, "exactly one file operation: the write")
        #expect(recorder.mainThreadViolations == 0)
        #expect(permissions.activeScopeCount == 0)
    }

    @Test("ACC-...-02: Save As reaches exactly one path — the chosen URL — and commits exactly the buffer")
    func saveAsReachesOnlyTheChosenPath() async throws {
        let scratch = try openSaveTestScratchDirectory()
        let other = try openSaveTestScratchDirectory()
        defer {
            openSaveTestRemove(scratch)
            openSaveTestRemove(other)
        }

        let destination = scratch.appendingPathComponent("only path.txt")
        let elsewhere = try openSaveTestWriteNote(named: "elsewhere.txt", text: "not the destination\n", in: other)

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(saveAnswers: [destination], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log)
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)

        let buffer = "the exact buffer\n"
        feature.documentText = buffer

        let outcome = await feature.chooseSaveDestination(suggestedName: OpenSaveTestFeature.defaultSuggestedName)

        #expect(outcome.state == .succeeded)
        // The destination handed to the writer is the chosen URL itself, value for value, and
        // the same standardized path the panel recorded.
        #expect(seam.writeDestinations == [destination])
        #expect(seam.writeDestinations.map(\.path) == panel.recordedSavePaths)
        #expect(seam.touchedPaths == [destination.path], "exactly one path was reached")
        #expect(seam.writtenPayloads == [buffer], "exactly the in-memory buffer was committed")
        #expect(seam.reads.isEmpty, "Save As reads nothing")
        #expect(seam.writeAtomicallyCallCount == 1)
        #expect(seam.readCount == 0)
        #expect(elsewhere.path != destination.path)
        #expect(try Data(contentsOf: elsewhere) == Data("not the destination\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.path),
                "the double performs no I/O itself: only the seam was asked to write")
        #expect(permissions.activeScopeCount == 0)
    }

    @Test("A later selection replaces the previous destination while the earlier note keeps its bytes")
    func aLaterSelectionFollowsTheNewPathOnly() async throws {
        let scratch = try openSaveTestScratchDirectory()
        let (suiteName, defaults) = try openSaveTestDefaultsSuite()
        defer {
            openSaveTestRemove(scratch)
            openSaveTestDiscardSuite(suiteName)
        }

        let first = scratch.appendingPathComponent("first.txt")
        let second = scratch.appendingPathComponent("second.txt")
        try Data("first revision\n".utf8).write(to: first)

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(saveAnswers: [first, second], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, forwarding: store)
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)

        feature.documentText = "revision two\n"
        let firstOutcome = await feature.chooseSaveDestination(suggestedName: "first.txt")
        #expect(firstOutcome.state == .succeeded)
        #expect(feature.lastSavedURL?.path == first.path)
        #expect(try Data(contentsOf: first) == Data("revision two\n".utf8))

        feature.documentText = "revision three\n"
        let secondOutcome = await feature.chooseSaveDestination(suggestedName: "second.txt")

        #expect(secondOutcome.state == .succeeded)
        #expect(feature.lastSavedURL?.path == second.path, "the document follows the new selection")
        #expect(try Data(contentsOf: second) == Data("revision three\n".utf8))
        #expect(try Data(contentsOf: first) == Data("revision two\n".utf8),
                "the earlier destination keeps the bytes of the save that addressed it")
        #expect(seam.writeDestinations.map(\.path) == [first.path, second.path])
        #expect(try openSaveTestEntries(scratch) == ["first.txt", "second.txt"],
                "two atomic saves leave two files and no temporary sibling")
        #expect(permissions.activeScopeCount == 0)
        #expect(recorder.mainThreadViolations == 0)
    }

    // MARK: - ACC-03: cancelling changes nothing

    @Test("ACC-...-03: a cancelled open leaves the current document and its path unchanged")
    func cancelledOpenLeavesTheDocumentAndItsPathUnchanged() async throws {
        let scratch = try openSaveTestScratchDirectory()
        defer { openSaveTestRemove(scratch) }

        let note = try openSaveTestWriteNote(named: "kept.txt", text: "kept contents\n", in: scratch)
        let treeBefore = openSaveTestTree(scratch)

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(openAnswers: [note], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, texts: [note: "kept contents\n"])
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)

        // The document as it stands: one note open, its path and its text known.
        let opened = await feature.chooseOpenDestination()
        #expect(opened.state == .succeeded)
        #expect(feature.lastReadURL?.path == note.path)
        #expect(feature.lastReadText == "kept contents\n")
        let readsBeforeTheCancel = seam.readCount

        // Now the user cancels: `nil` is the panel reporting a cancel.
        panel.scriptOpen(nil)
        let cancelled = await feature.chooseOpenDestination()

        #expect(cancelled.state == .cancelled, "ACC-03: a cancelled panel reports .cancelled")
        #expect(cancelled.cancelled)
        #expect(cancelled.url == nil, "no path was chosen, so the outcome carries none")
        #expect(cancelled.adoptedURL == nil)
        #expect(feature.openState == .cancelled)
        #expect(feature.lastErrorAlert == nil, "cancelling a panel is not an error, so no alert")

        // The current document and its path are unchanged.
        #expect(feature.lastReadURL?.path == note.path)
        #expect(feature.lastReadText == "kept contents\n")
        #expect(feature.lastSavedURL == nil)

        // Nothing was read or written by the cancelled attempt.
        #expect(seam.readCount == readsBeforeTheCancel, "the cancelled attempt read nothing")
        #expect(seam.writeDestinations.isEmpty, "the cancelled attempt wrote nothing")
        #expect(seam.touchedPaths == [note.path], "the only path ever reached is the one that was opened")
        #expect(log.kinds == [.openPanelAsked, .noteRead, .openPanelAsked],
                "the second panel was asked and cancelled before any read")
        #expect(feature.openPanelPresentationCount == 2)
        #expect(feature.readAttemptCount == 1)
        #expect(openSaveTestTree(scratch) == treeBefore)
        #expect(permissions.activeScopeCount == 0)

        // An explicit retry — another selection — still succeeds after the cancel.
        panel.scriptOpen(note)
        let retried = await feature.chooseOpenDestination()
        #expect(retried.state == .succeeded, "another explicit selection follows a cancel")
        #expect(feature.lastErrorAlert == nil)
        #expect(permissions.activeScopeCount == 0)
    }

    @Test("ACC-...-03: a cancelled Save As writes nothing and keeps the document's last path")
    func cancelledSaveAsWritesNothingAndKeepsThePath() async throws {
        let scratch = try openSaveTestScratchDirectory()
        let (suiteName, defaults) = try openSaveTestDefaultsSuite()
        defer {
            openSaveTestRemove(scratch)
            openSaveTestDiscardSuite(suiteName)
        }

        let committed = scratch.appendingPathComponent("committed.txt")
        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(saveAnswers: [committed], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, forwarding: store)
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)

        feature.documentText = "first revision\n"
        let firstSave = await feature.chooseSaveDestination(suggestedName: "committed.txt")
        #expect(firstSave.state == .succeeded)
        #expect(feature.lastSavedURL?.path == committed.path)
        let writesBeforeTheCancel = seam.writeAtomicallyCallCount

        // The user edits and then cancels the save panel.
        feature.documentText = "edited, uncommitted revision\n"
        panel.scriptSave(nil)
        let cancelled = await feature.chooseSaveDestination(suggestedName: "committed.txt")

        #expect(cancelled.state == .cancelled, "ACC-03: a cancelled save panel reports .cancelled")
        #expect(cancelled.cancelled)
        #expect(cancelled.url == nil)
        #expect(cancelled.adoptedURL == nil)
        #expect(feature.saveState == .cancelled)
        #expect(feature.lastErrorAlert == nil)

        // The current document, its path and the buffer are unchanged.
        #expect(feature.lastSavedURL?.path == committed.path, "the document keeps the path it already had")
        #expect(feature.documentText == "edited, uncommitted revision\n",
                "the cancelled attempt does not touch the in-memory buffer")
        #expect(feature.lastReadURL == nil)

        // Nothing was written by the cancelled attempt.
        #expect(seam.writeAtomicallyCallCount == writesBeforeTheCancel, "the cancelled attempt wrote nothing")
        #expect(seam.writeDestinations.map(\.path) == [committed.path])
        #expect(feature.writeAttemptCount == 1)
        #expect(try Data(contentsOf: committed) == Data("first revision\n".utf8),
                "the file on disk still holds the committed revision, not the cancelled edit")
        #expect(try openSaveTestEntries(scratch) == ["committed.txt"])
        #expect(log.kinds == [.savePanelAsked, .writeAttempted, .savePanelAsked])
        #expect(permissions.activeScopeCount == 0)
    }

    @Test("ACC-...-03: an attempt cancelled before it starts presents no panel and touches nothing")
    func attemptCancelledBeforeEntryTouchesNothing() async throws {
        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log)
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)
        feature.documentText = "never committed\n"

        // Deterministic handshake: the task is parked, cancelled, and only then released into
        // the operation, which therefore observes the cancellation on entry.
        let openHandshake = OpenSaveTestHandshake()
        let openTask = Task { () -> OpenSaveTestFeature.PanelOutcome in
            await openHandshake.park()
            return await feature.chooseOpenDestination()
        }
        openTask.cancel()
        await openHandshake.open()
        let openOutcome = await openTask.value

        #expect(openOutcome.state == .cancelled)
        #expect(openOutcome.url == nil)
        #expect(openOutcome.cancelled)
        #expect(feature.openPanelPresentationCount == 0, "an interrupted attempt presents no panel")
        #expect(feature.readAttemptCount == 0)
        #expect(feature.lastErrorAlert == nil)
        #expect(panel.openAskCount == 0)
        #expect(seam.reads.isEmpty)

        let saveHandshake = OpenSaveTestHandshake()
        let saveTask = Task { () -> OpenSaveTestFeature.PanelOutcome in
            await saveHandshake.park()
            return await feature.chooseSaveDestination(suggestedName: "Untitled.txt")
        }
        saveTask.cancel()
        await saveHandshake.open()
        let saveOutcome = await saveTask.value

        #expect(saveOutcome.state == .cancelled)
        #expect(saveOutcome.url == nil)
        #expect(saveOutcome.cancelled)
        #expect(feature.savePanelPresentationCount == 0)
        #expect(feature.writeAttemptCount == 0)
        #expect(feature.lastSavedURL == nil)
        #expect(panel.saveAskCount == 0)
        #expect(seam.writeDestinations.isEmpty)
        #expect(seam.touchedPaths.isEmpty, "an interrupted attempt reaches no path at all")
        #expect(log.kinds.isEmpty)
        #expect(permissions.activeScopeCount == 0)
    }

    // MARK: - ACC-04: the panels list only .txt, asserted on the real configuration

    @Test("ACC-...-04: the real open and save panels are restricted to plain-text .txt")
    func theRealPanelsAreRestrictedToPlainText() async {
        let panels = await OpenSaveTestPanelFixture.panels()
        let openPanel = panels.open
        let savePanel = panels.save

        #expect(OpenSaveTestFeature.allowedFileExtension == PermissionCoordinator.allowedFileExtension)
        #expect(OpenSaveTestFeature.allowedFileExtension == "txt")

        // The open panel: one content type, plain text, whose own extension is .txt.
        #expect(openPanel.allowedContentTypes.count == 1, "one content type only: plain text")
        #expect(openPanel.allowedContentTypes == [.plainText])
        #expect(openPanel.allowedContentTypes.first?.identifier == UTType.plainText.identifier)
        #expect(openPanel.allowedContentTypes.first?.preferredFilenameExtension == OpenSaveTestFeature.allowedFileExtension,
                "plain text maps to .txt, so only .txt notes are selectable")
        #expect(UTType(filenameExtension: OpenSaveTestFeature.allowedFileExtension)?.conforms(to: .plainText) == true)
        #expect(openPanel.allowsMultipleSelection == false, "one note at a time")
        #expect(openPanel.canChooseFiles == true)
        #expect(openPanel.canChooseDirectories == false, "a folder is not a note location")
        #expect(openPanel.canCreateDirectories == false)
        #expect(openPanel.isVisible == false, "configuring the panel must not present any UI")

        // The save panel: the same restriction, and it cannot be widened by a typed extension.
        #expect(savePanel.allowedContentTypes.count == 1)
        #expect(savePanel.allowedContentTypes == [.plainText])
        #expect(savePanel.allowedContentTypes.first?.preferredFilenameExtension == OpenSaveTestFeature.allowedFileExtension)
        #expect(savePanel.allowsOtherFileTypes == false)
        #expect(savePanel.isExtensionHidden == false)
        #expect(savePanel.nameFieldStringValue == "Draft.txt", "the suggested name is carried verbatim")
        #expect(savePanel.isVisible == false)
    }

    @Test("ACC-...-04: a selection outside .txt is refused by this owner, leaving state and files alone")
    func aSelectionOutsideTxtIsRefused() async throws {
        let scratch = try openSaveTestScratchDirectory()
        let (suiteName, defaults) = try openSaveTestDefaultsSuite()
        defer {
            openSaveTestRemove(scratch)
            openSaveTestDiscardSuite(suiteName)
        }

        let refusedRead = scratch.appendingPathComponent("essay.md")
        let refusedDestination = scratch.appendingPathComponent("Saved.md")
        try openSaveTestWriteNote(named: "essay.md", text: "not a note\n", in: scratch)

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(log: log)
        // A real store sits behind the seam, so the successful retry's read and write are real
        // file operations whose bytes can be asserted.
        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let seam = OpenSaveTestNoteFileAccess(log: log, forwarding: store)
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)
        feature.documentText = "buffer\n"

        panel.scriptOpen(refusedRead)
        let refusedOpen = await feature.chooseOpenDestination()

        #expect(refusedOpen.state == .failed)
        #expect(refusedOpen.adoptedURL == nil)
        #expect(feature.lastReadText == nil, "nothing was read, so no document was adopted")
        #expect(seam.reads.isEmpty, "a refused location is never read")
        let openAlert = try #require(feature.lastErrorAlert)
        #expect(openAlert.title == OpenSaveTestFeature.openFailureAlertTitle)
        #expect(openAlert.message.contains("essay.md"))

        panel.scriptSave(refusedDestination)
        let refusedSave = await feature.chooseSaveDestination(suggestedName: "Saved.md")

        #expect(refusedSave.state == .failed)
        #expect(refusedSave.adoptedURL == nil)
        #expect(seam.writeDestinations.isEmpty, "a refused destination is never written")
        #expect(feature.lastSavedURL == nil)
        let saveAlert = try #require(feature.lastErrorAlert)
        #expect(saveAlert.title == OpenSaveTestFeature.saveFailureAlertTitle)
        #expect(saveAlert.message.contains("Saved.md"))

        #expect(try openSaveTestEntries(scratch) == ["essay.md"], "no file was created or changed")
        #expect(try Data(contentsOf: refusedRead) == Data("not a note\n".utf8))
        #expect(permissions.activeScopeCount == 0, "a refused location leaks no scope")

        // An explicit retry with a .txt location succeeds and dismisses the alert.
        let note = scratch.appendingPathComponent("note.txt")
        try openSaveTestWriteNote(named: "note.txt", text: "a real note\n", in: scratch)
        panel.scriptOpen(note)
        panel.scriptSave(note)
        let retriedOpen = await feature.chooseOpenDestination()
        #expect(retriedOpen.state == .succeeded)
        #expect(retriedOpen.url?.path == note.path)
        #expect(feature.lastReadText == "a real note\n", "the retry reads the real note")
        #expect(feature.lastErrorAlert == nil, "the retry clears the refusal alert")
        let retriedSave = await feature.chooseSaveDestination(suggestedName: "note.txt")
        #expect(retriedSave.state == .succeeded)
        #expect(retriedSave.adoptedURL?.path == note.path)
        #expect(try Data(contentsOf: note) == Data("buffer\n".utf8))
        #expect(try openSaveTestEntries(scratch) == ["essay.md", "note.txt"])
        #expect(permissions.activeScopeCount == 0)
    }

    // MARK: - Failure branches: the open path

    @Test("An unreadable selection presents the locked open alert, adopts nothing, and a retry succeeds")
    func unreadableSelectionReportsTheLockedOpenAlert() async throws {
        let scratch = try openSaveTestScratchDirectory()
        let (suiteName, defaults) = try openSaveTestDefaultsSuite()
        defer {
            openSaveTestRemove(scratch)
            openSaveTestDiscardSuite(suiteName)
        }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let open = try openSaveTestWriteNote(named: "open.txt", text: "the document that is open\n", in: scratch)
        let missing = scratch.appendingPathComponent("gone.txt")

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(openAnswers: [open, missing], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, forwarding: store)
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)

        let firstOpen = await feature.chooseOpenDestination()
        #expect(firstOpen.state == .succeeded)
        #expect(feature.lastReadText == "the document that is open\n")

        // The user selects a note that cannot be read.
        let failed = await feature.chooseOpenDestination()

        #expect(failed.state == .failed)
        #expect(failed.adoptedURL == nil, "a failed read hands nothing to adopt")
        #expect(failed.url?.path == missing.path, "the outcome names the path it addressed")
        #expect(feature.openState == .failed)
        #expect(seam.reads.map(\.path) == [open.path, missing.path], "exactly the selection was read")
        #expect(seam.writeDestinations.isEmpty, "a failed read writes nothing")

        let alert = try #require(feature.lastErrorAlert, "a failed read presents the modal alert")
        #expect(alert.title == "Could Not Open Note")
        #expect(alert.title == OpenSaveTestFeature.openFailureAlertTitle)
        #expect(alert.title == OpenAndEditAPlainTextNoteFeature.openFailureAlertTitle,
                "the same locked title the open-and-edit owner reports")
        #expect(alert.message.contains(missing.path), "the alert names the file")
        #expect(alert.message.contains("the file does not exist"), "the alert names the read error")

        // The last valid user state: the document that was open is still the document.
        #expect(feature.lastReadURL?.path == open.path)
        #expect(feature.lastReadText == "the document that is open\n")
        #expect(feature.lastSavedURL == nil)
        #expect(openSaveTestTree(scratch) == [openSaveTestResolvedPath(open)],
                "nothing was created, changed or removed")
        #expect(permissions.activeScopeCount == 0)

        // An explicit retry reads the note the user chooses next and dismisses the alert.
        panel.scriptOpen(open)
        let retried = await feature.chooseOpenDestination()
        #expect(retried.state == .succeeded)
        #expect(feature.lastErrorAlert == nil)
        #expect(feature.lastReadText == "the document that is open\n")
        #expect(recorder.mainThreadViolations == 0)
    }

    @Test("A file that is not valid UTF-8 reports the decoding reason and leaves the document alone")
    func aFileThatIsNotUTF8ReportsTheDecodingReason() async throws {
        let scratch = try openSaveTestScratchDirectory()
        let (suiteName, defaults) = try openSaveTestDefaultsSuite()
        defer {
            openSaveTestRemove(scratch)
            openSaveTestDiscardSuite(suiteName)
        }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let open = try openSaveTestWriteNote(named: "open.txt", text: "kept\n", in: scratch)
        let binary = scratch.appendingPathComponent("binary.txt")
        try Data([0x48, 0x69, 0xFF, 0xFE, 0x0A]).write(to: binary)

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(openAnswers: [open, binary], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, forwarding: store)
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)

        let first = await feature.chooseOpenDestination()
        #expect(first.state == .succeeded)

        let failed = await feature.chooseOpenDestination()

        #expect(failed.state == .failed)
        #expect(failed.url?.path == binary.path)
        let alert = try #require(feature.lastErrorAlert)
        #expect(alert.title == "Could Not Open Note")
        #expect(alert.message.contains("not valid UTF-8"))
        #expect(feature.lastReadURL?.path == open.path, "the last valid document stays open")
        #expect(feature.lastReadText == "kept\n", "no fabricated text is adopted")
        #expect(try Data(contentsOf: binary) == Data([0x48, 0x69, 0xFF, 0xFE, 0x0A]))
        #expect(permissions.activeScopeCount == 0)
    }

    @Test("An interrupted read reports .cancelled, raises no alert and adopts nothing")
    func anInterruptedReadIsCancelled() async throws {
        let scratch = try openSaveTestScratchDirectory()
        defer { openSaveTestRemove(scratch) }

        let note = scratch.appendingPathComponent("interrupted.txt")
        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(openAnswers: [note], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, failures: [note: CancellationError()])
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)

        let outcome = await feature.chooseOpenDestination()

        #expect(outcome.state == .cancelled, "an interruption is a cancellation, never a failure")
        #expect(outcome.cancelled)
        #expect(outcome.url == nil)
        #expect(outcome.adoptedURL == nil)
        #expect(feature.lastErrorAlert == nil, "a cancellation is not an error, so no alert")
        #expect(feature.lastReadURL == nil)
        #expect(feature.lastReadText == nil)
        #expect(feature.openPanelPresentationCount == 1, "the panel was presented before the interruption")
        #expect(feature.readAttemptCount == 1, "the read was attempted")
        #expect(seam.reads.map(\.path) == [note.path])
        #expect(seam.writeDestinations.isEmpty)
        #expect(permissions.activeScopeCount == 0, "the interrupted read releases its scope")
    }

    // MARK: - Failure branches: the save path

    @Test("A failed Save As leaves the destination bytes unchanged, removes its temporary file, and a retry succeeds")
    func aFailedSaveAsLeavesTheDestinationUnchanged() async throws {
        let scratch = try openSaveTestScratchDirectory()
        let (suiteName, defaults) = try openSaveTestDefaultsSuite()
        defer {
            openSaveTestRemove(scratch)
            openSaveTestDiscardSuite(suiteName)
        }

        let recorder = FileIOThreadRecorder()
        let destination = scratch.appendingPathComponent("note.txt")
        try Data("previous revision\n".utf8).write(to: destination)

        // The real writer with a rename that fails: the whole atomic-save failure branch.
        let failingStore = DataStore(
            defaults: defaults,
            recorder: recorder,
            rename: openSaveTestFailingRename
        )

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(saveAnswers: [destination, destination], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, forwarding: failingStore)
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)
        feature.documentText = "revision two\n"

        let failed = await feature.chooseSaveDestination(suggestedName: "note.txt")

        #expect(failed.state == .failed)
        #expect(failed.url?.path == destination.path, "the outcome names the destination it addressed")
        #expect(failed.adoptedURL == nil, "a failed save hands no path to adopt")
        #expect(feature.saveState == .failed)
        #expect(feature.lastSavedURL == nil, "the document keeps its last valid path")
        #expect(feature.writeAttemptCount == 1)
        #expect(seam.writeDestinations.map(\.path) == [destination.path])

        let alert = try #require(feature.lastErrorAlert, "a failed Save As presents the modal alert")
        #expect(alert.title == "Could Not Save Note")
        #expect(alert.title == OpenSaveTestFeature.saveFailureAlertTitle)
        #expect(alert.title == ExplicitSaveWithCmdSFeature.failureAlertTitle,
                "the same locked title Cmd+S uses")
        #expect(alert.message.contains(destination.path), "the alert names the path")
        #expect(alert.message.contains("injected rename failure"), "the alert names the write error")
        #expect(alert.message.contains("Cmd+Shift+S"), "the alert names the explicit retry")
        #expect(!alert.message.contains("revision two"), "the alert never carries the buffer")

        // CON-DATA-TEMPORARY-SAVE-FILE: the destination bytes are unchanged and the temporary
        // sibling is gone.
        #expect(try Data(contentsOf: destination) == Data("previous revision\n".utf8),
                "a failed save leaves the destination exactly as it was")
        #expect(try openSaveTestEntries(scratch) == ["note.txt"], "no temporary save file is left behind")
        #expect(permissions.activeScopeCount == 0, "the failed attempt releases its scope")

        // The only recovery path is an explicit retry — a new attempt, through the same seam.
        let workingStore = DataStore(defaults: defaults, recorder: recorder)
        let retrySeam = OpenSaveTestNoteFileAccess(log: log, forwarding: workingStore)
        let retryFeature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: retrySeam)
        retryFeature.documentText = feature.documentText

        let retried = await retryFeature.chooseSaveDestination(suggestedName: "note.txt")

        #expect(retried.state == .succeeded)
        #expect(retried.adoptedURL?.path == destination.path)
        #expect(retryFeature.lastErrorAlert == nil, "the successful retry dismisses the alert")
        #expect(retryFeature.lastSavedURL?.path == destination.path)
        #expect(try Data(contentsOf: destination) == Data("revision two\n".utf8))
        #expect(try openSaveTestEntries(scratch) == ["note.txt"])
        #expect(permissions.activeScopeCount == 0)
        #expect(recorder.mainThreadViolations == 0)
    }

    @Test("A write the seam rejects reports the locked save alert and keeps the last valid path")
    func aRejectedWriteReportsTheLockedSaveAlert() async throws {
        let scratch = try openSaveTestScratchDirectory()
        defer { openSaveTestRemove(scratch) }

        let destination = scratch.appendingPathComponent("rejected.txt")
        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(saveAnswers: [destination], log: log)
        let seam = OpenSaveTestNoteFileAccess(
            log: log,
            failures: [destination: OpenSaveTestFailure(reason: "the volume is read-only")]
        )
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)
        feature.documentText = "the buffer that could not be written\n"

        let outcome = await feature.chooseSaveDestination(suggestedName: "rejected.txt")

        #expect(outcome.state == .failed)
        #expect(outcome.adoptedURL == nil)
        #expect(feature.lastSavedURL == nil)
        #expect(feature.documentText == "the buffer that could not be written\n",
                "a failed save does not consume the buffer")
        let alert = try #require(feature.lastErrorAlert)
        #expect(alert.title == "Could Not Save Note")
        #expect(alert.message.contains(destination.path))
        #expect(alert.message.contains("the volume is read-only"))
        #expect(seam.writeDestinations.map(\.path) == [destination.path])
        #expect(try openSaveTestEntries(scratch).isEmpty, "nothing was created")
        #expect(permissions.activeScopeCount == 0)
    }

    @Test("An interrupted write reports .cancelled, raises no alert and writes nothing")
    func anInterruptedWriteIsCancelled() async throws {
        let scratch = try openSaveTestScratchDirectory()
        defer { openSaveTestRemove(scratch) }

        let destination = scratch.appendingPathComponent("interrupted.txt")
        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(saveAnswers: [destination], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, failures: [destination: CancellationError()])
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)
        feature.documentText = "never written\n"

        let outcome = await feature.chooseSaveDestination(suggestedName: "interrupted.txt")

        #expect(outcome.state == .cancelled)
        #expect(outcome.cancelled)
        #expect(outcome.url?.path == destination.path, "the cancelled attempt still names its destination")
        #expect(outcome.adoptedURL == nil)
        #expect(feature.lastErrorAlert == nil)
        #expect(feature.lastSavedURL == nil)
        #expect(feature.writeAttemptCount == 1)
        #expect(seam.writeDestinations.map(\.path) == [destination.path])
        #expect(try openSaveTestEntries(scratch).isEmpty)
        #expect(permissions.activeScopeCount == 0)
    }

    // MARK: - The same atomic writer as Cmd+S

    @Test("Save As uses the same atomic writer as Cmd+S — counted on one shared seam")
    func saveAsUsesTheSameAtomicWriterAsCmdS() async throws {
        let scratch = try openSaveTestScratchDirectory()
        defer { openSaveTestRemove(scratch) }

        let log = OpenSaveTestCallLog()
        let saveAsDestination = scratch.appendingPathComponent("saved as.txt")
        let cmdSDestination = scratch.appendingPathComponent("cmd s.txt")
        let buffer = "one buffer, two commands\n"

        // ONE seam instance, shared by both owners: every write either command performs is
        // counted on this single object, and `writeAtomically` is its only write entry point.
        let panel = OpenSaveTestPanelPresenter(saveAnswers: [saveAsDestination], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log)
        let permissions = PermissionCoordinator(presenter: panel)
        let panelsFeature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)
        let cmdSFeature = ExplicitSaveWithCmdSFeature(noteFiles: seam, panels: panel)

        panelsFeature.documentText = buffer
        let saveAsOutcome = await panelsFeature.chooseSaveDestination(suggestedName: "saved as.txt")
        let cmdSOutcome = await cmdSFeature.save(
            text: buffer,
            documentURL: cmdSDestination,
            suggestedName: "cmd s.txt"
        )

        #expect(saveAsOutcome.state == .succeeded)
        #expect(cmdSOutcome.state == .succeeded)

        // Both commands committed through the same `writeAtomically` seam, exactly once each,
        // addressed with exactly their own destination and payload.
        #expect(seam.writeAtomicallyCallCount == 2,
                "one atomic write per command, on the SAME seam object")
        #expect(seam.writeDestinations.map(\.path) == [saveAsDestination.path, cmdSDestination.path])
        #expect(seam.writtenPayloads == [buffer, buffer])
        #expect(seam.reads.isEmpty, "neither command reads")
        #expect(panelsFeature.lastSavedURL?.path == saveAsDestination.path)
        #expect(cmdSFeature.lastSavedURL?.path == cmdSDestination.path)
        #expect(permissions.activeScopeCount == 0)
    }

    @Test("Save As and Cmd+S leave the identical on-disk shape through the real store")
    func saveAsAndCmdSShareTheRealAtomicWriter() async throws {
        let scratch = try openSaveTestScratchDirectory()
        let (suiteName, defaults) = try openSaveTestDefaultsSuite()
        defer {
            openSaveTestRemove(scratch)
            openSaveTestDiscardSuite(suiteName)
        }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let saveAsDestination = scratch.appendingPathComponent("saved as.txt")
        let cmdSDestination = scratch.appendingPathComponent("cmd s.txt")
        let buffer = "Úvod — 日本語 ✓\r\nbuffer\n"

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(saveAnswers: [saveAsDestination], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, forwarding: store)
        let permissions = PermissionCoordinator(presenter: panel)
        let panelsFeature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)
        let cmdSFeature = ExplicitSaveWithCmdSFeature(noteFiles: seam, panels: panel)

        panelsFeature.documentText = buffer
        let saveAsOutcome = await panelsFeature.chooseSaveDestination(suggestedName: "saved as.txt")
        let cmdSOutcome = await cmdSFeature.save(
            text: buffer,
            documentURL: cmdSDestination,
            suggestedName: "cmd s.txt"
        )

        #expect(saveAsOutcome.state == .succeeded)
        #expect(cmdSOutcome.state == .succeeded)
        #expect(seam.writeAtomicallyCallCount == 2)

        // Both destinations hold exactly the buffer, and both atomic saves left no temporary
        // sibling — the same writer produced the same shape.
        #expect(try Data(contentsOf: saveAsDestination) == Data(buffer.utf8))
        #expect(try Data(contentsOf: cmdSDestination) == Data(buffer.utf8))
        #expect(try openSaveTestEntries(scratch) == ["cmd s.txt", "saved as.txt"],
                "two atomic saves, two files, no temporary sibling")
        #expect(recorder.totalOperations == 2, "one recorded operation per save")
        #expect(recorder.mainThreadViolations == 0)
        #expect(permissions.activeScopeCount == 0)
    }

    // MARK: - Scope handling and cleanup

    @Test("The access scope of the user-selected location is held during the operation and released after it")
    func theAccessScopeIsHeldThenReleased() async throws {
        let scratch = try openSaveTestScratchDirectory()
        let (suiteName, defaults) = try openSaveTestDefaultsSuite()
        defer {
            openSaveTestRemove(scratch)
            openSaveTestDiscardSuite(suiteName)
        }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let note = try openSaveTestWriteNote(named: "scoped.txt", text: "scoped contents\n", in: scratch)
        let destination = scratch.appendingPathComponent("written.txt")

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(openAnswers: [note], saveAnswers: [destination], log: log)
        let probe = OpenSaveTestScopeProbe()
        let seam = OpenSaveTestNoteFileAccess(log: log, probe: probe, forwarding: store)
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)
        probe.feature = feature
        probe.permissions = permissions

        // Measured, not assumed: a real note and a real directory in this scratch location are
        // bookmarkable, so the coordinator really holds a scope while they are in use.
        #expect(PermissionCoordinator.securityScopedBookmarkData(for: note) != nil)
        #expect(PermissionCoordinator.securityScopedBookmarkData(for: scratch) != nil)

        let openOutcome = await feature.chooseOpenDestination()
        #expect(openOutcome.state == .succeeded)
        #expect(probe.openStatesAtRead == [.active], "the attempt is active while the note is read")
        #expect(probe.scopeCountsAtRead == [1],
                "the user-selected note is held under exactly one access scope while it is read")
        #expect(permissions.activeScopeCount == 0, "and released again on the terminal path")

        feature.documentText = "scoped buffer\n"
        let saveOutcome = await feature.chooseSaveDestination(suggestedName: "written.txt")
        #expect(saveOutcome.state == .succeeded)
        #expect(probe.saveStatesAtWrite == [.active], "the attempt is active while the buffer is written")
        #expect(probe.scopeCountsAtWrite == [1],
                "the destination's own directory is held under exactly one access scope while it is written")
        #expect(permissions.activeScopeCount == 0, "and released again on the terminal path")
    }

    @Test("A terminal path releases exactly the scope it added and never the one another operation holds")
    func aTerminalPathReleasesOnlyItsOwnScope() async throws {
        let scratch = try openSaveTestScratchDirectory()
        defer { openSaveTestRemove(scratch) }

        let held = try openSaveTestWriteNote(named: "held.txt", text: "held\n", in: scratch)
        let note = try openSaveTestWriteNote(named: "chosen.txt", text: "chosen\n", in: scratch)

        let log = OpenSaveTestCallLog()
        let panel = OpenSaveTestPanelPresenter(openAnswers: [note], log: log)
        let seam = OpenSaveTestNoteFileAccess(log: log, texts: [note: "chosen\n"])
        let permissions = PermissionCoordinator(presenter: panel)
        let feature = OpenSaveTestFeature(panels: panel, permissions: permissions, noteFiles: seam)

        #expect(permissions.beginAccess(to: held) == true, "the test itself holds one scope")
        #expect(permissions.activeScopeCount == 1)

        let outcome = await feature.chooseOpenDestination()
        #expect(outcome.state == .succeeded)
        #expect(permissions.activeScopeCount == 1, "the pre-existing scope survives the attempt")

        panel.scriptOpen(nil)
        let cancelled = await feature.chooseOpenDestination()
        #expect(cancelled.cancelled)
        #expect(permissions.activeScopeCount == 1, "a cancelled attempt adds and releases nothing")

        panel.scriptOpen(scratch.appendingPathComponent("gone.txt"))
        let failed = await feature.chooseOpenDestination()
        #expect(failed.state == .failed)
        #expect(permissions.activeScopeCount == 1, "a failed read releases exactly its own scope")

        permissions.endAccess(to: held)
        #expect(permissions.activeScopeCount == 0)
    }

    // MARK: - Structural proofs

    @Test("This owner reaches disk only through the shared seams and re-implements no file I/O")
    func structuralProofOverTheFeatureSource() throws {
        let source = try openSaveTestFeatureSource()

        // Positive: the panel seam chooses every path; the shared note-file seam performs every
        // read and the one write; the permission owner decides what a `.txt` location is.
        #expect(source.contains("panels.chooseExistingNote()"))
        #expect(source.contains("panels.chooseNewNoteDestination(suggestedName: suggestedName)"))
        #expect(source.contains("noteFiles.readUTF8(from: url)"))
        #expect(source.contains("noteFiles.writeAtomically(documentText, to: chosen)"),
                "the buffer is committed through NoteFileAccess.writeAtomically — the SAME writer Cmd+S uses")
        #expect(source.contains("PermissionCoordinator.isAllowedNoteLocation(chosen)"))
        #expect(source.contains("permissions.beginAccess(to:"))
        #expect(source.contains("permissions.endAccess(to:"))
        #expect(source.contains("Could Not Open Note"))
        #expect(source.contains("Could Not Save Note"))

        // Negative: no reader, no writer, no rename, no temporary directory, no second settings
        // store and no network — every one of those belongs to another owner.
        let forbidden = [
            "NSTemporaryDirectory",
            "temporaryDirectory",
            "FileManager",
            "Darwin.",
            "posixRename",
            "moveItem",
            "replaceItemAt",
            "Data(contentsOf",
            "write(to:",
            "func writeAtomically",
            "startAccessingSecurityScopedResource",
            "bookmarkData",
            "UserDefaults",
            "StatusMessage",
            "URLSession",
            "NSURLConnection",
            "CFNetwork",
            "import Network",
        ]
        for token in forbidden {
            #expect(
                !source.contains(token),
                "OpenAndSavePanelsForLocalFilesystemAccessFeature.swift must not contain \(token)"
            )
        }
        #expect(source.contains("import Foundation"), "this owner needs nothing but Foundation")
    }

    @Test("No real panel is ever shown: the suite's presenters are doubles and the panels stay invisible")
    func noRealPanelIsEverShown() async {
        // The placeholder default can only cancel, so an unconfigured owner shows nothing.
        let defaults = OpenSaveTestFeature()
        #expect(defaults.openPanelPresentationCount == 0)

        // The real panels the production presenter builds are configuration objects only: this
        // suite never calls `runModal()`/`begin()` on them.
        let panels = await OpenSaveTestPanelFixture.panels()
        #expect(panels.open.isVisible == false)
        #expect(panels.save.isVisible == false)
    }
}
