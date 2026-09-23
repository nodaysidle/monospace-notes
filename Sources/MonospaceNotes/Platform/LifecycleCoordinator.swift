//
//  LifecycleCoordinator.swift
//  MonospaceNotes
//
//  TASK-03-LIFECYCLE-COORDINATOR — owner OWN-LIFECYCLE-COORDINATOR.
//
//  The owner-level coordinator for the application lifecycle contracts:
//
//    * CON-LIFECYCLE-APPLICATION-LAUNCH — preset-owned state and services are
//      initialized without starting privileged capture, remote requests, or
//      destructive work automatically. A launch attempt is explicit and observable,
//      a failure rolls the partial initialization of that attempt back, and an
//      interrupted transition is never reported as complete.
//    * CON-LIFECYCLE-APPLICATION-TERMINATION — new work is stopped, every
//      registered task is cancelled *and awaited*, and every accounted AppKit
//      delegate is released before termination completes.
//    * CON-LIFECYCLE-PRESET — the WindowGroup (Dock-first) entry lives in
//      MonospaceNotesApp.swift; this coordinator is the owner that cancels tasks
//      and releases AppKit delegates when the application terminates, and it models
//      restoration for product-owned state only: nothing here is persisted and
//      nothing here is read back from disk.
//
//  Phase state machine
//  -------------------
//      idle ──beginLaunch──▶ launching ──completeLaunch──▶ ready
//                                │  │
//                                │  └──failLaunch───────▶ failed ──beginLaunch──▶ launching
//                                │
//      idle|launching|ready|failed ────beginTermination──▶ terminating ──▶ terminated
//
//    * `completeLaunch()` only ever moves `launching` to `ready`. From any other
//      phase it reports the current phase and changes nothing, so a transition that
//      was interrupted by a failure or by termination can never be published as a
//      completed one.
//    * `terminating` and `terminated` are terminal for new work: `beginLaunch()`
//      refuses to start a launch, `register(_:)` cancels the task it is handed
//      instead of adopting it, and `registerAppKitDelegate()` is refused.
//    * Termination is idempotent and repeat-safe: repeating it returns 0, releases
//      nothing a second time, and leaves the coordinator in `terminated`.
//
//  Invariants honoured here
//  -----------------------
//    * No network APIs and no third-party dependencies.
//    * No file I/O at all, on any actor: this coordinator touches no file, no
//      defaults suite, and no AppKit object. AppKit delegates are accounted for by
//      count so that their release is provable without the coordinator holding a
//      delegate it cannot release.
//    * No work is started automatically. Construction starts nothing, and the only
//      tasks this coordinator knows about are the ones its owner registers.
//    * Reporting values never carry note contents, buffers, or file paths. The alert
//      a failed launch returns carries the reason its owner supplied, and nothing
//      else: `AppStateError` descriptions are content-free by construction.
//

import Foundation

@MainActor
final class LifecycleCoordinator {

    // MARK: - Phase

    /// The lifecycle phase. Raw values are stable so diagnostics and tests can name
    /// a phase without depending on case order.
    enum Phase: String, Sendable, Equatable {
        case idle
        case launching
        case ready
        case failed
        case terminating
        case terminated
    }

    // MARK: - Locked surface

    /// Current lifecycle phase. Starts `idle`: nothing is initialized and nothing
    /// is running.
    private(set) var phase: Phase = .idle

    /// The launch operation in the shared `OperationState` vocabulary: `idle` before
    /// the first attempt, `active` while launching, `succeeded` only after a launch
    /// completed, `failed` after a rolled-back attempt, and `cancelled` when
    /// termination interrupted a launch that was still in flight.
    private(set) var launchState: OperationState = .idle

    /// Number of AppKit delegates released so far. Cumulative and monotonic: a
    /// delegate is counted once, on the release that actually lets it go.
    private(set) var releasedAppKitDelegateCount: Int = 0

    /// Registered work that has not finished yet. Work that completed on its own is
    /// no longer active and is therefore not counted.
    var activeTaskCount: Int {
        var count = 0
        for registration in registrations where !registration.isFinished {
            count += 1
        }
        return count
    }

    /// `true` once termination completed: every registered task has finished.
    var isTerminated: Bool { phase == .terminated }

    init() {}

    // MARK: - Launch

    /// Begins a launch attempt.
    ///
    /// `idle` and `failed` may start a launch — the second is the documented safe
    /// retry path. A launch already in flight stays in `launching` rather than
    /// restarting, a launch that already completed is never re-opened, and
    /// termination is terminal so no new work starts after it began. Every refused
    /// call reports the current phase and changes nothing.
    @discardableResult
    func beginLaunch() -> Phase {
        guard acceptsNewWork else { return phase }
        guard phase == .idle || phase == .failed else { return phase }

        phase = .launching
        launchState = .active
        // A new attempt tracks its own partial initialization, so nothing from an
        // earlier attempt may be rolled back twice.
        launchScopedRegistrationIDs.removeAll()
        launchScopedAppKitDelegates = 0
        return phase
    }

    /// Completes the launch attempt that is in flight and reports the resulting
    /// phase. Only `launching` becomes `ready`; from `idle`, `failed`, `terminating`
    /// or `terminated` the current phase is reported and nothing changes.
    @discardableResult
    func completeLaunch() -> Phase {
        guard phase == .launching else { return phase }

        phase = .ready
        launchState = .succeeded
        // The attempt succeeded: what it registered is now owned by the running app
        // and must not be rolled back by a later failure report.
        launchScopedRegistrationIDs.removeAll()
        launchScopedAppKitDelegates = 0
        return phase
    }

    /// Records a failed launch, rolls the partial initialization of that attempt
    /// back, and returns the alert the application presents. The title is the locked
    /// user-facing string for a launch failure.
    ///
    /// A failure is recorded unless the launch already completed (`ready` keeps its
    /// phase and its `succeeded` launch state: a completed transition is not
    /// un-completed by a later report) or the coordinator is terminating/terminated
    /// (termination keeps the last safe state active). In those cases the alert is
    /// still returned, because the caller's failure must not be swallowed.
    @discardableResult
    func failLaunch(_ error: Error) -> ErrorAlert {
        if acceptsNewWork, phase != .ready {
            phase = .failed
            launchState = .failed
        }

        // Rollback (CON-LIFECYCLE-APPLICATION-LAUNCH cleanup): cancel the work this
        // attempt registered and release the delegates it registered, so a retry or a
        // manual launch starts from a clean state. Resources owned before the attempt
        // are left untouched.
        rollbackLaunchAttempt()

        return ErrorAlert(
            title: "Could Not Launch",
            message: Self.launchFailureMessage(for: error)
        )
    }

    // MARK: - Registered work

    /// Adopts `task` as cancellable work that termination must cancel and await.
    ///
    /// Terminating and terminated are terminal for new work: a task handed over after
    /// termination began is cancelled immediately instead of being adopted, so
    /// nothing registered here can still be running once termination reported
    /// completion.
    func register(_ task: Task<Void, Never>) {
        guard acceptsNewWork else {
            task.cancel()
            return
        }

        let identifier = UUID()
        registrations.append(Registration(id: identifier, task: task, isFinished: false))
        if phase == .launching {
            launchScopedRegistrationIDs.insert(identifier)
        }

        // Watch the registration so `activeTaskCount` reports running work only. The
        // watch completes as soon as the task does, and termination awaits it
        // together with the task it watches.
        let watch = Task { [weak self] in
            await task.value
            self?.markFinished(identifier)
        }
        completionWatches.append(watch)
    }

    // MARK: - AppKit delegate accounting

    /// Records that the application registered an AppKit delegate that this
    /// coordinator must release during termination.
    ///
    /// Registration after termination began is refused and not counted: termination
    /// already released everything it owned, and no new work may start.
    func registerAppKitDelegate() {
        guard acceptsNewWork else { return }

        trackedAppKitDelegates += 1
        if phase == .launching {
            launchScopedAppKitDelegates += 1
        }
    }

    /// Releases every accounted delegate and adds it to the released count. Safe to
    /// repeat: a second call has nothing left to release and never double-counts.
    func releaseAppKitDelegates() {
        releasedAppKitDelegateCount += trackedAppKitDelegates
        trackedAppKitDelegates = 0
        launchScopedAppKitDelegates = 0
    }

    // MARK: - Termination

    /// Stops new work, cancels and awaits every registered task, releases the
    /// accounted AppKit delegates, and moves the coordinator to `terminated`.
    ///
    /// Returns the number of registered tasks this call cancelled: tasks that had not
    /// finished and had not already been cancelled. Repeating the call is safe, has
    /// nothing left to cancel or release, and returns 0.
    func beginTermination() async -> Int {
        if phase == .terminated { return 0 }
        if let inFlight = terminationTask {
            // A concurrent caller joins the termination in progress instead of
            // cancelling or releasing anything twice.
            _ = await inFlight.value
            return 0
        }

        let termination = Task { [weak self] in
            guard let self else { return 0 }
            return await self.performTermination()
        }
        terminationTask = termination
        return await termination.value
    }

    // MARK: - Private state

    /// One adopted task plus whether its completion has already been observed.
    private struct Registration {
        let id: UUID
        let task: Task<Void, Never>
        var isFinished: Bool
    }

    private var registrations: [Registration] = []
    private var completionWatches: [Task<Void, Never>] = []
    private var terminationTask: Task<Int, Never>?
    private var trackedAppKitDelegates = 0
    /// Registrations made during the current launch attempt: exactly these are the
    /// attempt's partial initialization.
    private var launchScopedRegistrationIDs: Set<UUID> = []
    private var launchScopedAppKitDelegates = 0

    // MARK: - Private behaviour

    /// `terminating` and `terminated` accept no new work.
    private var acceptsNewWork: Bool {
        phase != .terminating && phase != .terminated
    }

    /// The single termination body. Runs once per coordinator because
    /// `beginTermination()` stores and awaits its task.
    private func performTermination() async -> Int {
        phase = .terminating

        // A launch that was still in flight is cancelled, not completed: an
        // interrupted transition must never be reported as a success.
        if launchState == .active {
            launchState = .cancelled
        }
        launchScopedRegistrationIDs.removeAll()
        launchScopedAppKitDelegates = 0

        var cancelledCount = 0
        for registration in registrations where !registration.isFinished {
            if !registration.task.isCancelled {
                registration.task.cancel()
                cancelledCount += 1
            }
        }

        // Await every registration, cancelled or not: nothing that was registered may
        // still be running when termination completes.
        for registration in registrations {
            await registration.task.value
        }
        for watch in completionWatches {
            await watch.value
        }

        registrations.removeAll()
        completionWatches.removeAll()
        releaseAppKitDelegates()

        phase = .terminated
        return cancelledCount
    }

    /// Cancels the current launch attempt's work and releases the delegates that
    /// attempt registered. A no-op when the attempt registered nothing, which is what
    /// keeps a repeated `failLaunch` honest.
    private func rollbackLaunchAttempt() {
        let scopedIdentifiers = launchScopedRegistrationIDs
        launchScopedRegistrationIDs.removeAll()

        for registration in registrations where scopedIdentifiers.contains(registration.id) {
            if !registration.task.isCancelled {
                registration.task.cancel()
            }
        }

        if launchScopedAppKitDelegates > 0 {
            releasedAppKitDelegateCount += launchScopedAppKitDelegates
            trackedAppKitDelegates -= launchScopedAppKitDelegates
            launchScopedAppKitDelegates = 0
        }
    }

    /// Marks a registration as finished so it no longer counts as active work.
    private func markFinished(_ identifier: UUID) {
        guard let index = registrations.firstIndex(where: { $0.id == identifier }) else {
            return
        }
        registrations[index].isFinished = true
        launchScopedRegistrationIDs.remove(identifier)
    }

    // MARK: - Private reporting

    /// The content-free reason for a launch failure. `AppStateError` descriptions are
    /// built from operation summaries, so they are preferred; anything else is
    /// described as-is. The coordinator adds no path, buffer, or note content.
    private static func launchFailureReason(for error: Error) -> String {
        let reason: String
        if let appStateError = error as? AppStateError {
            reason = appStateError.description
        } else {
            reason = String(describing: error)
        }

        let trimmed = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return trimmed.isEmpty ? "an unknown error" : trimmed
    }

    private static func launchFailureMessage(for error: Error) -> String {
        "The launch transition did not complete: \(launchFailureReason(for: error)). "
            + "Partial initialization was rolled back, so a retry or a manual launch "
            + "starts from a clean state."
    }
}
