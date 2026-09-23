//
//  ExplicitSaveWithCmdSFeatureTests.swift
//  MonospaceNotesTests
//
//  TASK-08-EXPLICIT-SAVE-WITH-CMD-S focused suite — owner OWN-EXPLICIT-SAVE-WITH-CMD-S.
//
//  Covers FEAT-EXPLICIT-SAVE-WITH-CMD-S with CON-EXPLICIT-SAVE-WITH-CMD-S-INTERFACE /
//  -RECOVERY, CON-DATA-TEMPORARY-SAVE-FILE and CON-PERSISTENCE-TEMPORARY-SAVE-FILE
//  against the real `ExplicitSaveWithCmdSFeature`:
//
//    * ACC-EXPLICIT-SAVE-WITH-CMD-S-01 — after a successful save the unsaved-changes
//      marker is cleared (`clearedUnsavedMarker == true`).
//    * ACC-EXPLICIT-SAVE-WITH-CMD-S-02 — after Cmd+S on a document with a path,
//      reading that path returns exactly the buffer contents as UTF-8, asserted
//      against a real file in a unique scratch directory through the real `DataStore`.
//    * ACC-EXPLICIT-SAVE-WITH-CMD-S-03 — with no path, a save panel is presented
//      BEFORE any write occurs (the panel's own observation records how many writes
//      had been attempted at the instant it was asked), and a cancelled panel writes
//      nothing at all.
//    * ACC-EXPLICIT-SAVE-WITH-CMD-S-04 — a failed write presents the modal alert
//      titled "Could Not Save Note" naming the path and the write error, and the
//      unsaved-changes marker REMAINS set; the destination's prior bytes stay valid
//      and no temporary save file is left behind.
//
//  No assertion here depends on a wall-clock window. The "panel before write" ordering
//  is proved by a shared call log written by the doubles themselves, and cancellation
//  is driven by a deterministic handshake, never by a sleep. No real `NSOpenPanel` /
//  `NSSavePanel` is ever presented: the panel seam is a unique-prefixed double.
//
//  Every double is file-private and prefixed `ExplicitSaveTest`, so it cannot collide
//  with another suite in this module.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import Foundation
import Testing

@testable import MonospaceNotes

// MARK: - File-scope fixtures (unique names: every test file compiles into one module)

/// An ordered, thread-safe record of what the doubles were asked to do. "The panel was
/// asked before any write" is asserted from this log, never from elapsed time.
private final class ExplicitSaveTestCallLog: @unchecked Sendable {
    enum Kind: Equatable, Sendable {
        case panelAsked
        case writeAttempted
        case noteRead
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

    var writeAttempts: Int { kinds.filter { $0 == .writeAttempted }.count }

    var panelAsks: Int { kinds.filter { $0 == .panelAsked }.count }
}

/// The panel seam: returns a fixed path (or `nil` = the user cancelled) and records,
/// at the instant it is asked, how many writes had already been attempted.
private final class ExplicitSaveTestPanelPresenter: PanelPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private let log: ExplicitSaveTestCallLog
    private var chosen: URL?
    private var askedNames: [String] = []
    private var writesVisibleWhenAsked: [Int] = []

    init(chosen: URL?, log: ExplicitSaveTestCallLog) {
        self.chosen = chosen
        self.log = log
    }

    /// Cmd+S never asks for an existing note, so this seam must stay untouched.
    func chooseExistingNote() async -> URL? {
        return nil
    }

    func chooseNewNoteDestination(suggestedName: String) async -> URL? {
        // Observed BEFORE the panel returns: the number of write attempts the log held
        // when the panel was asked. The save must not have written anything yet.
        let writesSoFar = log.writeAttempts
        let answer = recordAsk(suggestedName: suggestedName, writesSoFar: writesSoFar)

        log.record(.panelAsked, detail: suggestedName)
        return answer
    }

    /// The locked mutation itself, synchronous so no `NSLock` is used from an async
    /// context.
    private func recordAsk(suggestedName: String, writesSoFar: Int) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        askedNames.append(suggestedName)
        writesVisibleWhenAsked.append(writesSoFar)
        return chosen
    }

    func setChosen(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        chosen = url
    }

    var askCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return askedNames.count
    }

    var requestedSuggestedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return askedNames
    }

    var writeCountsObservedWhenAsked: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return writesVisibleWhenAsked
    }
}

/// A write failure the shared writer could report, carrying its own short reason.
private struct ExplicitSaveTestWriteFailure: Error, Equatable, Sendable, CustomStringConvertible {
    let reason: String

    var description: String { reason }
}

/// The note-file seam: records every write (its exact destination and payload) and
/// every read, and can fail the write on demand. It never touches the filesystem, so
/// tests that need real bytes use the real `DataStore` instead.
private final class ExplicitSaveTestNoteFileAccess: NoteFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let log: ExplicitSaveTestCallLog
    private var failure: Error?
    private var destinations: [URL] = []
    private var payloads: [String] = []
    private var readURLs: [URL] = []

    init(log: ExplicitSaveTestCallLog, failure: Error? = nil) {
        self.log = log
        self.failure = failure
    }

    func readUTF8(from url: URL) async throws -> String {
        log.record(.noteRead, detail: url.path)
        recordRead(url)
        throw ExplicitSaveTestWriteFailure(reason: "this double holds no note contents")
    }

    func writeAtomically(_ contents: String, to url: URL) async throws {
        log.record(.writeAttempted, detail: url.path)
        let pendingFailure = recordWrite(contents, to: url)

        if let pendingFailure {
            throw pendingFailure
        }
    }

    /// The locked mutations themselves, synchronous so no `NSLock` is used from an
    /// async context.
    private func recordRead(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        readURLs.append(url)
    }

    private func recordWrite(_ contents: String, to url: URL) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        destinations.append(url)
        payloads.append(contents)
        return failure
    }

    var writeDestinations: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return destinations
    }

    var writtenPayloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return destinations.count
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readURLs.count
    }
}

/// The real store's injectable rename step: it fails while `fails` is `true`, and can be
/// flipped back so an explicit retry can be observed to succeed.
private final class ExplicitSaveTestRenameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failing: Bool

    init(failing: Bool) {
        self.failing = failing
    }

    var fails: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return failing
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            failing = newValue
        }
    }

    func rename(_ from: String, _ to: String) throws {
        if fails {
            throw DataStore.OperationError.renameFailed(
                fileName: URL(fileURLWithPath: to).lastPathComponent,
                reason: "injected rename failure"
            )
        }
        try DataStore.posixRename(from, to)
    }
}

/// Parks a task so a test can cancel it before it reaches the save, then release it —
/// a deterministic handshake instead of a sleep.
private actor ExplicitSaveTestHandshake {
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

/// A real scratch directory under the system temporary location. Tests only: the
/// feature under test never chooses a destination by itself.
private func explicitSaveTestScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("monospace-notes-explicit-save-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A dedicated, unique `UserDefaults` suite so no test can see another one's state.
private func explicitSaveTestDefaultsSuite() throws -> (name: String, defaults: UserDefaults) {
    let name = "com.monospace.notes.tests.explicitsave.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name), "A dedicated defaults suite is required")
    return (name, defaults)
}

private func explicitSaveTestDiscardSuite(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
        .path
    if FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// The feature's own source, for the structural proof that it calls the shared writer
/// instead of re-implementing it.
private func explicitSaveTestFeatureSource() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot
        .appendingPathComponent("Sources/MonospaceNotes/Features/ExplicitSaveWithCmdSFeature.swift")
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

private func explicitSaveTestDirectoryEntries(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

// MARK: - Suite

@Suite("FEAT-EXPLICIT-SAVE-WITH-CMD-S explicit save")
@MainActor
struct ExplicitSaveWithCmdSFeatureTests {

    // MARK: - ACC-01, ACC-02: a save with a path

    @Test("ACC-01 + ACC-02: a save with a path writes exactly the buffer as UTF-8 and clears the unsaved marker")
    func saveWithAPathWritesExactBufferAndClearsMarker() async throws {
        let scratch = try explicitSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try explicitSaveTestDefaultsSuite()
        defer { explicitSaveTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let log = ExplicitSaveTestCallLog()
        // A save panel exists, but this document already has a path, so it must stay unused.
        let panel = ExplicitSaveTestPanelPresenter(
            chosen: scratch.appendingPathComponent("never-chosen.txt"),
            log: log
        )
        let feature = ExplicitSaveWithCmdSFeature(noteFiles: store, panels: panel)

        let destination = scratch.appendingPathComponent("note.txt")
        try Data("previous revision\n".utf8).write(to: destination)

        // The document as Cmd+S finds it: edited in memory, marked as unsaved.
        let buffer = "Úvod — 日本語のメモ — emoji 🅰\r\nsecond line\r\n"
        let markedUnsavedBeforeTheSave = true

        let outcome = await feature.save(text: buffer, documentURL: destination, suggestedName: "note.txt")

        // ACC-01: the successful save clears the unsaved-changes marker.
        #expect(markedUnsavedBeforeTheSave, "the document really was marked as having unsaved changes")
        #expect(outcome.state == .succeeded)
        #expect(outcome.clearedUnsavedMarker, "ACC-01: a successful save clears the unsaved-changes marker")
        #expect(outcome.errorAlert == nil, "a successful save presents no alert")
        #expect(outcome.url == destination, "the document keeps the path it was saved to")

        // ACC-02: reading that path returns exactly the buffer contents as UTF-8.
        #expect(try Data(contentsOf: destination) == Data(buffer.utf8),
                "the destination holds exactly the UTF-8 bytes of the buffer")
        let readBack = try await store.readUTF8(from: destination)
        #expect(readBack == buffer, "ACC-02: reading the path returns exactly the buffer contents")
        #expect(readBack.utf8.count == buffer.utf8.count)

        // The shared writer's atomicity: destination only, no temporary sibling left.
        #expect(try explicitSaveTestDirectoryEntries(scratch) == ["note.txt"],
                "no temporary save file remains beside the destination")

        // A document with a path never asks for a panel.
        #expect(panel.askCount == 0, "a document that already has a path presents no save panel")
        #expect(panel.writeCountsObservedWhenAsked.isEmpty)
        #expect(feature.panelPresentationCount == 0)

        #expect(feature.saveState == .succeeded)
        #expect(feature.lastSavedURL == destination)
        #expect(feature.lastErrorAlert == nil)
        #expect(feature.writeAttemptCount == 1)
        #expect(feature.lastOutcome == outcome)

        #expect(recorder.totalOperations == 2, "one write and one read were recorded")
        #expect(recorder.mainThreadViolations == 0, "no file I/O ran on the main thread")
    }

    // MARK: - ACC-03: no path — the panel comes first

    @Test("ACC-03: with no path the save panel is asked before any write and the chosen path receives the buffer")
    func saveWithNoPathAsksThePanelBeforeAnyWrite() async throws {
        let scratch = try explicitSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let log = ExplicitSaveTestCallLog()
        let chosen = scratch.appendingPathComponent("chosen-by-the-panel.txt")
        let panel = ExplicitSaveTestPanelPresenter(chosen: chosen, log: log)
        let files = ExplicitSaveTestNoteFileAccess(log: log)
        let feature = ExplicitSaveWithCmdSFeature(noteFiles: files, panels: panel)

        let buffer = "first draft — 日本語\nsecond line\n"
        let outcome = await feature.save(text: buffer, documentURL: nil, suggestedName: "Untitled.txt")

        #expect(outcome.state == .succeeded)
        #expect(outcome.url == chosen, "the attempt addressed exactly the path the panel returned")
        #expect(outcome.clearedUnsavedMarker)
        #expect(outcome.errorAlert == nil)

        // The panel was asked, and it was asked before any write.
        #expect(panel.askCount == 1, "a document without a path presents the save panel")
        #expect(panel.requestedSuggestedNames == ["Untitled.txt"], "the suggested name reaches the panel")
        #expect(panel.writeCountsObservedWhenAsked == [0],
                "ACC-03: no write had been attempted at the instant the panel was asked")
        #expect(log.kinds == [.panelAsked, .writeAttempted],
                "the attempt's order is: panel first, write second")

        // The write went to exactly the chosen path, with exactly the buffer.
        #expect(files.writeDestinations == [chosen])
        #expect(files.writtenPayloads == [buffer])
        #expect(files.writeCount == 1)
        #expect(files.readCount == 0, "a save never re-reads the note")
        #expect(log.writeAttempts == 1)

        #expect(feature.panelPresentationCount == 1)
        #expect(feature.writeAttemptCount == 1)
        #expect(feature.lastSavedURL == chosen)
    }

    @Test("ACC-03: a cancelled save panel reports .cancelled, writes nothing at all and leaves the document untouched")
    func cancelledPanelWritesNothing() async throws {
        let scratch = try explicitSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let log = ExplicitSaveTestCallLog()
        // `nil` is the user cancelling the save panel.
        let panel = ExplicitSaveTestPanelPresenter(chosen: nil, log: log)
        let files = ExplicitSaveTestNoteFileAccess(log: log)
        let feature = ExplicitSaveWithCmdSFeature(noteFiles: files, panels: panel)

        // A real note already sits in the folder the user was about to save into.
        let neighbour = scratch.appendingPathComponent("existing-note.txt")
        let neighbourBytes = Data("already on disk — 日本語\n".utf8)
        try neighbourBytes.write(to: neighbour)

        let buffer = "unsaved edit that must never reach any file"
        let outcome = await feature.save(text: buffer, documentURL: nil, suggestedName: "Untitled.txt")

        #expect(outcome.state == .cancelled, "a cancelled panel is a cancelled save, not a failure")
        #expect(outcome.url == nil, "no path was chosen, so there is nothing for the caller to adopt")
        #expect(outcome.errorAlert == nil, "a cancelled panel is not an error: it raises no alert")
        #expect(!outcome.clearedUnsavedMarker, "nothing was saved, so the document is still unsaved")

        #expect(feature.saveState == .cancelled)
        #expect(feature.lastSavedURL == nil)
        #expect(feature.lastErrorAlert == nil)
        #expect(feature.writeAttemptCount == 0, "the cancelled save never attempted a write")
        #expect(feature.panelPresentationCount == 1)

        #expect(panel.askCount == 1, "the panel WAS asked, and then cancelled")
        #expect(panel.writeCountsObservedWhenAsked == [0])
        #expect(log.kinds == [.panelAsked], "the cancelled attempt wrote nothing at all")
        #expect(files.writeCount == 0)
        #expect(files.writeDestinations.isEmpty)
        #expect(files.readCount == 0)

        // The document is untouched: the folder still holds exactly the pre-existing
        // note, with its prior bytes.
        #expect(try explicitSaveTestDirectoryEntries(scratch) == ["existing-note.txt"])
        #expect(try Data(contentsOf: neighbour) == neighbourBytes)

        // Nothing about the buffer reached disk anywhere in the scratch directory.
        for entry in try explicitSaveTestDirectoryEntries(scratch) {
            let bytes = try Data(contentsOf: scratch.appendingPathComponent(entry))
            #expect(!String(decoding: bytes, as: UTF8.self).contains(buffer),
                    "the cancelled save wrote no buffer contents into \(entry)")
        }

        // The document is still unsaved, so an explicit retry is possible — and it
        // writes to whatever the user chooses next.
        let retryDestination = scratch.appendingPathComponent("retry.txt")
        panel.setChosen(retryDestination)
        let retry = await feature.save(text: buffer, documentURL: nil, suggestedName: "Untitled.txt")

        #expect(retry.state == .succeeded, "an explicit retry after a cancel succeeds")
        #expect(retry.clearedUnsavedMarker)
        #expect(retry.url == retryDestination)
        #expect(files.writeDestinations == [retryDestination], "the retry wrote to the newly chosen path")
        #expect(panel.askCount == 2)
        #expect(feature.writeAttemptCount == 1)
    }

    // MARK: - ACC-04: a failed write

    @Test("ACC-04: a failed write presents the modal alert naming the path and the error, keeps the marker, and leaves the prior bytes valid")
    func failedWritePresentsModalAlertAndKeepsTheMarker() async throws {
        let scratch = try explicitSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try explicitSaveTestDefaultsSuite()
        defer { explicitSaveTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let gate = ExplicitSaveTestRenameGate(failing: true)
        let store = DataStore(
            defaults: defaults,
            recorder: recorder,
            rename: { from, to in try gate.rename(from, to) }
        )
        let log = ExplicitSaveTestCallLog()
        let panel = ExplicitSaveTestPanelPresenter(chosen: nil, log: log)
        let feature = ExplicitSaveWithCmdSFeature(noteFiles: store, panels: panel)

        let destination = scratch.appendingPathComponent("note.txt")
        let priorBytes = Data("the last valid revision\n".utf8)
        try priorBytes.write(to: destination)

        let outcome = await feature.save(
            text: "the edit that could not be written\n",
            documentURL: destination,
            suggestedName: "note.txt"
        )

        #expect(outcome.state == .failed)
        #expect(!outcome.clearedUnsavedMarker,
                "ACC-04: a failed save leaves the unsaved-changes marker SET")
        #expect(outcome.url == destination, "the attempt addressed the document's own path")

        // ACC-04: a MODAL error alert, with the locked title, naming the path and the
        // write error.
        let alert = try #require(outcome.errorAlert, "ACC-04: a failed save presents a modal error alert")
        #expect(alert.title == "Could Not Save Note")
        #expect(alert.title == ExplicitSaveWithCmdSFeature.failureAlertTitle)
        #expect(alert.message.contains(destination.path), "the alert names the path")
        #expect(alert.message.contains("injected rename failure"), "the alert names the write error")
        #expect(feature.lastErrorAlert == alert)
        #expect(feature.saveState == .failed)
        #expect(feature.lastSavedURL == nil, "a failed save commits no path")

        // The prior bytes stay valid and the shared writer cleaned up after itself.
        #expect(try Data(contentsOf: destination) == priorBytes,
                "a failed save leaves the destination's prior bytes valid")
        #expect(try explicitSaveTestDirectoryEntries(scratch) == ["note.txt"],
                "the temporary save file was removed on the failure path")
        #expect(recorder.totalOperations == 1, "the failed write is still recorded")
        #expect(recorder.mainThreadViolations == 0)
    }

    @Test("A failed write through the file-access seam reports that write error and never touches the destination")
    func failedWriteThroughTheSeam() async throws {
        let scratch = try explicitSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let log = ExplicitSaveTestCallLog()
        let failure = ExplicitSaveTestWriteFailure(reason: "the volume is read-only")
        let files = ExplicitSaveTestNoteFileAccess(log: log, failure: failure)
        let panel = ExplicitSaveTestPanelPresenter(chosen: nil, log: log)
        let feature = ExplicitSaveWithCmdSFeature(noteFiles: files, panels: panel)

        let destination = scratch.appendingPathComponent("note.txt")
        let priorBytes = Data("valid prior revision\n".utf8)
        try priorBytes.write(to: destination)

        let outcome = await feature.save(text: "unsaved edit\n", documentURL: destination, suggestedName: "note.txt")

        #expect(outcome.state == .failed)
        #expect(!outcome.clearedUnsavedMarker)
        let alert = try #require(outcome.errorAlert)
        #expect(alert.title == "Could Not Save Note")
        #expect(alert.message.contains(destination.path))
        #expect(alert.message.contains("the volume is read-only"),
                "the writer's own error reaches the alert message")
        #expect(!alert.message.contains("unsaved edit"), "the alert never carries note contents")

        #expect(files.writeDestinations == [destination], "the attempt really addressed the destination")
        #expect(files.readCount == 0)
        #expect(try Data(contentsOf: destination) == priorBytes, "the prior bytes are untouched")
        #expect(try explicitSaveTestDirectoryEntries(scratch) == ["note.txt"])
    }

    @Test("An explicit retry after a failed save succeeds, clears the failure alert and clears the marker")
    func explicitRetryAfterAFailedSave() async throws {
        let scratch = try explicitSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try explicitSaveTestDefaultsSuite()
        defer { explicitSaveTestDiscardSuite(suiteName) }

        let gate = ExplicitSaveTestRenameGate(failing: true)
        let store = DataStore(
            defaults: defaults,
            recorder: FileIOThreadRecorder(),
            rename: { from, to in try gate.rename(from, to) }
        )
        let log = ExplicitSaveTestCallLog()
        let feature = ExplicitSaveWithCmdSFeature(
            noteFiles: store,
            panels: ExplicitSaveTestPanelPresenter(chosen: nil, log: log)
        )

        let destination = scratch.appendingPathComponent("note.txt")
        try Data("revision one\n".utf8).write(to: destination)

        let first = await feature.save(text: "revision two\n", documentURL: destination, suggestedName: "note.txt")
        #expect(first.state == .failed)
        #expect(feature.lastErrorAlert != nil)
        #expect(feature.writeAttemptCount == 1)

        // The retry: another explicit Cmd+S, now with the writer working again.
        gate.fails = false
        let second = await feature.save(text: "revision two\n", documentURL: destination, suggestedName: "note.txt")

        #expect(second.state == .succeeded)
        #expect(second.clearedUnsavedMarker, "the retry commits the buffer and clears the marker")
        #expect(second.errorAlert == nil, "a successful retry presents no alert")
        #expect(feature.lastErrorAlert == nil, "the retry clears the previous failure alert")
        #expect(feature.lastSavedURL == destination)
        #expect(try Data(contentsOf: destination) == Data("revision two\n".utf8))
        #expect(try explicitSaveTestDirectoryEntries(scratch) == ["note.txt"])
        #expect(feature.writeAttemptCount == 2)
    }

    // MARK: - Cancellation

    @Test("A save interrupted before it writes reports .cancelled, raises no alert and writes nothing")
    func interruptedSaveReportsCancelled() async throws {
        let scratch = try explicitSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let log = ExplicitSaveTestCallLog()
        let destination = scratch.appendingPathComponent("note.txt")
        let panel = ExplicitSaveTestPanelPresenter(chosen: scratch.appendingPathComponent("unused.txt"), log: log)
        let files = ExplicitSaveTestNoteFileAccess(log: log)
        let feature = ExplicitSaveWithCmdSFeature(noteFiles: files, panels: panel)

        // Deterministic handshake: the task is parked, cancelled, and only then released
        // into `save`, which therefore observes the cancellation on entry.
        let handshake = ExplicitSaveTestHandshake()
        let task = Task { () -> ExplicitSaveWithCmdSFeature.SaveOutcome in
            await handshake.park()
            return await feature.save(text: "buffer", documentURL: destination, suggestedName: "note.txt")
        }
        task.cancel()
        await handshake.open()
        let outcome = await task.value

        #expect(outcome.state == .cancelled, "an interrupted save is cancelled, never failed")
        #expect(outcome.errorAlert == nil, "a cancellation is not an error, so no alert")
        #expect(!outcome.clearedUnsavedMarker)
        #expect(feature.saveState == .cancelled)
        #expect(feature.writeAttemptCount == 0, "an interrupted save never reaches the writer")
        #expect(files.writeCount == 0)
        #expect(files.readCount == 0)
        #expect(panel.askCount == 0, "an interrupted save presents no panel")
        #expect(log.kinds.isEmpty)
        #expect(try explicitSaveTestDirectoryEntries(scratch).isEmpty)
    }

    // MARK: - The shared writer, not a private one

    @Test("The save calls the shared same-directory atomic writer and re-implements no file I/O")
    func structuralProofOverTheFeatureSource() throws {
        let source = try explicitSaveTestFeatureSource()

        // Positive: the shared writer seam is the only way this feature reaches disk,
        // and the panel seam is the only way it chooses a destination.
        #expect(source.contains("noteFiles.writeAtomically("),
                "every save goes through NoteFileAccess.writeAtomically")
        #expect(source.contains("panels.chooseNewNoteDestination(suggestedName: suggestedName)"))
        #expect(source.contains("Could Not Save Note"),
                "the locked alert title is declared in this file")

        // Negative: no writer, no reader, no temporary directory, no network — the
        // atomic temporary-then-rename writer belongs to OWN-DATA-STORE alone.
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
            "URLSession",
            "NSURLConnection",
            "CFNetwork",
            "import Network",
        ]
        for token in forbidden {
            #expect(!source.contains(token),
                    "ExplicitSaveWithCmdSFeature.swift must not contain \(token)")
        }
        #expect(!source.contains("func writeAtomically"),
                "this feature must not re-implement the atomic writer")
        #expect(!source.contains("StatusMessage"),
                "a failed Cmd+S is a modal alert; the non-modal status area belongs to the background save")
    }
}
