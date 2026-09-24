//
//  NonBlockingBackgroundSaveFeature.swift
//  MonospaceNotes
//
//  TASK-10-NON-BLOCKING-BACKGROUND-SAVE — owner OWN-NON-BLOCKING-BACKGROUND-SAVE.
//
//  Owns FEAT-NON-BLOCKING-BACKGROUND-SAVE:
//
//    * CON-NON-BLOCKING-BACKGROUND-SAVE-INTERFACE — the buffer is written to a
//      temporary file in the destination's OWN directory and that sibling replaces
//      the destination by rename(2). The write and the rename run off the main
//      thread, so the text view keeps accepting keystrokes while the document is
//      written to disk.
//    * CON-NON-BLOCKING-BACKGROUND-SAVE-RECOVERY — every attempt ends in exactly one
//      of idle / active / succeeded / failed / cancelled, the last valid user state is
//      preserved on every path, every terminal path cleans up (no task, handle, or
//      temporary file is left behind), and the only retry is an explicit one.
//    * CON-DATA-TEMPORARY-SAVE-FILE and CON-PERSISTENCE-TEMPORARY-SAVE-FILE — the
//      temporary save file lives beside the destination (never in a temporary
//      directory), is deleted automatically at its retention boundary, its absence is
//      verified, and a cleanup failure is reported honestly.
//
//  What this feature owns, and what it does not
//  --------------------------------------------
//  USER CLARIFICATION 1: this feature runs ONLY on the autosave timer — 30000 ms after
//  the last edit, reset by every edit. Cmd+S is FEAT-EXPLICIT-SAVE-WITH-CMD-S, and a
//  failed Cmd+S is presented as a modal alert. A failed background save is reported in
//  the NON-MODAL status area instead: this feature produces a `StatusMessage` with
//  `isFailure == true`, and it has no way to produce a modal alert at all — no alert
//  value of any kind is built here, which the focused suite proves structurally over
//  this file.
//
//  The same-directory temporary-then-rename writer is the shared seam
//  `NoteFileAccess.writeAtomically(_:to:)` (owner OWN-DATA-STORE). This feature calls
//  that seam and never implements a writer of its own: there is no temporary
//  directory, no rename, and no destination write in this file.
//
//  The autosave interval
//  ---------------------
//  `startAutosave(buffer:documentURL:)` starts the autosave run for an open document
//  and `noteEdit(at:buffer:documentURL:)` records every edit and resets the deadline.
//  In both cases the deadline is EXACTLY `autosaveInterval` from the instant given (or
//  from the injected clock's current reading), which `scheduledDeadlineMilliseconds`
//  exposes so the interval is asserted exactly, without waiting 30 seconds.
//
//  ACC-NON-BLOCKING-BACKGROUND-SAVE-03 — what is proved
//  ----------------------------------------------------
//  The save is `async` and never blocks the main actor: while an attempt is in flight,
//  the main actor is free, so a keystroke handled at that moment reaches the real text
//  view before the attempt completes. The focused suite orders save-start,
//  keystroke-applied and save-completed deterministically (a writer that parks until
//  the test releases it — no sleeps, no wall-clock windows) and asserts both the
//  ordering and that the character really is in the text view while the attempt is
//  still in flight. The 16 ms figure is the keystroke budget owned by
//  FEAT-KEYSTROKE-RENDERING-UNDER-16MS; this feature adds no keystroke cost of its own,
//  and the suite reports the measured keystroke number rather than asserting a
//  single-sample wall-clock budget on a loaded machine.
//
//  Invariants honoured here
//  ------------------------
//    * No network APIs and no third-party dependencies.
//    * No file I/O on the main actor: the write travels through the shared seam (which
//      performs its work off the main actor) and the cleanup verification runs on a
//      detached task.
//    * `UserDefaults` is not reached from here. The document buffer and the destination
//      are in-memory only; a background save writes the destination and nothing else.
//    * Reporting values name the destination path and a short reason, never the note's
//      contents.
//

import Foundation

// MARK: - The autosave clock

/// The clock the autosave timer waits on. Injected so the 30000 ms interval is asserted
/// exactly against a manually driven clock instead of a 30 second wait, and so the
/// timer's cancellation is observable.
protocol AutosaveClock: Sendable {
    /// The current reading, in milliseconds since this clock's origin. Monotonic: a
    /// later reading is never smaller than an earlier one.
    func nowMilliseconds() -> Int

    /// Suspends for `milliseconds`, or throws `CancellationError` when the wait is
    /// cancelled. A cancelled wait never resumes normally.
    func sleep(milliseconds: Int) async throws
}

/// The real clock: `ContinuousClock` for the reading, and a cancellable task sleep for
/// the wait. Both are monotonic and neither blocks a thread.
struct SystemAutosaveClock: AutosaveClock {
    private let origin: ContinuousClock.Instant

    init() {
        self.origin = ContinuousClock.now
    }

    func nowMilliseconds() -> Int {
        Self.milliseconds(of: origin.duration(to: ContinuousClock.now))
    }

    func sleep(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// A `Duration` as whole milliseconds.
    static func milliseconds(of duration: Duration) -> Int {
        let components = duration.components
        let value = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return Int(value.rounded())
    }
}

// MARK: - Temporary save file verification

/// Verifies the shared writer's cleanup boundary: which temporary siblings of a
/// destination are still present. CON-PERSISTENCE-TEMPORARY-SAVE-FILE requires the
/// absence of the temporary save file to be verified and a cleanup failure to be
/// reported honestly, so this is a real check and not an assumed one.
protocol TemporarySaveFileVerifying: Sendable {
    /// The names of the shared writer's temporary siblings still present in the
    /// destination's own directory, sorted.
    func temporarySiblingNames(beside destination: URL) async -> [String]
}

/// The real verification: lists the destination's own directory on a detached task (so
/// the main actor never performs the listing) and keeps the entries that carry the
/// shared writer's temporary-file marker.
struct DirectoryTemporarySaveFileVerifier: TemporarySaveFileVerifying {
    /// The marker `DataStore.temporarySiblingURL(for:)` puts in the name of the
    /// same-directory temporary file: `.<destination>.<marker><uuid>`.
    static let marker: String = ".mn-save-"

    private let recorder: FileIOThreadRecorder?

    /// - Parameter recorder: the composition root's recorder, so this verification is
    ///   recorded like every other I/O entry point and a main-thread listing would be
    ///   visible as a violation.
    init(recorder: FileIOThreadRecorder? = nil) {
        self.recorder = recorder
    }

    func temporarySiblingNames(beside destination: URL) async -> [String] {
        let prefix = Self.temporarySiblingPrefix(for: destination)
        let directory = destination.deletingLastPathComponent()
        let recorder = self.recorder
        return await Task.detached(priority: .utility) {
            // Recorded where the work happens: off the main thread.
            recorder?.record()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.filter { $0.hasPrefix(prefix) }.sorted()
        }.value
    }

    /// The name prefix of the shared writer's temporary sibling for `destination`.
    static func temporarySiblingPrefix(for destination: URL) -> String {
        "." + destination.lastPathComponent + marker
    }
}

// MARK: - The feature

@MainActor
final class NonBlockingBackgroundSaveFeature {

    // MARK: - Locked surface

    /// The locked autosave interval: 30000 ms after the last edit.
    nonisolated static let autosaveIntervalMilliseconds: Int = 30_000

    /// The same interval as a `Duration`.
    nonisolated static let autosaveInterval: Duration = .milliseconds(30_000)

    /// The locked prefix of the non-modal status a failed background save reports:
    /// `Background save failed for <path>: <reason>`.
    nonisolated static let failureStatusPrefix: String = "Background save failed for "

    /// The locked user-facing status text of a failed background save.
    static func failureStatusMessage(path: URL, reason: String) -> StatusMessage {
        StatusMessage(
            text: failureStatusPrefix + path.path + ": " + reason,
            isFailure: true
        )
    }

    /// Why a background save did not commit the buffer.
    enum FailureReason: String, Sendable, Equatable {
        /// The shared writer's temporary write or rename failed. The destination keeps
        /// its prior bytes and the temporary sibling was removed.
        case writeFailed
        /// The shared writer could not remove its temporary sibling.
        case cleanupFailed
        /// The writer reported success, yet a temporary sibling is still beside the
        /// destination.
        case temporaryFileLeftBehind
    }

    /// Why an autosave attempt ended without writing.
    enum CancellationReason: String, Sendable, Equatable {
        /// The document has no path yet, so a background autosave has no destination.
        /// Choosing one is the explicit Cmd+S / save-panel route, never a background
        /// save, which never presents UI.
        case noDestination
        /// The attempt was interrupted before it reached the shared writer.
        case interruptedBeforeWrite
        /// The attempt was interrupted while the shared writer was running.
        case interruptedDuringWrite
    }

    /// One background save attempt.
    struct BackgroundSaveOutcome: Equatable, Sendable {
        /// The state the attempt ended in: `.succeeded`, `.failed` or `.cancelled`.
        /// (`idle` and `active` only ever describe the feature before and during an
        /// attempt; an attempt that returns has reached a terminal state.)
        let state: OperationState

        /// The non-modal status to show, or `nil`. A failed attempt produces the locked
        /// `Background save failed for <path>: <reason>` message; a success and an
        /// interruption produce none (an interruption is not an error).
        let statusMessage: StatusMessage?

        /// `true` exactly when no temporary sibling of the destination is left behind
        /// after this attempt, as reported by the cleanup verification.
        let temporaryFileRemoved: Bool

        /// The destination this attempt addressed; `nil` only when the document has no
        /// path. A caller adopts this path only on success: a failed attempt leaves the
        /// document on its last valid path.
        let url: URL?

        /// The failure, when the attempt failed.
        let failureReason: FailureReason?

        /// The interruption, when the attempt was cancelled without writing.
        let cancellationReason: CancellationReason?

        /// `true` exactly when the attempt succeeded: the buffer is on disk, so the
        /// unsaved-changes marker may be cleared. Derived from `state`, so it can never
        /// claim a cleared marker for an attempt that did not commit the buffer.
        let clearedUnsavedMarker: Bool

        init(
            state: OperationState,
            statusMessage: StatusMessage?,
            temporaryFileRemoved: Bool,
            url: URL? = nil,
            failureReason: FailureReason? = nil,
            cancellationReason: CancellationReason? = nil
        ) {
            self.state = state
            self.statusMessage = statusMessage
            self.temporaryFileRemoved = temporaryFileRemoved
            self.url = url
            self.failureReason = failureReason
            self.cancellationReason = cancellationReason
            self.clearedUnsavedMarker = state == .succeeded
        }
    }

    // MARK: - Injected services

    /// The shared note-file seam. Every save goes through
    /// `writeAtomically(_:to:)` — the same-directory temporary file plus rename that
    /// Cmd+S and the panel flows use. This feature never writes, renames, or removes
    /// anything itself.
    private let noteFiles: any NoteFileAccess

    /// The clock the autosave timer waits on.
    private let clock: any AutosaveClock

    /// The cleanup verification of the shared writer's temporary sibling.
    private let temporaryFileVerifier: any TemporarySaveFileVerifying

    /// - Parameters:
    ///   - noteFiles: the shared note-file seam (the real `DataStore` in the app).
    ///   - clock: the autosave clock. The default is the real monotonic clock; the
    ///     focused suite injects a manually driven one so the interval is asserted
    ///     exactly.
    ///   - temporaryFileVerifier: the cleanup verification. The default lists the
    ///     destination's directory off the main actor.
    init(
        noteFiles: any NoteFileAccess,
        clock: any AutosaveClock = SystemAutosaveClock(),
        temporaryFileVerifier: any TemporarySaveFileVerifying = DirectoryTemporarySaveFileVerifier()
    ) {
        self.noteFiles = noteFiles
        self.clock = clock
        self.temporaryFileVerifier = temporaryFileVerifier
    }

    // MARK: - Operation state (idle / active / succeeded / failed / cancelled)

    /// The state of the most recent attempt. `.idle` until the first attempt.
    private(set) var backgroundSaveState: OperationState = .idle

    /// The most recent attempt, whatever its outcome.
    private(set) var lastOutcome: BackgroundSaveOutcome?

    /// The exact buffer the most recent *successful* attempt committed to disk, `nil`
    /// until then. The composition root compares it with the live buffer to decide
    /// whether a successful autosave really saved the current text (no edit landed while
    /// the write was in flight), so the dirty marker is only cleared when that is true.
    private(set) var lastSavedBuffer: String?

    /// How many attempts have been made. A failed attempt counts: it was attempted. An
    /// attempt that found no destination never reached the writer and does not count.
    private(set) var writeAttemptCount: Int = 0

    /// How many attempts found no destination, i.e. the document had no path yet.
    private(set) var skippedWithoutDestinationCount: Int = 0

    /// Published when an attempt reaches a terminal state, so the composition root can
    /// mirror it into its operation state and the non-modal status area — and never into
    /// a modal alert.
    var onOutcome: (@MainActor (BackgroundSaveOutcome) -> Void)?

    // MARK: - Autosave timer state

    /// The buffer the next autosave will write: the buffer as of the last recorded edit
    /// (or of the last `startAutosave`).
    private(set) var autosaveBuffer: String = ""

    /// The destination the next autosave will write to; `nil` while the document has no
    /// path. A background save never chooses one.
    private(set) var autosaveDestination: URL?

    /// The instant of the last recorded edit, in milliseconds on the injected clock.
    private(set) var lastEditMilliseconds: Int?

    /// The instant the armed timer will fire: exactly `lastEditMilliseconds +
    /// autosaveIntervalMilliseconds`. `nil` when no timer is armed.
    private(set) var scheduledDeadlineMilliseconds: Int?

    /// The number of autosave waits still scheduled: 1 while the timer is armed and 0
    /// when it is not (before the first edit, after the timer fired, and after
    /// `cancel()`).
    var pendingAutosaveCount: Int { scheduledDeadlineMilliseconds == nil ? 0 : 1 }

    /// Whether a background save attempt is in flight.
    var isSaving: Bool { attemptTasks.isEmpty == false }

    /// Everything this feature currently has running: the armed timer plus every
    /// in-flight attempt. Zero means nothing is left running.
    var runningOperationCount: Int { pendingAutosaveCount + attemptTasks.count }

    // MARK: - Private task bookkeeping

    private var timerTask: Task<Void, Never>?
    private var timerGeneration = 0
    private var cancellationEpoch = 0
    private var attemptGeneration = 0
    private var attemptTasks: [Int: Task<BackgroundSaveOutcome, Never>] = [:]

    // MARK: - The autosave run

    /// Starts (or restarts) the autosave run for an open document: the buffer and the
    /// destination are recorded and the timer is armed for exactly `autosaveInterval`
    /// from `time` — the injected clock's current reading when `time` is `nil`.
    ///
    /// A document with no destination still arms the timer: the attempt then reports
    /// that it had nowhere to write, instead of inventing a path or presenting UI.
    func startAutosave(buffer: String, documentURL: URL?, at time: Int? = nil) {
        record(buffer: buffer, documentURL: documentURL)
        armTimer(fromMilliseconds: time ?? clock.nowMilliseconds())
    }

    /// One edit at `time` — milliseconds on the injected clock; `nil` means the clock's
    /// current reading. The autosave interval is reset to exactly 30000 ms from that
    /// instant, which is what "the background autosave interval of 30000ms after the
    /// last edit" means.
    func noteEdit(at time: Int? = nil) {
        armTimer(fromMilliseconds: time ?? clock.nowMilliseconds())
    }

    /// One edit that also records what the autosave will write: the edited buffer and the
    /// document's current path (`nil` while the document has no path). Every edit resets
    /// the deadline, so the attempt that fires always writes the buffer of the last edit.
    func noteEdit(at time: Int? = nil, buffer: String, documentURL: URL?) {
        record(buffer: buffer, documentURL: documentURL)
        armTimer(fromMilliseconds: time ?? clock.nowMilliseconds())
    }

    /// Arms (or re-arms) the autosave timer. Re-arming cancels the previous wait, so
    /// exactly one wait is ever pending and every edit moves the deadline.
    private func armTimer(fromMilliseconds editMilliseconds: Int) {
        timerTask?.cancel()
        timerTask = nil

        lastEditMilliseconds = editMilliseconds
        scheduledDeadlineMilliseconds = editMilliseconds + Self.autosaveIntervalMilliseconds
        timerGeneration += 1
        let generation = timerGeneration
        let epoch = cancellationEpoch
        let clock = self.clock

        let task = Task { [self] in
            do {
                try await clock.sleep(milliseconds: Self.autosaveIntervalMilliseconds)
            } catch {
                // The wait was cancelled — by cancel(), or because a newer edit replaced
                // this timer. Nothing is saved and nothing keeps running.
                return
            }
            // A wait that resumed for a timer that is no longer the current one, or one
            // that was cancelled while it was resuming, must not start an attempt.
            guard generation == timerGeneration,
                  epoch == cancellationEpoch,
                  Task.isCancelled == false else { return }
            await timerFired()
        }
        timerTask = task
    }

    /// The armed timer reached its deadline: one attempt with the recorded buffer and
    /// destination. The timer is disarmed first, so the attempt is the only thing left
    /// running and a completed run leaves nothing pending.
    private func timerFired() async {
        timerTask = nil
        scheduledDeadlineMilliseconds = nil
        let text = autosaveBuffer
        let destination = autosaveDestination
        _ = await startAttempt(text: text, documentURL: destination)
    }

    /// Cancels the autosave timer and any in-flight save, and awaits both, so nothing is
    /// left running when this returns. The last valid user state — the recorded buffer
    /// and destination — is preserved; an edit after this starts a new run.
    ///
    /// - Returns: how many operations were interrupted: 0, 1 or 2.
    @discardableResult
    func cancel() async -> Int {
        cancellationEpoch += 1

        let pendingTimer = scheduledDeadlineMilliseconds != nil ? 1 : 0
        let pendingAttempts = attemptTasks
        let cancelledCount = pendingTimer + pendingAttempts.count

        scheduledDeadlineMilliseconds = nil
        let timer = timerTask
        timerTask = nil

        timer?.cancel()
        for (_, task) in pendingAttempts {
            task.cancel()
        }
        await timer?.value
        for (_, task) in pendingAttempts {
            _ = await task.value
        }
        // Nothing is left running: every interrupted task has completed and released its
        // own bookkeeping, so any entry still present is stale.
        if attemptTasks.isEmpty == false {
            attemptTasks.removeAll()
        }
        return cancelledCount
    }

    // MARK: - The attempt

    /// Saves `text` to `documentURL` now: one background save, outside the autosave
    /// timer. The caller awaits the terminal outcome; the attempt itself is tracked, so
    /// `cancel()` can interrupt it.
    @discardableResult
    func saveNow(text: String, documentURL: URL?) async -> BackgroundSaveOutcome {
        await startAttempt(text: text, documentURL: documentURL)
    }

    /// Runs one attempt on its own tracked task and awaits it.
    ///
    /// A caller that is already cancelled starts no attempt at all: nothing is written,
    /// no task is created, and the cancellation is reported as `.cancelled` — the
    /// tracked task is only ever created for a caller that is still live, and `cancel()`
    /// can interrupt it from there.
    private func startAttempt(text: String, documentURL: URL?) async -> BackgroundSaveOutcome {
        guard Task.isCancelled == false else {
            return publish(
                BackgroundSaveOutcome(
                    state: .cancelled,
                    statusMessage: nil,
                    temporaryFileRemoved: true,
                    url: documentURL,
                    cancellationReason: documentURL == nil ? .noDestination : .interruptedBeforeWrite
                )
            )
        }

        attemptGeneration += 1
        let generation = attemptGeneration
        let task = Task { [self] in
            let outcome = await runAttempt(text: text, documentURL: documentURL)
            // Cleanup on this attempt's terminal path: the handle is dropped before the
            // terminal outcome is handed back, so a caller that sees the outcome also
            // sees that nothing about this attempt is still running.
            attemptTasks[generation] = nil
            return outcome
        }
        attemptTasks[generation] = task
        return await task.value
    }

    private func runAttempt(text: String, documentURL: URL?) async -> BackgroundSaveOutcome {
        backgroundSaveState = .active
        let outcome = await performAttempt(text: text, documentURL: documentURL)
        return publish(outcome)
    }

    /// Publishes one terminal outcome: the feature's own operation state, its record of
    /// the last attempt, and the composition root's callback — which is the surface a
    /// failure reaches the user through, and it is a status value, never an alert.
    @discardableResult
    private func publish(_ outcome: BackgroundSaveOutcome) -> BackgroundSaveOutcome {
        lastOutcome = outcome
        backgroundSaveState = outcome.state
        onOutcome?(outcome)
        return outcome
    }

    private func performAttempt(text: String, documentURL: URL?) async -> BackgroundSaveOutcome {
        guard let destination = documentURL else {
            // No destination: nothing to write to. A background save never invents a
            // path and never presents UI, so this is a cancelled attempt — not a write
            // failure — and it reports honestly that it had nowhere to write.
            skippedWithoutDestinationCount += 1
            return BackgroundSaveOutcome(
                state: .cancelled,
                statusMessage: nil,
                temporaryFileRemoved: true,
                url: nil,
                cancellationReason: .noDestination
            )
        }

        if Task.isCancelled {
            // Interrupted before reaching the writer: nothing was attempted, so the
            // destination is untouched and there is nothing to clean up.
            return BackgroundSaveOutcome(
                state: .cancelled,
                statusMessage: nil,
                temporaryFileRemoved: true,
                url: destination,
                cancellationReason: .interruptedBeforeWrite
            )
        }

        writeAttemptCount += 1
        do {
            try await noteFiles.writeAtomically(text, to: destination)
        } catch is CancellationError {
            // The shared writer reports that it moved no bytes; an interruption is not
            // an error, so the status area stays clean and the destination keeps its
            // bytes. The verification still reports honestly whether a temporary
            // sibling is present.
            let leftovers = await temporarySiblingNames(beside: destination)
            return BackgroundSaveOutcome(
                state: .cancelled,
                statusMessage: nil,
                temporaryFileRemoved: leftovers.isEmpty,
                url: destination,
                cancellationReason: .interruptedDuringWrite
            )
        } catch {
            let leftovers = await temporarySiblingNames(beside: destination)
            let reason = Self.reason(for: error)
            return BackgroundSaveOutcome(
                state: .failed,
                statusMessage: Self.failureStatusMessage(path: destination, reason: reason),
                temporaryFileRemoved: leftovers.isEmpty,
                url: destination,
                failureReason: Self.failureReason(for: error, leftovers: leftovers)
            )
        }

        // The writer reported success. Verify the retention boundary it promises: no
        // temporary sibling may remain beside the destination.
        let leftovers = await temporarySiblingNames(beside: destination)
        guard leftovers.isEmpty else {
            return BackgroundSaveOutcome(
                state: .failed,
                statusMessage: Self.failureStatusMessage(
                    path: destination,
                    reason: "the temporary save file was left behind"
                ),
                temporaryFileRemoved: false,
                url: destination,
                failureReason: .temporaryFileLeftBehind
            )
        }

        lastSavedBuffer = text
        return BackgroundSaveOutcome(
            state: .succeeded,
            statusMessage: nil,
            temporaryFileRemoved: true,
            url: destination
        )
    }

    // MARK: - Private

    private func record(buffer: String, documentURL: URL?) {
        autosaveBuffer = buffer
        autosaveDestination = documentURL
    }

    /// The temporary siblings of `destination` still present, asked of the injected
    /// verification.
    private func temporarySiblingNames(beside destination: URL) async -> [String] {
        await temporaryFileVerifier.temporarySiblingNames(beside: destination)
    }

    /// The short, content-free reason a write failed. The shared writer's own failure
    /// vocabulary is preferred because it is already short, and it never carries a
    /// directory path.
    static func reason(for error: Error) -> String {
        if let operationError = error as? DataStore.OperationError {
            return operationError.failureReason
        }
        let described = String(describing: error)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return described.isEmpty ? "an unknown error" : described
    }

    /// Which failure a failed attempt reports: the writer's own cleanup failure when its
    /// temporary sibling is still present, and otherwise the write itself.
    static func failureReason(for error: Error, leftovers: [String]) -> FailureReason {
        if let operationError = error as? DataStore.OperationError {
            if case .cleanupFailed = operationError { return .cleanupFailed }
        }
        return leftovers.isEmpty ? .writeFailed : .cleanupFailed
    }
}
