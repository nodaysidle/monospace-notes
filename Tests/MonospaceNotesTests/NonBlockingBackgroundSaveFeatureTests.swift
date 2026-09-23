//
//  NonBlockingBackgroundSaveFeatureTests.swift
//  MonospaceNotesTests
//
//  TASK-10-NON-BLOCKING-BACKGROUND-SAVE focused suite — owner
//  OWN-NON-BLOCKING-BACKGROUND-SAVE.
//
//  Covers FEAT-NON-BLOCKING-BACKGROUND-SAVE with
//  CON-NON-BLOCKING-BACKGROUND-SAVE-INTERFACE / -RECOVERY, CON-DATA-TEMPORARY-SAVE-FILE
//  and CON-PERSISTENCE-TEMPORARY-SAVE-FILE against the real feature:
//
//    * ACC-NON-BLOCKING-BACKGROUND-SAVE-01 — a failed background save produces a visible
//      NON-MODAL status message naming the path (`statusMessage.isFailure == true`, the
//      text carries the path), no unsaved marker is cleared, the destination keeps its
//      bytes — and the feature has no way to build a modal alert at all, proved
//      structurally over its source.
//    * ACC-NON-BLOCKING-BACKGROUND-SAVE-02 — after a successful background save the
//      destination contains exactly the buffer as UTF-8 and NO temporary file remains in
//      the destination's own directory: asserted from the real directory listing and from
//      the feature's own verification, against a real `DataStore` in a unique scratch
//      directory.
//    * ACC-NON-BLOCKING-BACKGROUND-SAVE-03 — during a background save, a keystroke reaches
//      a real TextKit 2 `NSTextView` before the save completes. Ordered by a deterministic
//      handshake (a writer that parks until the test releases it) and a recorded event
//      log, never by a sleep and never by a wall-clock window.
//    * ACC-NON-BLOCKING-BACKGROUND-SAVE-04 — if the rename fails, the destination's bytes
//      are unchanged from before the attempt (real `DataStore` with an injected failing
//      rename), and no temporary sibling is left behind.
//
//  Also covered: the autosave interval is exactly 30000 ms from the last edit and every
//  edit resets it — asserted on an INJECTED clock, not by sleeping 30 seconds; `cancel()`
//  interrupts both the armed timer and an in-flight save and leaves nothing running;
//  every terminal path (success, temporary-write failure, rename failure, interruption,
//  no destination, temporary file left behind) leaves nothing running and reports in
//  exactly one way; a document with no path is skipped without inventing a destination;
//  the cleanup verification really recognises the shared writer's temporary sibling.
//
//  Every test double is declared at file scope and prefixed `BackgroundSaveTest`, so it
//  cannot collide with another suite in this module.
//
//  Swift Testing only: no XCTest, no placeholder assertions, no `#expect(true)`.
//

import AppKit
import Foundation
import Testing

@testable import MonospaceNotes

// MARK: - File-scope fixtures (unique names: every test file compiles into one module)

/// What happened, in order. Ordering is asserted from recorded events, never from
/// elapsed time.
private final class BackgroundSaveTestEventLog: @unchecked Sendable {
    enum Event: String, Sendable, Equatable {
        case saveStarted
        case writerEntered
        case writerWrote
        case keystrokeApplied
        case saveCompleted
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func record(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var recorded: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func firstIndex(of event: Event) -> Int? {
        recorded.firstIndex(of: event)
    }
}

/// A deterministic park/release handshake shared by the test doubles. A parked wait is
/// resumed only by the test (or by the cancellation of the task that parked), so no test
/// depends on a wall-clock window; and the wait also reports how many waits it has
/// registered, which is the other half of the handshake.
private final class BackgroundSaveTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextToken = 0
    private var parkedCountValue = 0
    private var requestCountValue = 0
    private var requests: [Int] = []
    private var requestWaiters: [(required: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Parks until `release()` or `cancelAll()`, or throws `CancellationError` when the
    /// waiting task is cancelled — including a task that was already cancelled on entry.
    func park(milliseconds: Int? = nil) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                register(continuation, milliseconds: milliseconds)
                if Task.isCancelled {
                    resumeAll(throwing: CancellationError())
                }
            }
        } onCancel: {
            self.resumeAll(throwing: CancellationError())
        }
    }

    /// Lets every parked wait finish normally.
    @discardableResult
    func release() -> Int {
        resumeAll(throwing: nil)
    }

    /// Cancels every parked wait.
    @discardableResult
    func cancelAll() -> Int {
        resumeAll(throwing: CancellationError())
    }

    var parkedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return parkedCountValue
    }

    /// How many waits have been registered in total — never decreases, so a test can wait
    /// for the NEXT wait as well as the first one.
    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCountValue
    }

    var requestedMilliseconds: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    /// The handshake: waits until at least `count` waits have been registered.
    func waitForRequestCount(atLeast count: Int) async {
        if requestCount >= count { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if registerRequestWaiter(count, continuation) {
                continuation.resume()
            }
        }
    }

    /// Registers a request waiter and reports whether the count is already satisfied (in
    /// which case the caller resumes the continuation itself). Synchronous, so no lock is
    /// taken from an asynchronous context.
    private func registerRequestWaiter(
        _ required: Int,
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if requestCountValue >= required { return true }
        requestWaiters.append((required, continuation))
        return false
    }

    private func register(_ continuation: CheckedContinuation<Void, Error>, milliseconds: Int?) {
        lock.lock()
        let token = nextToken
        nextToken += 1
        waiters[token] = continuation
        parkedCountValue += 1
        requestCountValue += 1
        if let milliseconds {
            requests.append(milliseconds)
        }
        let ready = requestWaiters.filter { $0.required <= requestCountValue }
        requestWaiters.removeAll { $0.required <= requestCountValue }
        lock.unlock()
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    @discardableResult
    private func resumeAll(throwing error: Error?) -> Int {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        parkedCountValue = 0
        lock.unlock()
        for (_, continuation) in pending {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
        return pending.count
    }
}

/// The autosave clock, driven by the test: `elapse()` is "the interval finished".
/// Nothing here depends on a wall clock, and the requested intervals are readable, so the
/// 30000 ms interval is asserted exactly.
private final class BackgroundSaveTestClock: AutosaveClock, @unchecked Sendable {
    private let gate = BackgroundSaveTestGate()
    private let lock = NSLock()
    private var currentMillisecondsValue: Int
    private var intervals: [Int] = []
    private var pendingIntervals: [Int] = []

    init(startingAtMilliseconds: Int = 0) {
        self.currentMillisecondsValue = startingAtMilliseconds
    }

    func nowMilliseconds() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return currentMillisecondsValue
    }

    func sleep(milliseconds: Int) async throws {
        recordSleepRequest(milliseconds)
        try await gate.park(milliseconds: milliseconds)
    }

    /// Synchronous, so no lock is taken from an asynchronous context.
    private func recordSleepRequest(_ milliseconds: Int) {
        lock.lock()
        defer { lock.unlock() }
        intervals.append(milliseconds)
        pendingIntervals.append(milliseconds)
    }

    /// The intervals the timer asked for, in request order.
    var requestedIntervals: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return intervals
    }

    /// How many waits are parked right now.
    var parkedWaitCount: Int { gate.parkedCount }

    /// Waits until at least `count` waits have been asked for (cumulative).
    func waitForSleepRequests(atLeast count: Int) async {
        await gate.waitForRequestCount(atLeast: count)
    }

    /// "The interval elapsed": every parked wait finishes and the clock moves forward by
    /// the intervals those waits asked for.
    func elapse() {
        lock.lock()
        currentMillisecondsValue += pendingIntervals.reduce(0, +)
        pendingIntervals.removeAll()
        lock.unlock()
        gate.release()
    }
}

/// A write failure the shared writer could report, carrying its own short reason.
private struct BackgroundSaveTestWriteFailure: Error, Equatable, Sendable, CustomStringConvertible {
    let reason: String

    var description: String { reason }
}

/// The slow writer: it parks INSIDE the write until the test releases it, then writes the
/// bytes it was handed into the real destination (off the main actor). This is the
/// deterministic handshake of ACC-NON-BLOCKING-BACKGROUND-SAVE-03, and the park is
/// cancellation-aware, so `cancel()` really interrupts an in-flight save.
private final class BackgroundSaveTestSlowWriter: NoteFileAccess, @unchecked Sendable {
    private let log: BackgroundSaveTestEventLog
    private let gate = BackgroundSaveTestGate()
    private let lock = NSLock()
    private var payloads: [String] = []
    private var destinations: [URL] = []

    init(log: BackgroundSaveTestEventLog) {
        self.log = log
    }

    func readUTF8(from url: URL) async throws -> String {
        throw BackgroundSaveTestWriteFailure(reason: "this seam holds no note contents")
    }

    func writeAtomically(_ contents: String, to url: URL) async throws {
        log.record(.writerEntered)
        try await gate.park()
        try await Task.detached {
            try Data(contents.utf8).write(to: url)
        }.value
        recordWrite(contents, to: url)
        log.record(.writerWrote)
    }

    /// Synchronous, so no lock is taken from an asynchronous context.
    private func recordWrite(_ contents: String, to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        payloads.append(contents)
        destinations.append(url)
    }

    var writtenPayloads: [String] {
        lock.lock()
        defer { lock.unlock() }
        return payloads
    }

    var writeDestinations: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return destinations
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return destinations.count
    }

    var parkedWaitCount: Int { gate.parkedCount }

    /// Waits until the writer is parked inside a write: the save is in flight.
    func waitForWriterEntry() async {
        await gate.waitForRequestCount(atLeast: 1)
    }

    /// Lets the parked write finish.
    func releaseTheWriter() {
        gate.release()
    }
}

/// The note-file seam with a fixed failure and no filesystem, for the failure branches
/// that must not touch the destination at all.
private final class BackgroundSaveTestFailingWriter: NoteFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private let failure: Error
    private var destinations: [URL] = []

    init(failure: Error) {
        self.failure = failure
    }

    func readUTF8(from url: URL) async throws -> String {
        throw failure
    }

    func writeAtomically(_ contents: String, to url: URL) async throws {
        recordDestination(url)
        throw failure
    }

    /// Synchronous, so no lock is taken from an asynchronous context.
    private func recordDestination(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        destinations.append(url)
    }

    var writeDestinations: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return destinations
    }

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return destinations.count
    }
}

/// The real store's injectable rename step: it fails while `fails` is `true`, and can be
/// flipped back so an explicit retry is observed to succeed.
private final class BackgroundSaveTestRenameGate: @unchecked Sendable {
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

/// The cleanup verification with a planted report, so the "a temporary file was left
/// behind" branch is driven from a real observation point.
private final class BackgroundSaveTestVerifier: TemporarySaveFileVerifying, @unchecked Sendable {
    private let real = DirectoryTemporarySaveFileVerifier()
    private let lock = NSLock()
    private var reported: [String]

    init(reporting reported: [String] = []) {
        self.reported = reported
    }

    func temporarySiblingNames(beside destination: URL) async -> [String] {
        let planted = plantedNames()
        if planted.isEmpty == false {
            return planted
        }
        return await real.temporarySiblingNames(beside: destination)
    }

    /// Synchronous, so no lock is taken from an asynchronous context.
    private func plantedNames() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return reported
    }

    func report(_ names: [String]) {
        lock.lock()
        defer { lock.unlock() }
        reported = names
    }
}

/// Records every published outcome, so a test can await one deterministically instead of
/// hoping it happened.
private actor BackgroundSaveTestOutcomeRecorder {
    typealias Outcome = NonBlockingBackgroundSaveFeature.BackgroundSaveOutcome

    private var outcomes: [Outcome] = []
    private var waiters: [(required: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ outcome: Outcome) {
        outcomes.append(outcome)
        let ready = waiters.filter { $0.required <= outcomes.count }
        waiters.removeAll { $0.required <= outcomes.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func waitFor(atLeast count: Int) async -> [Outcome] {
        while outcomes.count < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append((count, continuation))
            }
        }
        return outcomes
    }

    var count: Int { outcomes.count }
}

/// The terminal paths every attempt can end on. Module-internal (not file-private)
/// because a test's parameter type must be at least as visible as the test itself; the
/// `BackgroundSaveTest` prefix keeps it unique in this module.
enum BackgroundSaveTestTerminalPath: String, CaseIterable, Sendable {
    case succeeded
    case temporaryWriteFailed
    case renameFailed
    case interruptedBeforeWrite
    case noDestination
    case temporaryFileLeftBehind

    var terminalState: OperationState {
        switch self {
        case .succeeded: return .succeeded
        case .temporaryWriteFailed, .renameFailed, .temporaryFileLeftBehind: return .failed
        case .interruptedBeforeWrite, .noDestination: return .cancelled
        }
    }

    /// Whether this path must report through the non-modal status area.
    var reportsFailure: Bool { terminalState == .failed }

    /// Whether the shared writer's temporary sibling is gone after this path.
    var removesTheTemporaryFile: Bool { self != .temporaryFileLeftBehind }

    /// Whether the destination holds the buffer after this path. The leftover path did
    /// commit its bytes — what failed there is the cleanup boundary.
    var commitsTheBuffer: Bool { self == .succeeded || self == .temporaryFileLeftBehind }

    /// Whether this path must leave the destination's directory holding exactly the
    /// destination.
    var leavesNoTemporarySiblingBehind: Bool { self != .temporaryFileLeftBehind }

    /// A path that never reached the shared writer attempted no write.
    var expectedWriteAttempts: Int {
        switch self {
        case .noDestination, .interruptedBeforeWrite: return 0
        default: return 1
        }
    }
}

// MARK: - Helpers

/// A real scratch directory under the system temporary location. Tests only: the feature
/// under test never chooses a destination by itself.
private func backgroundSaveTestScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("monospace-notes-background-save-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A dedicated, unique `UserDefaults` suite so no test can see another one's state.
private func backgroundSaveTestDefaultsSuite() throws -> (name: String, defaults: UserDefaults) {
    let name = "com.monospace.notes.tests.backgroundsave.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name), "A dedicated defaults suite is required")
    return (name, defaults)
}

private func backgroundSaveTestDiscardSuite(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
        .path
    if FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

private func backgroundSaveTestDirectoryEntries(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

private func backgroundSaveTestFeatureSource() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot
        .appendingPathComponent("Sources/MonospaceNotes/Features/NonBlockingBackgroundSaveFeature.swift")
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

/// The source with its `//` comments removed, so a structural scan is a scan of the
/// code and not of the prose that documents it: a comment that names a token must not
/// make the check report a behaviour the code does not have, and must not be needed to
/// hide one it does. Code and line structure are preserved.
private func backgroundSaveTestCodeWithoutComments(_ source: String) -> String {
    source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> String in
            guard let comment = line.range(of: "//") else { return String(line) }
            return String(line[line.startIndex..<comment.lowerBound])
        }
        .joined(separator: "\n")
}

private func backgroundSaveTestAppStateSource() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot.appendingPathComponent("Sources/MonospaceNotes/AppState.swift")
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

// MARK: - Suite

@Suite("FEAT-NON-BLOCKING-BACKGROUND-SAVE non-blocking background save")
@MainActor
struct NonBlockingBackgroundSaveFeatureTests {

    /// What one terminal path produced, with the real directory it ran in.
    private struct PathObservation {
        let outcome: NonBlockingBackgroundSaveFeature.BackgroundSaveOutcome
        let feature: NonBlockingBackgroundSaveFeature
        let recorder: FileIOThreadRecorder
        let directory: URL
        let suiteName: String
        let destination: URL
        let priorBytes: Data
        let buffer: String
    }

    // MARK: - The autosave interval (injected clock, no 30 second wait)

    @Test("The autosave interval is exactly 30000 ms from the last edit, and every edit resets it")
    func autosaveIntervalIsExactlyThirtyThousandMilliseconds() async throws {
        let clock = BackgroundSaveTestClock(startingAtMilliseconds: 500)
        let feature = NonBlockingBackgroundSaveFeature(
            noteFiles: BackgroundSaveTestFailingWriter(
                failure: BackgroundSaveTestWriteFailure(reason: "never used by this test")
            ),
            clock: clock
        )

        // The locked constants.
        #expect(NonBlockingBackgroundSaveFeature.autosaveIntervalMilliseconds == 30_000)
        #expect(NonBlockingBackgroundSaveFeature.autosaveInterval == .milliseconds(30_000))
        #expect(NonBlockingBackgroundSaveFeature.autosaveInterval == .seconds(30))
        #expect(feature.pendingAutosaveCount == 0, "nothing is scheduled before the first edit")
        #expect(feature.backgroundSaveState == .idle)

        let destination = URL(fileURLWithPath: "/definitely-not-a-real-directory/note.txt")

        // Starting the autosave run arms the timer for the interval, from the clock. The
        // wait for its registration is the handshake; nothing here waits on time.
        feature.startAutosave(buffer: "first revision\n", documentURL: destination)
        await clock.waitForSleepRequests(atLeast: 1)
        #expect(feature.lastEditMilliseconds == 500)
        #expect(feature.scheduledDeadlineMilliseconds == 500 + 30_000)
        #expect(feature.pendingAutosaveCount == 1)
        #expect(feature.runningOperationCount == 1)
        #expect(clock.requestedIntervals == [30_000], "the timer asked for exactly 30000 ms")

        // An edit at a chosen instant resets the deadline to EXACTLY 30000 ms later.
        feature.noteEdit(at: 1_000, buffer: "second revision\n", documentURL: destination)
        await clock.waitForSleepRequests(atLeast: 2)
        #expect(feature.scheduledDeadlineMilliseconds == 31_000)
        #expect(
            (feature.scheduledDeadlineMilliseconds ?? 0) - (feature.lastEditMilliseconds ?? 0)
                == NonBlockingBackgroundSaveFeature.autosaveIntervalMilliseconds,
            "the deadline is exactly the locked interval after the edit"
        )
        #expect(feature.autosaveBuffer == "second revision\n", "the edit's buffer is what the autosave will write")
        #expect(feature.autosaveDestination == destination)
        #expect(clock.requestedIntervals == [30_000, 30_000], "the reset wait is 30000 ms again")

        // A third edit moves it again, and every wait asked for exactly 30000 ms.
        feature.noteEdit(at: 7_777)
        await clock.waitForSleepRequests(atLeast: 3)
        #expect(feature.scheduledDeadlineMilliseconds == 37_777)
        #expect(clock.requestedIntervals == [30_000, 30_000, 30_000])

        // However many edits happened, exactly one wait is pending: an edit replaces the
        // previous wait instead of adding one.
        #expect(feature.pendingAutosaveCount == 1)
        #expect(feature.runningOperationCount == 1)

        // Cleanup: cancel leaves nothing running, and the last valid state is preserved.
        let cancelled = await feature.cancel()
        #expect(cancelled == 1, "the armed timer wait was interrupted")
        #expect(feature.pendingAutosaveCount == 0)
        #expect(feature.runningOperationCount == 0)
        #expect(feature.scheduledDeadlineMilliseconds == nil)
        #expect(feature.autosaveBuffer == "second revision\n", "the last valid user state is preserved")
        #expect(clock.parkedWaitCount == 0, "no clock wait is left parked")
    }

    @Test("The armed timer fires once after the interval and writes the buffer of the last edit")
    func timerFiresOnceAndWritesTheEditedBuffer() async throws {
        let scratch = try backgroundSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try backgroundSaveTestDefaultsSuite()
        defer { backgroundSaveTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let verifier = DirectoryTemporarySaveFileVerifier(recorder: recorder)
        let clock = BackgroundSaveTestClock()
        let feature = NonBlockingBackgroundSaveFeature(
            noteFiles: store,
            clock: clock,
            temporaryFileVerifier: verifier
        )
        let published = BackgroundSaveTestOutcomeRecorder()
        feature.onOutcome = { outcome in Task { await published.record(outcome) } }

        let destination = scratch.appendingPathComponent("note.txt")
        try Data("revision one\n".utf8).write(to: destination)

        feature.startAutosave(buffer: "revision one\n", documentURL: destination)
        await clock.waitForSleepRequests(atLeast: 1)
        #expect(feature.pendingAutosaveCount == 1)
        #expect(clock.requestedIntervals == [30_000])

        // The user keeps typing: the edit records the new buffer and resets the deadline.
        let edited = "revision two — 日本語のメモ\nsecond line\n"
        feature.noteEdit(at: 0, buffer: edited, documentURL: destination)
        #expect(feature.scheduledDeadlineMilliseconds == 30_000)
        await clock.waitForSleepRequests(atLeast: 2)

        // The interval elapses: the timer fires and the attempt runs.
        clock.elapse()
        let outcomes = await published.waitFor(atLeast: 1)
        #expect(outcomes.count == 1, "the armed timer fires exactly once")
        let outcome = try #require(outcomes.first)

        #expect(outcome.state == .succeeded)
        #expect(outcome.statusMessage == nil, "a successful attempt reports nothing in the status area")
        #expect(outcome.temporaryFileRemoved)
        #expect(outcome.url == destination)
        #expect(outcome.clearedUnsavedMarker, "the buffer is on disk, so the marker is cleared")

        // The destination holds the buffer of the last edit, and nothing else is left in
        // the destination's directory.
        let bytes = try Data(contentsOf: destination)
        #expect(bytes == Data(edited.utf8))
        let entries = try backgroundSaveTestDirectoryEntries(scratch)
        #expect(entries == ["note.txt"], "no temporary file remains beside the destination")
        let leftovers = await verifier.temporarySiblingNames(beside: destination)
        #expect(leftovers.isEmpty)

        // The run ended: nothing is pending, nothing is running, and no second attempt
        // happens on its own (the retry is explicit).
        #expect(feature.pendingAutosaveCount == 0)
        #expect(feature.runningOperationCount == 0)
        #expect(feature.scheduledDeadlineMilliseconds == nil)
        #expect(feature.writeAttemptCount == 1)
        #expect(await published.count == 1, "nothing is retried automatically")
        #expect(recorder.mainThreadViolations == 0, "no file I/O ran on the main thread")
    }

    // MARK: - ACC-02: a successful background save

    @Test("ACC-02: a successful background save writes exactly the buffer and leaves no temporary file")
    func successfulSaveWritesTheExactBufferAndLeavesNoTemporaryFile() async throws {
        let scratch = try backgroundSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try backgroundSaveTestDefaultsSuite()
        defer { backgroundSaveTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let verifier = DirectoryTemporarySaveFileVerifier(recorder: recorder)
        let feature = NonBlockingBackgroundSaveFeature(
            noteFiles: store,
            clock: BackgroundSaveTestClock(),
            temporaryFileVerifier: verifier
        )

        let destination = scratch.appendingPathComponent("note.txt")
        try Data("previous revision\n".utf8).write(to: destination)
        #expect(try backgroundSaveTestDirectoryEntries(scratch) == ["note.txt"])

        let buffer = "Úvod — 日本語のメモ — emoji 🅰\r\nsecond line\r\n"
        let outcome = await feature.saveNow(text: buffer, documentURL: destination)

        #expect(outcome.state == .succeeded)
        #expect(outcome.clearedUnsavedMarker)
        #expect(outcome.statusMessage == nil, "a successful attempt never reports a failure status")
        #expect(outcome.failureReason == nil)
        #expect(outcome.cancellationReason == nil)
        #expect(outcome.temporaryFileRemoved, "the cleanup verification found no temporary sibling")
        #expect(outcome.url == destination)

        // Exactly the buffer's UTF-8 bytes, read back through the shared seam as well.
        let bytes = try Data(contentsOf: destination)
        #expect(bytes == Data(buffer.utf8))
        #expect(bytes.count == buffer.utf8.count)
        let readBack = try await store.readUTF8(from: destination)
        #expect(readBack == buffer)

        // The real directory listing: the destination and nothing else.
        let entries = try backgroundSaveTestDirectoryEntries(scratch)
        #expect(entries == ["note.txt"], "ACC-02: no temporary file remains in the directory")
        let leftovers = await verifier.temporarySiblingNames(beside: destination)
        #expect(leftovers.isEmpty)

        // The verification is not vacuous: it recognises, and reports, the temporary
        // sibling the shared writer really creates — in the destination's OWN directory.
        let sibling = DataStore.temporarySiblingURL(for: destination)
        #expect(sibling.deletingLastPathComponent().path == scratch.path,
                "the shared writer's temporary file lives in the destination's own directory")
        #expect(DirectoryTemporarySaveFileVerifier.temporarySiblingPrefix(for: destination)
                    == "." + destination.lastPathComponent + ".mn-save-")
        try Data("a write that was in flight\n".utf8).write(to: sibling)
        let detected = await verifier.temporarySiblingNames(beside: destination)
        #expect(detected == [sibling.lastPathComponent],
                "the verification really reports a temporary sibling that is present")
        try FileManager.default.removeItem(at: sibling)
        let afterCleanup = await verifier.temporarySiblingNames(beside: destination)
        #expect(afterCleanup.isEmpty)

        #expect(feature.backgroundSaveState == .succeeded)
        #expect(feature.lastOutcome == outcome)
        #expect(feature.pendingAutosaveCount == 0)
        #expect(feature.runningOperationCount == 0, "a completed attempt leaves nothing running")
        #expect(feature.writeAttemptCount == 1)
        #expect(recorder.mainThreadViolations == 0, "no file I/O ran on the main thread")
        #expect(recorder.totalOperations >= 2, "the write and the cleanup verification are recorded")
    }

    // MARK: - ACC-01: a failed background save is non-modal

    @Test("ACC-01: a failed background save reports the path in the non-modal status, and builds no modal alert")
    func failedBackgroundSaveReportsNonModalStatusNamingThePath() async throws {
        let scratch = try backgroundSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let recorder = FileIOThreadRecorder()
        let failure = DataStore.OperationError.writeFailed(
            fileName: "note.txt",
            reason: "the volume is read-only"
        )
        let writer = BackgroundSaveTestFailingWriter(failure: failure)
        let verifier = DirectoryTemporarySaveFileVerifier(recorder: recorder)
        let feature = NonBlockingBackgroundSaveFeature(
            noteFiles: writer,
            clock: BackgroundSaveTestClock(),
            temporaryFileVerifier: verifier
        )

        let destination = scratch.appendingPathComponent("note.txt")
        let priorBytes = Data("the last valid revision\n".utf8)
        try priorBytes.write(to: destination)

        let buffer = "the edit that could not be written\n"
        let outcome = await feature.saveNow(text: buffer, documentURL: destination)

        #expect(outcome.state == .failed)
        let status = try #require(outcome.statusMessage, "ACC-01: a failed background save produces a status message")
        #expect(status.isFailure, "the status area shows it as a failure")
        #expect(status.text.contains(destination.path), "ACC-01: the status names the destination path")
        #expect(status.text == "Background save failed for " + destination.path + ": the volume is read-only",
                "the status uses the locked text exactly")
        #expect(status.text.hasPrefix(NonBlockingBackgroundSaveFeature.failureStatusPrefix))
        #expect(!status.text.contains(buffer), "the status never carries note contents")

        #expect(!outcome.clearedUnsavedMarker, "nothing was committed, so the document is still unsaved")
        #expect(outcome.failureReason == .writeFailed)
        #expect(outcome.url == destination)
        #expect(outcome.temporaryFileRemoved)
        #expect(feature.backgroundSaveState == .failed)
        #expect(writer.writeDestinations == [destination], "the attempt addressed the destination")

        // The failure never touched the destination or its directory.
        let bytes = try Data(contentsOf: destination)
        #expect(bytes == priorBytes)
        let entries = try backgroundSaveTestDirectoryEntries(scratch)
        #expect(entries == ["note.txt"])

        // The feature builds NO modal alert: it has no alert value of any kind, and the
        // modal title of the Cmd+S route appears nowhere in it. That is a structural
        // proof over the published source, which is what "never with a modal alert" can
        // be checked against without a UI.
        let source = try backgroundSaveTestFeatureSource()
        #expect(source.contains("StatusMessage"), "the non-modal status area is how this feature reports")
        #expect(!source.contains("ErrorAlert"), "the background save builds no modal alert at all")
        #expect(!source.contains("errorAlert"), "the background save never reaches the modal alert surface")
        #expect(!source.contains("Could Not Save Note"), "the modal Cmd+S title belongs to the Cmd+S route")
    }

    // MARK: - ACC-04: a failed rename leaves the destination's bytes unchanged

    @Test("ACC-04: a failed rename leaves the destination's bytes exactly as they were")
    func renameFailureLeavesTheDestinationBytesUnchanged() async throws {
        let scratch = try backgroundSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try backgroundSaveTestDefaultsSuite()
        defer { backgroundSaveTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let gate = BackgroundSaveTestRenameGate(failing: true)
        let store = DataStore(
            defaults: defaults,
            recorder: recorder,
            rename: { from, to in try gate.rename(from, to) }
        )
        let verifier = DirectoryTemporarySaveFileVerifier(recorder: recorder)
        let feature = NonBlockingBackgroundSaveFeature(
            noteFiles: store,
            clock: BackgroundSaveTestClock(),
            temporaryFileVerifier: verifier
        )

        let destination = scratch.appendingPathComponent("note.txt")
        let priorBytes = Data("revision one — 日本語\n".utf8)
        try priorBytes.write(to: destination)

        let edited = "revision two — and an edit — 日本語\n"
        let outcome = await feature.saveNow(text: edited, documentURL: destination)

        #expect(outcome.state == .failed)
        #expect(!outcome.clearedUnsavedMarker)
        #expect(outcome.failureReason == .writeFailed)

        let status = try #require(outcome.statusMessage)
        #expect(status.isFailure)
        #expect(status.text.contains(destination.path))
        #expect(status.text.contains("injected rename failure"), "the status names the write error")

        // ACC-04: the destination's bytes are unchanged from before the attempt.
        let bytes = try Data(contentsOf: destination)
        #expect(bytes == priorBytes, "ACC-04: a failed rename leaves the destination's bytes unchanged")

        // The shared writer cleaned up after itself: no temporary sibling remains.
        let entries = try backgroundSaveTestDirectoryEntries(scratch)
        #expect(entries == ["note.txt"], "the temporary save file was removed on the rename-failure path")
        let leftovers = await verifier.temporarySiblingNames(beside: destination)
        #expect(leftovers.isEmpty)
        #expect(feature.backgroundSaveState == .failed)
        #expect(feature.runningOperationCount == 0)
        #expect(recorder.mainThreadViolations == 0)

        // An explicit retry commits, once the rename works again.
        gate.fails = false
        let retry = await feature.saveNow(text: edited, documentURL: destination)
        #expect(retry.state == .succeeded)
        #expect(retry.clearedUnsavedMarker)
        #expect(retry.statusMessage == nil)
        let retriedBytes = try Data(contentsOf: destination)
        #expect(retriedBytes == Data(edited.utf8))
        #expect(try backgroundSaveTestDirectoryEntries(scratch) == ["note.txt"])
        #expect(feature.writeAttemptCount == 2, "the failed attempt counted, and the retry counted")
        #expect(feature.runningOperationCount == 0)
    }

    // MARK: - ACC-03: the save never blocks the document surface

    @Test("ACC-03: a keystroke during a background save reaches the text view before the save completes")
    func keystrokeDuringABackgroundSaveReachesTheTextViewBeforeTheSaveCompletes() async throws {
        let scratch = try backgroundSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let log = BackgroundSaveTestEventLog()
        let writer = BackgroundSaveTestSlowWriter(log: log)
        let verifier = DirectoryTemporarySaveFileVerifier()
        let feature = NonBlockingBackgroundSaveFeature(
            noteFiles: writer,
            clock: BackgroundSaveTestClock(),
            temporaryFileVerifier: verifier
        )

        let destination = scratch.appendingPathComponent("note.txt")
        let bufferAtSaveStart = "line one\n"

        // A real TextKit 2 document surface and the app's real keystroke path.
        let textView = TextKit2DocumentView.makeDocumentTextView(
            text: bufferAtSaveStart,
            font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            textColor: .white,
            backgroundColor: .black,
            isEditable: true
        )
        let keystrokes = KeystrokeRenderingUnder16msFeature()
        keystrokes.attach(textView)
        let surfaceReady = keystrokes.prepareSurface(textView)
        #expect(surfaceReady, "the real document surface is ready to render a keystroke")
        #expect(textView.textLayoutManager != nil, "the surface is genuinely TextKit 2")
        #expect(textView.string == bufferAtSaveStart)

        // The background save starts and parks inside the writer: it is in flight, and it
        // has not completed.
        let saveTask = Task { () -> NonBlockingBackgroundSaveFeature.BackgroundSaveOutcome in
            log.record(.saveStarted)
            return await feature.saveNow(text: bufferAtSaveStart, documentURL: destination)
        }
        await writer.waitForWriterEntry()
        #expect(feature.isSaving, "the attempt is in flight")
        #expect(log.recorded == [.saveStarted, .writerEntered])

        // The keystroke, entered while the save is in flight — "within 16 ms of the save
        // start" made deterministic: the save is parked inside the writer, so the
        // keystroke necessarily lands inside the save's window, with no wall-clock race.
        // It runs on the main actor: if the save blocked it, this insertion could not
        // happen here at all, and the completion event would precede it.
        let character = "字"
        let measurement = keystrokes.insert(character, into: textView)
        log.record(.keystrokeApplied)

        let failure = keystrokes.lastFailureReason.map(\.rawValue) ?? "none"
        #expect(measurement.inserted, "the character reached the text buffer (reason: \(failure))")
        #expect(measurement.drew, "TextKit 2 laid out and drew the updated text (reason: \(failure))")
        #expect(measurement.cancelled == false)
        #expect(textView.string.contains(character), "ACC-03: the keystroke is reflected in the text view")
        #expect((textView.string as NSString).length == (bufferAtSaveStart as NSString).length + 1,
                "the keystroke really reached the document buffer")
        #expect(feature.isSaving, "the save was still in flight when the keystroke landed")
        #expect(log.recorded.contains(.writerWrote) == false)
        #expect(log.recorded.contains(.saveCompleted) == false)

        // The 16 ms figure is the keystroke budget owned by FEAT-KEYSTROKE-RENDERING-UNDER-16MS.
        // The measured number is reported, never asserted from a single wall-clock sample:
        // the whole suite runs in parallel on this machine, so one sample is not a proof of
        // a budget, and the budget itself is verified by the keystroke suite that owns it.
        print("[ACC-03] keystroke measured while the background save was in flight:"
            + " \(measurement.milliseconds) ms"
            + " (budget \(KeystrokeRenderingUnder16msFeature.budgetMilliseconds) ms,"
            + " document surface \(KeystrokeRenderingUnder16msFeature.documentSizeForBudgetBytes) bytes,"
            + " drew: \(measurement.drew))")

        // Now the save is allowed to finish.
        writer.releaseTheWriter()
        let outcome = await saveTask.value
        log.record(.saveCompleted)

        #expect(outcome.state == .succeeded)
        #expect(outcome.temporaryFileRemoved)
        #expect(outcome.url == destination)

        // The ordering is recorded, never timed: the save was inside the writer, then the
        // keystroke reached the text view, and only then did the save complete.
        let entryIndex = try #require(log.firstIndex(of: .writerEntered))
        let keystrokeIndex = try #require(log.firstIndex(of: .keystrokeApplied))
        let wroteIndex = try #require(log.firstIndex(of: .writerWrote))
        let completedIndex = try #require(log.firstIndex(of: .saveCompleted))
        #expect(entryIndex < keystrokeIndex, "the save was already in flight")
        #expect(keystrokeIndex < wroteIndex, "the keystroke reached the text view before the save completed")
        #expect(wroteIndex < completedIndex)

        // The save wrote the buffer it started with, and never lost the keystroke or
        // clobbered the text view.
        let savedBytes = try Data(contentsOf: destination)
        #expect(savedBytes == Data(bufferAtSaveStart.utf8), "the attempt wrote the buffer of the save start")
        let savedText = String(decoding: savedBytes, as: UTF8.self)
        #expect(savedText.contains(character) == false,
                "the keystroke of a later edit is not silently folded into this attempt")
        #expect(textView.string.contains(character), "the keystroke is still in the text view after the save")
        #expect(writer.writeCount == 1)
        #expect(writer.writtenPayloads == [bufferAtSaveStart])
        #expect(try backgroundSaveTestDirectoryEntries(scratch) == ["note.txt"])
        #expect(feature.runningOperationCount == 0)
        #expect(feature.pendingAutosaveCount == 0)
    }

    // MARK: - cancel()

    @Test("cancel() cancels the armed timer, and nothing is written afterwards")
    func cancelCancelsTheArmedTimerWithNothingLeftRunning() async throws {
        let scratch = try backgroundSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try backgroundSaveTestDefaultsSuite()
        defer { backgroundSaveTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let clock = BackgroundSaveTestClock()
        let verifier = DirectoryTemporarySaveFileVerifier()
        let feature = NonBlockingBackgroundSaveFeature(
            noteFiles: store,
            clock: clock,
            temporaryFileVerifier: verifier
        )
        let published = BackgroundSaveTestOutcomeRecorder()
        feature.onOutcome = { outcome in Task { await published.record(outcome) } }

        let destination = scratch.appendingPathComponent("note.txt")
        let neverWritten = "an edit that must not reach the disk after a cancel\n"
        feature.noteEdit(at: 0, buffer: neverWritten, documentURL: destination)
        await clock.waitForSleepRequests(atLeast: 1)
        #expect(feature.pendingAutosaveCount == 1)
        #expect(feature.runningOperationCount == 1)

        let cancelled = await feature.cancel()

        #expect(cancelled == 1, "the armed timer wait was interrupted")
        #expect(feature.pendingAutosaveCount == 0)
        #expect(feature.runningOperationCount == 0, "nothing is left running")
        #expect(feature.isSaving == false)
        #expect(feature.scheduledDeadlineMilliseconds == nil)
        #expect(clock.parkedWaitCount == 0, "no clock wait is left parked")

        // Whatever the interval would have done, no attempt happens after the cancel.
        clock.elapse()
        #expect(await published.count == 0, "a cancelled run performs no attempt")
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(try backgroundSaveTestDirectoryEntries(scratch).isEmpty)

        // The last valid user state is preserved, and a later edit starts a new run.
        #expect(feature.autosaveBuffer == neverWritten)
        #expect(feature.autosaveDestination == destination)

        let laterEdit = "a later edit\n"
        feature.noteEdit(at: 0, buffer: laterEdit, documentURL: destination)
        #expect(feature.pendingAutosaveCount == 1)
        await clock.waitForSleepRequests(atLeast: 2)
        clock.elapse()
        let outcomes = await published.waitFor(atLeast: 1)
        #expect(outcomes.first?.state == .succeeded, "an edit after a cancel starts a new autosave run")
        let bytes = try Data(contentsOf: destination)
        #expect(bytes == Data(laterEdit.utf8))
        #expect(feature.runningOperationCount == 0)
    }

    @Test("cancel() also cancels an in-flight save, leaving nothing running and the destination untouched")
    func cancelCancelsAnInFlightSaveWithNothingLeftRunning() async throws {
        let scratch = try backgroundSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let log = BackgroundSaveTestEventLog()
        let writer = BackgroundSaveTestSlowWriter(log: log)
        let verifier = DirectoryTemporarySaveFileVerifier()
        let clock = BackgroundSaveTestClock()
        let feature = NonBlockingBackgroundSaveFeature(
            noteFiles: writer,
            clock: clock,
            temporaryFileVerifier: verifier
        )

        let destination = scratch.appendingPathComponent("note.txt")
        let priorBytes = Data("the last valid revision\n".utf8)
        try priorBytes.write(to: destination)

        let inFlight = "the edit that is in flight\n"
        let saveTask = Task { () -> NonBlockingBackgroundSaveFeature.BackgroundSaveOutcome in
            log.record(.saveStarted)
            return await feature.saveNow(text: inFlight, documentURL: destination)
        }
        await writer.waitForWriterEntry()
        #expect(feature.isSaving)

        // The user types during the save: the timer is armed again, so both the timer and
        // the attempt are running.
        feature.noteEdit(at: 0, buffer: "the edit typed during the save\n", documentURL: destination)
        #expect(feature.pendingAutosaveCount == 1)
        #expect(feature.runningOperationCount == 2)

        let cancelled = await feature.cancel()

        #expect(cancelled == 2, "both the in-flight save and the armed timer were interrupted")
        #expect(feature.runningOperationCount == 0, "nothing is left running")
        #expect(feature.isSaving == false)
        #expect(feature.pendingAutosaveCount == 0)
        #expect(writer.parkedWaitCount == 0, "the attempt is no longer parked inside the writer")

        let outcome = await saveTask.value
        #expect(outcome.state == .cancelled, "an interrupted attempt is cancelled, never failed")
        #expect(outcome.statusMessage == nil, "an interruption is not an error, so the status area stays clean")
        #expect(outcome.cancellationReason == .interruptedDuringWrite)
        #expect(!outcome.clearedUnsavedMarker)
        #expect(feature.backgroundSaveState == .cancelled)

        // Nothing was written: the interrupted attempt never reached the disk.
        #expect(writer.writeCount == 0)
        let bytes = try Data(contentsOf: destination)
        #expect(bytes == priorBytes)
        let entries = try backgroundSaveTestDirectoryEntries(scratch)
        #expect(entries == ["note.txt"])
        let leftovers = await verifier.temporarySiblingNames(beside: destination)
        #expect(leftovers.isEmpty)
    }

    // MARK: - Cleanup on every terminal path

    @Test(
        "Every terminal path leaves nothing running and reports in exactly one way",
        arguments: BackgroundSaveTestTerminalPath.allCases
    )
    func terminalPathsLeaveNothingRunning(_ path: BackgroundSaveTestTerminalPath) async throws {
        let observation = try await runTerminalPath(path)
        defer {
            try? FileManager.default.removeItem(at: observation.directory)
            backgroundSaveTestDiscardSuite(observation.suiteName)
        }

        let outcome = observation.outcome
        let feature = observation.feature

        #expect(outcome.state == path.terminalState, "the attempt ends on its terminal state")
        #expect(outcome.state != .idle && outcome.state != .active, "an attempt that returned is never still running")
        #expect(feature.backgroundSaveState == path.terminalState)
        #expect(feature.isSaving == false, "nothing is in flight after the attempt returned")
        #expect(feature.pendingAutosaveCount == 0, "no timer is left armed by an attempt")
        #expect(feature.runningOperationCount == 0, "no task is left running on this terminal path")
        #expect(feature.writeAttemptCount == path.expectedWriteAttempts)

        // Reporting rule: exactly a failure reports, and only in the non-modal status area.
        #expect((outcome.statusMessage != nil) == path.reportsFailure,
                "a failure reports in the status area; a success and an interruption report nothing")
        if let status = outcome.statusMessage {
            #expect(status.isFailure)
            #expect(status.text.hasPrefix(NonBlockingBackgroundSaveFeature.failureStatusPrefix))
            #expect(status.text.contains(observation.destination.path), "the status names the path")
        }
        #expect(outcome.clearedUnsavedMarker == (outcome.state == .succeeded))

        // The cleanup boundary.
        #expect(outcome.temporaryFileRemoved == path.removesTheTemporaryFile)
        let bytes = try Data(contentsOf: observation.destination)
        if path.commitsTheBuffer {
            #expect(bytes == Data(observation.buffer.utf8))
        } else {
            #expect(bytes == observation.priorBytes, "the destination keeps its prior bytes on this path")
        }
        let entries = try backgroundSaveTestDirectoryEntries(observation.directory)
        if path.leavesNoTemporarySiblingBehind {
            #expect(entries == ["note.txt"], "no temporary file remains in the destination's directory")
        } else {
            #expect(entries.count == 2, "the planted temporary file is still there, and is reported")
        }
        #expect(observation.recorder.mainThreadViolations == 0, "no file I/O ran on the main thread")
    }

    // MARK: - A document with no path

    @Test("A document with no path is skipped without inventing a destination")
    func documentWithoutAPathIsSkipped() async throws {
        let scratch = try backgroundSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try backgroundSaveTestDefaultsSuite()
        defer { backgroundSaveTestDiscardSuite(suiteName) }

        let store = DataStore(defaults: defaults, recorder: FileIOThreadRecorder())
        let clock = BackgroundSaveTestClock()
        let feature = NonBlockingBackgroundSaveFeature(
            noteFiles: store,
            clock: clock,
            temporaryFileVerifier: DirectoryTemporarySaveFileVerifier()
        )
        let published = BackgroundSaveTestOutcomeRecorder()
        feature.onOutcome = { outcome in Task { await published.record(outcome) } }

        // A neighbouring note the attempt must never touch.
        let neighbour = scratch.appendingPathComponent("another-note.txt")
        let neighbourBytes = Data("another note — 日本語\n".utf8)
        try neighbourBytes.write(to: neighbour)

        let direct = await feature.saveNow(text: "an unsaved first draft\n", documentURL: nil)
        #expect(direct.state == .cancelled)
        #expect(direct.cancellationReason == .noDestination)
        #expect(direct.url == nil)
        #expect(direct.statusMessage == nil, "having no path is not a write failure")
        #expect(direct.temporaryFileRemoved)
        #expect(feature.writeAttemptCount == 0, "the writer was never reached")
        #expect(feature.skippedWithoutDestinationCount == 1)

        // The same through the autosave timer.
        feature.noteEdit(at: 0, buffer: "an unsaved first draft\n", documentURL: nil)
        await clock.waitForSleepRequests(atLeast: 1)
        clock.elapse()
        // The direct attempt above already published one outcome, so the second one is the
        // timer-driven attempt: waiting for it is the handshake, not a sleep.
        let outcomes = await published.waitFor(atLeast: 2)
        #expect(outcomes.count == 2)
        let fired = try #require(outcomes.last)
        #expect(fired.state == .cancelled)
        #expect(fired.cancellationReason == .noDestination)
        #expect(fired.url == nil)
        #expect(feature.skippedWithoutDestinationCount == 2)
        #expect(feature.runningOperationCount == 0)
        #expect(feature.pendingAutosaveCount == 0)

        // Nothing was written anywhere.
        let entries = try backgroundSaveTestDirectoryEntries(scratch)
        #expect(entries == ["another-note.txt"])
        let neighbourAfter = try Data(contentsOf: neighbour)
        #expect(neighbourAfter == neighbourBytes)
    }

    // MARK: - A temporary file left behind is reported honestly

    @Test("A temporary file left beside the destination is reported honestly, and an explicit retry commits")
    func leftoverTemporaryFileIsReportedHonestly() async throws {
        let scratch = try backgroundSaveTestScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (suiteName, defaults) = try backgroundSaveTestDefaultsSuite()
        defer { backgroundSaveTestDiscardSuite(suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let verifier = DirectoryTemporarySaveFileVerifier(recorder: recorder)
        let feature = NonBlockingBackgroundSaveFeature(
            noteFiles: store,
            clock: BackgroundSaveTestClock(),
            temporaryFileVerifier: verifier
        )

        let destination = scratch.appendingPathComponent("note.txt")
        try Data("revision one\n".utf8).write(to: destination)

        // A real temporary sibling of an earlier attempt is still present: the cleanup
        // boundary of CON-PERSISTENCE-TEMPORARY-SAVE-FILE was violated.
        let leftover = DataStore.temporarySiblingURL(for: destination)
        try Data("an earlier attempt that never finished\n".utf8).write(to: leftover)
        let entriesBefore = try backgroundSaveTestDirectoryEntries(scratch)
        #expect(entriesBefore.count == 2)

        let buffer = "revision two — the buffer that was written\n"
        let outcome = await feature.saveNow(text: buffer, documentURL: destination)

        #expect(outcome.state == .failed, "a cleanup failure is reported honestly")
        #expect(outcome.failureReason == .temporaryFileLeftBehind)
        #expect(outcome.temporaryFileRemoved == false)
        #expect(!outcome.clearedUnsavedMarker, "the document stays marked unsaved: the boundary was not clean")
        let status = try #require(outcome.statusMessage)
        #expect(status.isFailure)
        #expect(status.text.contains(destination.path))
        #expect(status.text.contains("left behind"))
        #expect(feature.backgroundSaveState == .failed)
        #expect(feature.runningOperationCount == 0)

        // The verification, not a guess: the leftover really is there.
        let leftovers = await verifier.temporarySiblingNames(beside: destination)
        #expect(leftovers == [leftover.lastPathComponent])

        // The explicit retry: with the leftover gone the same attempt commits, and the
        // destination's directory holds exactly the destination.
        try FileManager.default.removeItem(at: leftover)
        let retry = await feature.saveNow(text: buffer, documentURL: destination)
        #expect(retry.state == .succeeded)
        #expect(retry.temporaryFileRemoved)
        #expect(retry.clearedUnsavedMarker)
        let bytes = try Data(contentsOf: destination)
        #expect(bytes == Data(buffer.utf8))
        let entriesAfter = try backgroundSaveTestDirectoryEntries(scratch)
        #expect(entriesAfter == ["note.txt"])
        #expect(feature.writeAttemptCount == 2)
    }

    // MARK: - The shared writer, and no writer of its own

    @Test("The feature calls the shared same-directory atomic writer and re-implements no file I/O")
    func structuralProofOverTheFeatureSource() throws {
        let source = try backgroundSaveTestFeatureSource()
        // The scan runs over the code with its comments removed: prose that names a token
        // is not behaviour, and behaviour must not be hidden behind prose either.
        let code = backgroundSaveTestCodeWithoutComments(source)

        // Positive: the shared writer seam is the only way this feature reaches a note,
        // and the status area is how it reports.
        #expect(code.contains("noteFiles.writeAtomically("),
                "every save goes through NoteFileAccess.writeAtomically")
        #expect(code.contains("autosaveIntervalMilliseconds: Int = 30_000"),
                "the locked interval is declared in this file")
        #expect(code.contains("\"Background save failed for \""),
                "the locked status text is declared in this file")
        #expect(code.contains("StatusMessage"), "the non-modal status area is the reporting surface")

        // Negative: this feature writes no writer, no rename, no temporary directory of
        // its own, no settings, and no UI.
        let forbidden = [
            "NSTemporaryDirectory",
            "temporaryDirectory",
            "func writeAtomically",
            "posixRename",
            "moveItem",
            "replaceItemAt",
            "rename(",
            "Data(contentsOf",
            "write(to:",
            "UserDefaults",
            "NSOpenPanel",
            "NSSavePanel",
            "runModal",
            "Color.black",
        ]
        for token in forbidden {
            #expect(!code.contains(token),
                    "NonBlockingBackgroundSaveFeature.swift must not contain \(token)")
        }

        // The forbidden technologies of the packet, restated for this file alone.
        let forbiddenTechnology = [
            "URLSession",
            "NSURLConnection",
            "NSURLRequest",
            "CFNetwork",
            "import Network",
            "import UIKit",
            "import WebKit",
            "import XCTest",
        ]
        for token in forbiddenTechnology {
            #expect(!source.contains(token),
                    "NonBlockingBackgroundSaveFeature.swift must not contain \(token) anywhere")
        }
    }

    @Test("The composition root already declares the surfaces this feature publishes into")
    func compositionRootSurfacesExist() throws {
        let source = try backgroundSaveTestAppStateSource()

        // The state the orchestrator's AppState patch publishes an attempt into: the
        // operation state and the NON-MODAL status area.
        #expect(source.contains("private(set) var backgroundSaveState: OperationState"),
                "AppState declares the background-save operation state")
        #expect(source.contains("var statusMessage: StatusMessage?"),
                "AppState declares the non-modal status area")
        #expect(source.contains("var errorAlert: ErrorAlert?"),
                "AppState declares the modal alert surface, which this feature never writes")
        // The edit path the timer is reset from.
        #expect(source.contains("func handleKeystrokeInsert(_ character: String, in textView: NSTextView) -> Bool"),
                "the edit path the autosave timer is reset from exists")
    }

    // MARK: - Terminal-path runner

    /// Runs one terminal path against a real destination directory, and returns what
    /// happened. Every path uses a real file for the destination, so "the destination's
    /// bytes" is always a real observation, and the destination's directory is real too.
    private func runTerminalPath(
        _ path: BackgroundSaveTestTerminalPath
    ) async throws -> PathObservation {
        let directory = try backgroundSaveTestScratchDirectory()
        let (suiteName, defaults) = try backgroundSaveTestDefaultsSuite()
        let recorder = FileIOThreadRecorder()
        let verifier = DirectoryTemporarySaveFileVerifier(recorder: recorder)
        let clock = BackgroundSaveTestClock()

        let destination = directory.appendingPathComponent("note.txt")
        let priorBytes = Data("the last valid revision — 日本語\n".utf8)
        let buffer = "the buffer of the last edit — 日本語\n"
        try priorBytes.write(to: destination)

        let feature: NonBlockingBackgroundSaveFeature
        var attemptDestination: URL? = destination
        var preCancelled = false

        switch path {
        case .succeeded:
            feature = NonBlockingBackgroundSaveFeature(
                noteFiles: DataStore(defaults: defaults, recorder: recorder),
                clock: clock,
                temporaryFileVerifier: verifier
            )
        case .temporaryWriteFailed:
            let failure = DataStore.OperationError.writeFailed(
                fileName: "note.txt",
                reason: "the volume is read-only"
            )
            feature = NonBlockingBackgroundSaveFeature(
                noteFiles: BackgroundSaveTestFailingWriter(failure: failure),
                clock: clock,
                temporaryFileVerifier: verifier
            )
        case .renameFailed:
            let gate = BackgroundSaveTestRenameGate(failing: true)
            feature = NonBlockingBackgroundSaveFeature(
                noteFiles: DataStore(
                    defaults: defaults,
                    recorder: recorder,
                    rename: { from, to in try gate.rename(from, to) }
                ),
                clock: clock,
                temporaryFileVerifier: verifier
            )
        case .interruptedBeforeWrite:
            feature = NonBlockingBackgroundSaveFeature(
                noteFiles: DataStore(defaults: defaults, recorder: recorder),
                clock: clock,
                temporaryFileVerifier: verifier
            )
            preCancelled = true
        case .noDestination:
            feature = NonBlockingBackgroundSaveFeature(
                noteFiles: DataStore(defaults: defaults, recorder: recorder),
                clock: clock,
                temporaryFileVerifier: verifier
            )
            attemptDestination = nil
        case .temporaryFileLeftBehind:
            let leftover = DataStore.temporarySiblingURL(for: destination)
            try Data("an earlier attempt that never finished\n".utf8).write(to: leftover)
            feature = NonBlockingBackgroundSaveFeature(
                noteFiles: DataStore(defaults: defaults, recorder: recorder),
                clock: clock,
                temporaryFileVerifier: verifier
            )
        }

        let outcome: NonBlockingBackgroundSaveFeature.BackgroundSaveOutcome
        if preCancelled {
            // Deterministic interruption: the task is cancelled before it runs its body,
            // so the attempt observes the cancellation on entry and writes nothing.
            let task = Task {
                await feature.saveNow(text: buffer, documentURL: attemptDestination)
            }
            task.cancel()
            outcome = await task.value
        } else {
            outcome = await feature.saveNow(text: buffer, documentURL: attemptDestination)
        }

        return PathObservation(
            outcome: outcome,
            feature: feature,
            recorder: recorder,
            directory: directory,
            suiteName: suiteName,
            destination: destination,
            priorBytes: priorBytes,
            buffer: buffer
        )
    }
}
