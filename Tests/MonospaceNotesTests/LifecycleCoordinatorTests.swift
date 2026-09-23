//
//  LifecycleCoordinatorTests.swift
//  MonospaceNotesTests
//
//  TASK-03-LIFECYCLE-COORDINATOR focused suite — owner OWN-LIFECYCLE-COORDINATOR.
//
//  Covers CON-LIFECYCLE-APPLICATION-LAUNCH, CON-LIFECYCLE-APPLICATION-TERMINATION
//  and CON-LIFECYCLE-PRESET against the real `LifecycleCoordinator`.
//
//  The cancellation proof is behavioural and deterministic, not taken on trust. A
//  registered task parks on a barrier that only cancellation (or an explicit release by
//  the test) can open, and every test waits for that task's own "I am parked" handshake
//  before it calls `beginTermination()`. A registered task therefore can never finish on
//  its own inside a wall-clock window — on a quiet machine or a loaded one — so the old
//  failure mode is structurally impossible: a probe whose sleep expired before
//  termination ran, was then counted as finished, was never cancelled, and had already
//  recorded its side effect. Termination still has to cancel the task, cancellation
//  still has to reach the task, and the side effect must still be absent once termination
//  returned and the task has been awaited to completion — so the assertions prove that
//  cancellation reached the task, not merely that termination returned.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import Foundation
import Testing

@testable import MonospaceNotes

// MARK: - File-scope fixtures (unique names: every test file compiles together)

/// Thread-safe record of what a registered task actually did. Registered tasks run
/// detached, so every mutation is lock-protected.
private final class LifecycleCoordinatorTestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var cancellationsObserved = 0

    func noteCancellation() {
        lock.lock()
        defer { lock.unlock() }
        cancellationsObserved += 1
    }

    func note(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var recordedEvents: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    var sideEffectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    var cancellationObservedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellationsObserved
    }

    func hasRecorded(_ event: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains(event)
    }
}

/// Deterministic stand-in for registered long-running work.
///
/// The task parks on a barrier that only cancellation or an explicit `release()` from the
/// test can open, so it can never complete on its own: no wall-clock window can expire
/// behind the test's back, whatever else the machine is doing. The cancellation branch
/// records the cancellation and never reaches the side effect; the released branch records
/// the side effect, which is how work that finishes on its own is modelled.
/// `waitUntilParked()` is the handshake that proves a task has reached its parked state,
/// so a test never calls `beginTermination()` while a probe is still starting up.
private final class LifecycleCoordinatorTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var parkedContinuation: CheckedContinuation<Void, Error>?
    private var parkedWaiters: [CheckedContinuation<Void, Never>] = []
    private var isParked = false
    private var isReleased = false
    private var isCancelled = false

    /// Creates the task a test registers. It parks until it is cancelled — recording the
    /// cancellation, never the side effect — or until the test releases it.
    func makeTask(
        probe: LifecycleCoordinatorTestProbe,
        sideEffect: String,
        cleanupOnCancellation: String? = nil
    ) -> Task<Void, Never> {
        Task.detached { [self] in
            do {
                try await park()
            } catch {
                // Cancellation reached the task: the side effect must never appear, and
                // any cleanup work the task owns is recorded after the cancellation.
                probe.noteCancellation()
                if let cleanupOnCancellation {
                    probe.note(cleanupOnCancellation)
                }
                return
            }
            probe.note(sideEffect)
        }
    }

    /// Waits until the task has signalled that it reached the barrier, so termination can
    /// never race a probe that has not started waiting yet.
    func waitUntilParked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isParked {
                lock.unlock()
                continuation.resume()
                return
            }
            parkedWaiters.append(continuation)
            lock.unlock()
        }
    }

    /// Opens the barrier so the task finishes on its own and records its side effect.
    func release() {
        lock.lock()
        isReleased = true
        let continuation = parkedContinuation
        parkedContinuation = nil
        lock.unlock()
        continuation?.resume(returning: ())
    }

    /// Suspends until `release()` or cancellation. A task that is already cancelled never
    /// parks at all, so cancellation is never lost to a scheduling race.
    private func park() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if isCancelled || Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if isReleased {
                    lock.unlock()
                    continuation.resume(returning: ())
                    return
                }
                parkedContinuation = continuation
                isParked = true
                let waiters = parkedWaiters
                parkedWaiters.removeAll()
                lock.unlock()
                for waiter in waiters { waiter.resume() }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        lock.lock()
        isCancelled = true
        let continuation = parkedContinuation
        parkedContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}

/// A real launch failure: something the preset lifecycle could report.
private enum LifecycleCoordinatorTestLaunchError: Error, CustomStringConvertible {
    case handshakeTimedOut

    var description: String { "startup handshake timed out" }
}

/// Waits for the coordinator to observe its registered work finishing.
///
/// This is an event wait, not a wall-clock window: it hands the main actor back (which is
/// what lets the coordinator's own completion watch run) and returns as soon as the count
/// matches, so an idle machine pays nothing and a loaded one is never failed by
/// scheduling alone. The bounded fallback exists only so that a genuine product bug
/// reports a failure instead of hanging the suite.
@MainActor
private func lifecycleCoordinatorTestWaitForActiveTaskCount(
    _ expected: Int,
    in coordinator: LifecycleCoordinator
) async -> Int {
    var spins = 0
    while coordinator.activeTaskCount != expected && spins < 20_000 {
        await Task.yield()
        spins += 1
        if spins % 256 == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    var waitedMilliseconds = 0
    while coordinator.activeTaskCount != expected && waitedMilliseconds < 10_000 {
        try? await Task.sleep(for: .milliseconds(5))
        waitedMilliseconds += 5
    }

    return coordinator.activeTaskCount
}

// MARK: - Suite

@Suite("Lifecycle coordinator")
struct LifecycleCoordinatorTests {

    // MARK: - Initial state and vocabulary

    @Test("A new coordinator is idle, starts no work, and owns nothing")
    @MainActor
    func startsIdleAndStartsNoWork() {
        let coordinator = LifecycleCoordinator()

        #expect(coordinator.phase == .idle)
        #expect(coordinator.launchState == .idle)
        #expect(coordinator.activeTaskCount == 0)
        #expect(coordinator.releasedAppKitDelegateCount == 0)
        #expect(coordinator.isTerminated == false)
    }

    @Test("The phase vocabulary is the fixed six-case state machine")
    func phaseVocabularyIsFixed() {
        #expect(LifecycleCoordinator.Phase(rawValue: "idle") == .idle)
        #expect(LifecycleCoordinator.Phase(rawValue: "launching") == .launching)
        #expect(LifecycleCoordinator.Phase(rawValue: "ready") == .ready)
        #expect(LifecycleCoordinator.Phase(rawValue: "failed") == .failed)
        #expect(LifecycleCoordinator.Phase(rawValue: "terminating") == .terminating)
        #expect(LifecycleCoordinator.Phase(rawValue: "terminated") == .terminated)
        #expect(LifecycleCoordinator.Phase(rawValue: "unknown") == nil)
    }

    // MARK: - Launch

    @Test("Launch moves idle -> launching -> ready and reports each phase")
    @MainActor
    func launchReachesReady() {
        let coordinator = LifecycleCoordinator()

        #expect(coordinator.beginLaunch() == .launching)
        #expect(coordinator.phase == .launching)
        #expect(coordinator.launchState == .active)
        #expect(coordinator.isTerminated == false)

        #expect(coordinator.completeLaunch() == .ready)
        #expect(coordinator.phase == .ready)
        #expect(coordinator.launchState == .succeeded)
    }

    @Test("A launch already in flight is not restarted and a completed launch is not re-opened")
    @MainActor
    func launchAttemptsAreNotRestarted() {
        let coordinator = LifecycleCoordinator()

        #expect(coordinator.beginLaunch() == .launching)
        #expect(coordinator.beginLaunch() == .launching, "One launch attempt at a time")
        #expect(coordinator.launchState == .active)

        #expect(coordinator.completeLaunch() == .ready)
        #expect(coordinator.beginLaunch() == .ready, "A completed launch is never re-opened")
        #expect(coordinator.phase == .ready)
        #expect(coordinator.launchState == .succeeded)
        #expect(coordinator.completeLaunch() == .ready)
    }

    @Test("A failed launch is reported, rolled back, and never converted to ready")
    @MainActor
    func failedLaunchIsNeverConvertedToReady() {
        let coordinator = LifecycleCoordinator()
        #expect(coordinator.beginLaunch() == .launching)

        let alert = coordinator.failLaunch(LifecycleCoordinatorTestLaunchError.handshakeTimedOut)

        #expect(alert.title == "Could Not Launch")
        #expect(alert.message.isEmpty == false)
        #expect(alert.message.contains("startup handshake timed out"),
                "The alert must carry the failure reason")
        #expect(coordinator.phase == .failed)
        #expect(coordinator.launchState == .failed)
        #expect(coordinator.isTerminated == false)

        // The interrupted transition must never be published as complete.
        #expect(coordinator.completeLaunch() == .failed)
        #expect(coordinator.phase == .failed)
        #expect(coordinator.launchState == .failed)
        #expect(coordinator.launchState != .succeeded)
    }

    @Test("A failed launch reports an AppStateError reason without inventing a success")
    @MainActor
    func failedLaunchReportsAppStateError() {
        let coordinator = LifecycleCoordinator()
        #expect(coordinator.beginLaunch() == .launching)

        let alert = coordinator.failLaunch(
            AppStateError.initializationFailed("No note file access is configured")
        )

        #expect(alert.title == "Could Not Launch")
        #expect(alert.message.contains("Initialization failed"),
                "An AppStateError reason is used as written")
        #expect(coordinator.phase == .failed)
        #expect(coordinator.launchState == .failed)
    }

    @Test("A failed launch can be retried and then completes honestly")
    @MainActor
    func failedLaunchCanBeRetried() {
        let coordinator = LifecycleCoordinator()
        #expect(coordinator.beginLaunch() == .launching)
        _ = coordinator.failLaunch(LifecycleCoordinatorTestLaunchError.handshakeTimedOut)
        #expect(coordinator.phase == .failed)

        #expect(coordinator.beginLaunch() == .launching)
        #expect(coordinator.launchState == .active)
        #expect(coordinator.completeLaunch() == .ready)
        #expect(coordinator.phase == .ready)
        #expect(coordinator.launchState == .succeeded)
    }

    @Test("A failure reported after a completed launch does not un-complete it")
    @MainActor
    func lateFailureKeepsACompletedLaunch() {
        let coordinator = LifecycleCoordinator()
        _ = coordinator.beginLaunch()
        _ = coordinator.completeLaunch()

        let alert = coordinator.failLaunch(LifecycleCoordinatorTestLaunchError.handshakeTimedOut)

        #expect(alert.title == "Could Not Launch")
        #expect(coordinator.phase == .ready, "A completed transition is not un-completed")
        #expect(coordinator.launchState == .succeeded)
    }

    // MARK: - Rollback of a failed launch

    @Test("A failed launch rolls back only what that attempt registered")
    @MainActor
    func failedLaunchRollsBackOnlyTheAttemptsResources() async throws {
        let coordinator = LifecycleCoordinator()
        let probe = LifecycleCoordinatorTestProbe()

        // Work registered before any launch attempt belongs to the owner, not to the
        // attempt, so a rollback must leave it running.
        let preLaunchGate = LifecycleCoordinatorTestGate()
        let preLaunchWork = preLaunchGate.makeTask(probe: probe, sideEffect: "pre-launch-work")
        coordinator.register(preLaunchWork)
        await preLaunchGate.waitUntilParked()
        #expect(coordinator.activeTaskCount == 1)

        #expect(coordinator.beginLaunch() == .launching)
        let launchScopedGate = LifecycleCoordinatorTestGate()
        let launchScopedWork = launchScopedGate.makeTask(probe: probe, sideEffect: "launch-scoped-work")
        coordinator.register(launchScopedWork)
        await launchScopedGate.waitUntilParked()
        coordinator.registerAppKitDelegate()
        #expect(coordinator.activeTaskCount == 2)

        let alert = coordinator.failLaunch(LifecycleCoordinatorTestLaunchError.handshakeTimedOut)

        #expect(alert.title == "Could Not Launch")
        #expect(coordinator.phase == .failed)
        #expect(coordinator.launchState == .failed)

        // The attempt's resources are cancelled and released.
        try #require(launchScopedWork.isCancelled)
        #expect(coordinator.releasedAppKitDelegateCount == 1,
                "The delegate registered during the attempt is released by the rollback")
        await launchScopedWork.value

        // The owner's pre-launch work is not touched: it is still parked, and only the
        // test's own release lets it finish and record its side effect.
        #expect(preLaunchWork.isCancelled == false)
        preLaunchGate.release()
        await preLaunchWork.value
        #expect(probe.hasRecorded("pre-launch-work"), "Work registered before the attempt must keep running")
        #expect(probe.hasRecorded("launch-scoped-work") == false)
        #expect(probe.cancellationObservedCount == 1)

        // Cleanup: the attempt's work is already finished, so termination has nothing
        // left to cancel and reports 0.
        let idled = await lifecycleCoordinatorTestWaitForActiveTaskCount(0, in: coordinator)
        #expect(idled == 0)
        let cancelled = await coordinator.beginTermination()
        #expect(cancelled == 0)
        #expect(coordinator.isTerminated)
        #expect(probe.sideEffectCount == 1)
    }

    @Test("A completed launch keeps its delegates out of the rollback scope")
    @MainActor
    func completedLaunchClearsTheRollbackScope() {
        let coordinator = LifecycleCoordinator()
        #expect(coordinator.beginLaunch() == .launching)
        coordinator.registerAppKitDelegate()
        #expect(coordinator.completeLaunch() == .ready)
        #expect(coordinator.releasedAppKitDelegateCount == 0)

        _ = coordinator.failLaunch(LifecycleCoordinatorTestLaunchError.handshakeTimedOut)

        #expect(coordinator.releasedAppKitDelegateCount == 0,
                "What a completed launch owns is not launch-attempt resource")
    }

    // MARK: - Cancellation proof

    @Test("Termination really cancels and awaits a registered sleeping task")
    @MainActor
    func terminationCancelsRegisteredWork() async {
        let coordinator = LifecycleCoordinator()
        let probe = LifecycleCoordinatorTestProbe()
        #expect(coordinator.beginLaunch() == .launching)
        #expect(coordinator.completeLaunch() == .ready)

        let gate = LifecycleCoordinatorTestGate()
        let task = gate.makeTask(probe: probe, sideEffect: "post-sleep-side-effect")
        coordinator.register(task)
        // Proof the probe is parked before termination runs: the task cannot finish by
        // itself, so nothing here depends on how long the machine takes.
        await gate.waitUntilParked()
        coordinator.registerAppKitDelegate()
        #expect(coordinator.activeTaskCount == 1)

        let cancelled = await coordinator.beginTermination()

        #expect(cancelled == 1, "beginTermination reports the task it cancelled")
        #expect(task.isCancelled, "The registered task itself must have been cancelled")
        #expect(coordinator.activeTaskCount == 0)
        #expect(coordinator.isTerminated)
        #expect(coordinator.phase == .terminated)
        #expect(coordinator.releasedAppKitDelegateCount == 1)
        #expect(coordinator.launchState == .succeeded,
                "A launch that completed is still reported as succeeded")

        // Termination awaited the task, so the task's whole life has already played out;
        // this window can only add confirmation that nothing follows the point where the
        // task would have recorded its side effect.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(probe.sideEffectCount == 0, "A cancelled task must never reach its side effect")
        #expect(probe.cancellationObservedCount == 1)
        #expect(coordinator.activeTaskCount == 0, "Termination leaves no task running behind it")
    }

    @Test("Termination cancels and reports every registered task")
    @MainActor
    func terminationCancelsEveryRegisteredTask() async {
        let coordinator = LifecycleCoordinator()
        let probe = LifecycleCoordinatorTestProbe()
        let firstGate = LifecycleCoordinatorTestGate()
        let secondGate = LifecycleCoordinatorTestGate()
        let first = firstGate.makeTask(probe: probe, sideEffect: "first")
        let second = secondGate.makeTask(probe: probe, sideEffect: "second")
        coordinator.register(first)
        coordinator.register(second)
        await firstGate.waitUntilParked()
        await secondGate.waitUntilParked()
        #expect(coordinator.activeTaskCount == 2)

        let cancelled = await coordinator.beginTermination()

        #expect(cancelled == 2)
        #expect(first.isCancelled)
        #expect(second.isCancelled)
        #expect(coordinator.activeTaskCount == 0)

        // Both probes were cancelled and have provably finished, so neither side effect
        // may ever appear — not even after the window that used to decide this.
        try? await Task.sleep(for: .milliseconds(600))
        #expect(probe.sideEffectCount == 0)
        #expect(probe.recordedEvents.isEmpty)
    }

    @Test("Termination awaits registered work before it reports completion")
    @MainActor
    func terminationAwaitsRegisteredWork() async {
        let coordinator = LifecycleCoordinator()
        let probe = LifecycleCoordinatorTestProbe()
        let gate = LifecycleCoordinatorTestGate()
        // The task reaches its cleanup only after cancellation, and termination has to
        // await that.
        let task = gate.makeTask(
            probe: probe,
            sideEffect: "task-cleanup-finished",
            cleanupOnCancellation: "task-cleanup-finished"
        )
        coordinator.register(task)
        await gate.waitUntilParked()

        let cancelled = await coordinator.beginTermination()

        #expect(cancelled == 1)
        #expect(probe.hasRecorded("task-cleanup-finished"),
                "beginTermination must await the registered task before returning")
        #expect(coordinator.activeTaskCount == 0)
        #expect(coordinator.isTerminated)
        await task.value
        #expect(task.isCancelled)
    }

    @Test("Termination counts only the work it actually cancelled")
    @MainActor
    func terminationCountsOnlyCancelledWork() async {
        let coordinator = LifecycleCoordinator()
        let probe = LifecycleCoordinatorTestProbe()
        let finishedGate = LifecycleCoordinatorTestGate()
        let finished = finishedGate.makeTask(probe: probe, sideEffect: "finished-on-its-own")
        coordinator.register(finished)
        #expect(coordinator.activeTaskCount == 1)

        // The barrier is opened by the test, never by cancellation: the task runs to its
        // side effect exactly like work that finishes on its own.
        finishedGate.release()
        await finished.value
        let idled = await lifecycleCoordinatorTestWaitForActiveTaskCount(0, in: coordinator)
        #expect(idled == 0, "A task that finished on its own is no longer active")
        #expect(probe.hasRecorded("finished-on-its-own"))

        let cancelled = await coordinator.beginTermination()
        #expect(cancelled == 0, "Nothing was cancelled because nothing was still running")
        #expect(coordinator.activeTaskCount == 0)
        #expect(coordinator.isTerminated)
    }

    // MARK: - Interrupted launches

    @Test("An interrupted launch is never reported as a completed transition")
    @MainActor
    func interruptedLaunchIsNeverReportedComplete() async {
        let coordinator = LifecycleCoordinator()
        let probe = LifecycleCoordinatorTestProbe()
        #expect(coordinator.beginLaunch() == .launching)
        #expect(coordinator.launchState == .active)

        let gate = LifecycleCoordinatorTestGate()
        let task = gate.makeTask(probe: probe, sideEffect: "never")
        coordinator.register(task)
        await gate.waitUntilParked()
        coordinator.registerAppKitDelegate()

        let cancelled = await coordinator.beginTermination()

        #expect(cancelled == 1)
        #expect(coordinator.phase == .terminated)
        #expect(coordinator.launchState == .cancelled)
        #expect(coordinator.launchState != .succeeded)

        // A late completion must not rewrite the interrupted transition.
        #expect(coordinator.completeLaunch() == .terminated)
        #expect(coordinator.phase == .terminated)
        #expect(coordinator.launchState == .cancelled)

        // Termination is terminal for new work.
        #expect(coordinator.beginLaunch() == .terminated)
        #expect(coordinator.launchState != .active)
        #expect(coordinator.releasedAppKitDelegateCount == 1)
        #expect(coordinator.activeTaskCount == 0)

        try? await Task.sleep(for: .milliseconds(400))
        #expect(probe.sideEffectCount == 0)
    }

    @Test("Termination before any launch keeps the idle launch state")
    @MainActor
    func terminationWithoutLaunchKeepsIdle() async {
        let coordinator = LifecycleCoordinator()

        let cancelled = await coordinator.beginTermination()

        #expect(cancelled == 0)
        #expect(coordinator.phase == .terminated)
        #expect(coordinator.launchState == .idle,
                "Nothing was interrupted because no launch was in flight")
        #expect(coordinator.isTerminated)
    }

    @Test("A failed launch keeps its failure through termination")
    @MainActor
    func failedLaunchSurvivesTermination() async {
        let coordinator = LifecycleCoordinator()
        _ = coordinator.beginLaunch()
        _ = coordinator.failLaunch(LifecycleCoordinatorTestLaunchError.handshakeTimedOut)

        let cancelled = await coordinator.beginTermination()

        #expect(cancelled == 0)
        #expect(coordinator.phase == .terminated)
        #expect(coordinator.launchState == .failed)
    }

    // MARK: - Delegate accounting and idempotent termination

    @Test("AppKit delegate release is counted and idempotent")
    @MainActor
    func appKitDelegateReleaseIsCountedAndIdempotent() {
        let coordinator = LifecycleCoordinator()
        coordinator.registerAppKitDelegate()
        coordinator.registerAppKitDelegate()
        coordinator.registerAppKitDelegate()
        #expect(coordinator.releasedAppKitDelegateCount == 0,
                "Nothing is released before termination")

        coordinator.releaseAppKitDelegates()
        #expect(coordinator.releasedAppKitDelegateCount == 3)

        coordinator.releaseAppKitDelegates()
        #expect(coordinator.releasedAppKitDelegateCount == 3,
                "A repeated release must not double-count")

        coordinator.registerAppKitDelegate()
        coordinator.releaseAppKitDelegates()
        #expect(coordinator.releasedAppKitDelegateCount == 4)
    }

    @Test("Terminating twice is safe and never double-counts")
    @MainActor
    func terminatingTwiceIsSafe() async {
        let coordinator = LifecycleCoordinator()
        let probe = LifecycleCoordinatorTestProbe()
        let gate = LifecycleCoordinatorTestGate()
        let task = gate.makeTask(probe: probe, sideEffect: "never")
        coordinator.register(task)
        await gate.waitUntilParked()
        coordinator.registerAppKitDelegate()

        let first = await coordinator.beginTermination()
        #expect(first == 1)
        #expect(coordinator.phase == .terminated)
        #expect(coordinator.isTerminated)
        #expect(coordinator.releasedAppKitDelegateCount == 1)

        let second = await coordinator.beginTermination()
        #expect(second == 0, "A repeated termination has nothing left to cancel")
        #expect(coordinator.phase == .terminated)
        #expect(coordinator.isTerminated)
        #expect(coordinator.releasedAppKitDelegateCount == 1,
                "Delegates must not be released twice")
        #expect(coordinator.activeTaskCount == 0)

        let third = await coordinator.beginTermination()
        #expect(third == 0)
        #expect(coordinator.releasedAppKitDelegateCount == 1)

        try? await Task.sleep(for: .milliseconds(400))
        #expect(probe.sideEffectCount == 0)
    }

    @Test("Registering work after termination is refused and cancelled immediately")
    @MainActor
    func registerAfterTerminationIsRefused() async throws {
        let coordinator = LifecycleCoordinator()
        _ = await coordinator.beginTermination()
        #expect(coordinator.isTerminated)

        let probe = LifecycleCoordinatorTestProbe()
        let gate = LifecycleCoordinatorTestGate()
        let late = gate.makeTask(probe: probe, sideEffect: "late-work")
        coordinator.register(late)

        // `register` cancels the task instead of adopting it, so the task never parks: it
        // takes its cancellation branch and finishes, which is what makes the assertions
        // below independent of scheduling.
        try #require(late.isCancelled, "Stop new work: a task handed over after termination must not run")
        await late.value
        #expect(coordinator.activeTaskCount == 0)
        #expect(coordinator.phase == .terminated)

        try? await Task.sleep(for: .milliseconds(400))
        #expect(probe.sideEffectCount == 0)
        #expect(probe.cancellationObservedCount == 1)
    }

    @Test("Registering an AppKit delegate after termination is not claimed or released")
    @MainActor
    func delegateRegistrationAfterTerminationIsRefused() async {
        let coordinator = LifecycleCoordinator()
        coordinator.registerAppKitDelegate()

        let first = await coordinator.beginTermination()
        #expect(first == 0)
        #expect(coordinator.releasedAppKitDelegateCount == 1)

        coordinator.registerAppKitDelegate()
        coordinator.releaseAppKitDelegates()
        #expect(coordinator.releasedAppKitDelegateCount == 1,
                "Termination already released everything it owned; nothing new may be claimed")
    }

    // MARK: - Structural boundary

    @Test("The coordinator source runs no I/O, touches no network, and holds no AppKit object")
    func sourceKeepsTheLifecycleBoundary() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent("Sources/MonospaceNotes/Platform/LifecycleCoordinator.swift")
        let source = String(decoding: try Data(contentsOf: url), as: UTF8.self)

        #expect(source.contains("@MainActor"))
        #expect(source.contains("final class LifecycleCoordinator"))
        #expect(source.contains("enum Phase: String, Sendable, Equatable"))

        let forbiddenTokens = [
            "URLSession",
            "import Network",
            "NSURLConnection",
            "CFNetwork",
            "import AppKit",
            "FileManager",
            "UserDefaults",
            "Data(contentsOf:",
            "write(to:",
        ]
        for token in forbiddenTokens {
            #expect(!source.contains(token),
                    "LifecycleCoordinator.swift must not contain \(token)")
        }
    }
}
