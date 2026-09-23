//
//  ColdLaunchUnder100msFeature.swift
//  MonospaceNotes
//
//  TASK-04-COLD-LAUNCH-UNDER-100MS — owner OWN-COLD-LAUNCH-UNDER-100MS.
//
//  Owns the cold-launch transition of FEAT-COLD-LAUNCH-UNDER-100MS:
//
//    * CON-COLD-LAUNCH-UNDER-100MS-INTERFACE — the app initialises its window,
//      its text view and its settings and presents an editable document window.
//      No network call or remote resource load happens during launch. The
//      transition is measured with `ContinuousClock` against `launchBudget`
//      (100 ms) on the machine that runs it.
//    * CON-COLD-LAUNCH-UNDER-100MS-RECOVERY — the launch operation is always one
//      of idle / active / succeeded / failed / cancelled. A failed attempt
//      presents an error alert titled "Could Not Launch" and leaves NO editable
//      window behind; the partial initialisation of every attempt that does not
//      publish an editable window is released, so a relaunch starts from a clean
//      state.
//
//  What is measured
//  ----------------
//  `measureLaunch(_:)` starts its clock immediately before the real
//  initialisation body runs and stops it the instant that body returns the
//  document text view. That instant is "the window is editable" moment the
//  100 ms budget is measured against, and keystroke acceptance is probed at that
//  same instant (ACC-COLD-LAUNCH-UNDER-100MS-01) without being counted in the
//  measured duration. The in-process clock starts where the initialisation
//  starts: the offset from process start to that point is not available inside
//  the process, so it is measured end to end for the built app instead of being
//  invented here (see the TASK-04 report).
//
//  Why a budget miss is not a launch failure
//  -----------------------------------------
//  `evaluate(_:)` reports `.failed` only when no editable window was produced.
//  A launch that produced a working window but missed the budget is a budget
//  miss, reported separately by `meetsBudget(_:)` and `lastLaunchMetBudget`:
//  the contract's failure behaviour ("present an error alert and exit without
//  leaving a partially initialized window") must never be triggered by a
//  window the user can actually type into.
//
//  Invariants honoured here
//  ------------------------
//    * No network APIs, no third-party dependencies, and no remote resource
//      loads. The launch path reaches persisted state only through the injected
//      `SettingsStoring` seam (typography and keybindings — the only persisted
//      values), so no request of any kind is issued during launch.
//    * No file I/O here: this file never touches the filesystem, a stream, or a
//      handle, and it performs no I/O on any thread.
//    * Reporting values never carry note contents, buffers, or file paths.
//    * Cleanup runs on every terminal path that does not publish a window, and
//      the keystroke probe leaves the document exactly as it found it.
//

import AppKit
import Foundation

@MainActor
final class ColdLaunchUnder100msFeature {

    // MARK: - Locked surface

    /// The locked cold-launch budget, measured with `ContinuousClock`.
    static let launchBudget: Duration = .milliseconds(100)

    /// The same budget as a number so a real measured millisecond value can be
    /// compared against it directly.
    static let launchBudgetMilliseconds: Double = 100

    /// The locked user-facing alert title for a failed launch (TRD.md "Exact
    /// user-facing strings": `Could Not Launch`).
    static let failureAlertTitle: String = "Could Not Launch"

    /// One measured cold-launch attempt.
    struct Measurement: Equatable, Sendable {
        /// Time from the start of the initialisation to the first editable
        /// window.
        let duration: Duration
        /// `duration` in milliseconds — the number reported and compared against
        /// `launchBudgetMilliseconds`.
        let milliseconds: Double
        /// `true` only when the attempt produced a window whose text view was
        /// editable and accepted a keystroke at that moment.
        let editable: Bool
    }

    // MARK: - Injected services

    /// The launch settings read (typography and keybindings). Nothing else is
    /// hydrated at launch, and nothing else is persisted by this feature.
    private let settings: any SettingsStoring

    // MARK: - Launch state (idle / active / succeeded / failed / cancelled)

    /// The launch operation state. Starts `.idle`: nothing has been initialised.
    private(set) var launchState: OperationState = .idle

    /// `true` only while an editable document window is published: it stays
    /// `false` before the first launch, after a failed launch, and after a
    /// cancelled launch.
    private(set) var isEditable: Bool = false

    /// The alert the application presents for a failed launch; `nil` while no
    /// launch failure has occurred (an explicit retry clears it).
    private(set) var errorAlert: ErrorAlert?

    /// The most recent measurement, whatever its outcome.
    private(set) var lastMeasurement: Measurement?

    /// Whether the most recent *editable* launch met the 100 ms budget; `nil`
    /// until an editable window has been measured. Reported separately from
    /// `launchState` because a budget miss is not a launch failure.
    private(set) var lastLaunchMetBudget: Bool?

    /// The editable document text view of the published first window. `nil`
    /// before the first launch and after every attempt that did not publish an
    /// editable window — no partially initialized window is ever retained.
    private(set) var documentView: NSTextView?

    /// How many registered partial-initialisation resources have been released.
    private(set) var releasedResourceCount: Int = 0

    /// Resources created by the attempt in flight that must be released if that
    /// attempt does not publish an editable window.
    private var pendingResourceReleases: [@MainActor () -> Void] = []

    /// - Parameter settings: the settings store the launch read uses. The
    ///   default is the real store, so a launch in the composition root reads the
    ///   user's persisted typography and keybindings.
    init(settings: any SettingsStoring = DataStore()) {
        self.settings = settings
    }

    // MARK: - The measured launch transition

    /// Runs one cold-launch attempt under `ContinuousClock` and publishes its
    /// outcome.
    ///
    /// `body` is the real initialisation path: it returns the document text view
    /// that must be editable when the first window is presented, or throws when
    /// the initialisation fails. The clock starts immediately before `body` runs
    /// and stops the instant it returns; keystroke acceptance is probed at that
    /// instant, after the clock has stopped.
    ///
    /// Outcome handling, in the vocabulary of the recovery contract:
    /// * the attempt is `.active` while `body` runs;
    /// * an editable window that accepts a keystroke publishes `.succeeded` and
    ///   `isEditable == true`;
    /// * anything else — a thrown error, `nil`, or a text view that is not
    ///   editable — publishes `.failed`, keeps `isEditable == false`, and
    ///   presents `failureAlert(for:)`;
    /// * an attempt interrupted by `cancel()` publishes `.cancelled` and is never
    ///   reported as a success.
    ///
    /// Every path that does not publish a window releases the attempt's partial
    /// initialisation, so the next launch starts from a clean state.
    ///
    /// `start` is when the launch began; by default the clock starts immediately
    /// before `body` runs.
    @discardableResult
    func measureLaunch(
        since start: ContinuousClock.Instant? = nil,
        _ body: () throws -> NSTextView?
    ) -> Measurement {
        launchState = .active
        errorAlert = nil

        let clock = ContinuousClock()
        let start = start ?? clock.now

        let candidate: NSTextView?
        let failure: Error?
        do {
            candidate = try body()
            failure = nil
        } catch {
            candidate = nil
            failure = error
        }

        // The instant the initialisation body returned is the "first editable
        // window" moment the budget is measured against.
        let duration = start.duration(to: clock.now)
        let milliseconds = Self.milliseconds(of: duration)
        let probeAccepted = candidate.map(Self.acceptsKeystrokes) ?? false

        // An attempt interrupted while it was in flight is never published as a
        // success (the recovery contract keeps cancellation as a terminal state of
        // its own), so its measurement reports `editable == false` even when the
        // surface it had already built happened to be editable.
        let cancelled = launchState == .cancelled
        let editable = probeAccepted && !cancelled

        let measurement = Measurement(
            duration: duration,
            milliseconds: milliseconds,
            editable: editable
        )
        lastMeasurement = measurement

        if cancelled {
            documentView = nil
            isEditable = false
            errorAlert = nil
            lastLaunchMetBudget = nil
            releasePartialInitialization()
            return measurement
        }

        if editable, let window = candidate {
            documentView = window
            isEditable = true
            lastLaunchMetBudget = Self.meetsBudget(measurement)
            // The attempt's resources are owned by the published window now.
            pendingResourceReleases.removeAll()
            launchState = evaluate(measurement)
            return measurement
        }

        // Failure branch: no editable window is published, so the partial
        // initialisation of this attempt is released and the failure is reported
        // with the locked alert.
        documentView = nil
        isEditable = false
        lastLaunchMetBudget = nil
        launchState = evaluate(measurement)
        errorAlert = failureAlert(
            for: failure ?? AppStateError.initializationFailed(
                "the editable document window was not created"
            )
        )
        releasePartialInitialization()
        return measurement
    }

    /// Runs the real cold-launch path under measurement.
    ///
    /// This is the path the composition root calls once at launch: the launch
    /// settings read, the editable document text view, and the measured
    /// transition to the first editable window.
    @discardableResult
    func launch() -> Measurement {
        measureLaunch { try initializeLaunchSurface() }
    }

    /// Completes the cold launch against the app's own document text view: the clock
    /// runs from `start` (when the composition root began initialising) to the moment
    /// the window's real document surface exists, so no throwaway surface is built
    /// and nothing is initialised twice. Call it before the surface's delegate is
    /// attached, so the keystroke probe never reaches the document buffer.
    @discardableResult
    func launch(adopting textView: NSTextView, since start: ContinuousClock.Instant) -> Measurement {
        let measurement = measureLaunch(since: start) {
            guard textView.isEditable, textView.textLayoutManager != nil else {
                throw AppStateError.initializationFailed(
                    "the editable document text view could not be created"
                )
            }
            return textView
        }
        textView.undoManager?.removeAllActions(withTarget: textView)
        return measurement
    }

    /// The real, `AppState`-free cold-launch initialisation path.
    ///
    /// Inputs are the persisted launch settings (typography and keybindings, the
    /// only persisted values) read through `SettingsStoring`; the output is the
    /// editable document text view of the first window. Throws
    /// `AppStateError.initializationFailed` when the editable surface cannot be
    /// built, and carries no note content, buffer, or path in that failure.
    func initializeLaunchSurface() throws -> NSTextView {
        let typography = settings.loadTypography()
        _ = settings.loadKeybindings()

        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Self.documentFont(for: typography)
        textView.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        textView.string = ""

        guard textView.isEditable, textView.textLayoutManager != nil else {
            throw AppStateError.initializationFailed(
                "the editable document text view could not be created"
            )
        }

        return textView
    }

    // MARK: - Evaluation and reporting

    /// The operation state of a measured launch: `.succeeded` when the attempt
    /// produced an editable window that accepted a keystroke, `.failed` when it
    /// did not. The 100 ms budget is reported separately by `meetsBudget(_:)`
    /// and `lastLaunchMetBudget`, so a working window that took longer than the
    /// budget is never reported as a failed initialisation.
    func evaluate(_ measurement: Measurement) -> OperationState {
        measurement.editable ? .succeeded : .failed
    }

    /// Whether a measured launch met the locked 100 ms budget. A measurement that
    /// published no editable window never met it, whatever its duration.
    static func meetsBudget(_ measurement: Measurement) -> Bool {
        measurement.editable && measurement.milliseconds < launchBudgetMilliseconds
    }

    /// The alert the application presents when a launch attempt fails. The title
    /// is the locked user-facing string; the message carries the content-free
    /// reason only, so no note content, buffer, or file path can reach a dialog.
    func failureAlert(for error: Error) -> ErrorAlert {
        ErrorAlert(
            title: Self.failureAlertTitle,
            message: Self.failureMessage(for: error)
        )
    }

    // MARK: - Keystroke acceptance at the editable moment

    /// Proves that `textView` accepts keystrokes *now*: the character is inserted
    /// through the text-input entry point AppKit uses for a typed character, the
    /// buffer change is observed, and the probe character is removed again so the
    /// document is left exactly as it was found. A non-editable text view refuses
    /// the insertion and reports `false`.
    static func acceptsKeystrokes(_ textView: NSTextView) -> Bool {
        guard textView.isEditable, textView.isSelectable else { return false }

        let before = textView.string
        let insertionPoint = (before as NSString).length

        textView.insertText(
            keystrokeProbe,
            replacementRange: NSRange(location: insertionPoint, length: 0)
        )
        let accepted = textView.string == before + keystrokeProbe

        if accepted {
            // Remove exactly the probe character so the last valid state is kept.
            textView.insertText(
                "",
                replacementRange: NSRange(
                    location: insertionPoint,
                    length: (keystrokeProbe as NSString).length
                )
            )
            if textView.string != before {
                // A text view that refused the removal still must not keep the
                // probe: restore the content it had at the editable moment.
                textView.string = before
            }
        }

        return accepted
    }

    // MARK: - Partial-initialisation cleanup

    /// Registers a resource created by the current attempt that must be released
    /// when that attempt ends without publishing an editable window (a failure or
    /// a cancellation). A registered release runs at most once per attempt.
    func registerLaunchResource(_ release: @escaping @MainActor () -> Void) {
        pendingResourceReleases.append(release)
    }

    /// Releases the partial initialisation of the attempt in flight. Idempotent:
    /// once released, an attempt releases nothing a second time, so a retry after
    /// a failure starts from a clean state.
    func releasePartialInitialization() {
        let releases = pendingResourceReleases
        pendingResourceReleases.removeAll()
        guard !releases.isEmpty else { return }

        for release in releases {
            release()
        }
        releasedResourceCount += releases.count
    }

    // MARK: - Cancellation

    /// Interrupts an attempt that is still in flight, e.g. because the
    /// application is terminating while the launch is running.
    ///
    /// Nothing about the attempt is published as a success: it becomes
    /// `.cancelled`, no editable window remains, its partial initialisation is
    /// released, and — because a cancellation is not an error — no alert is
    /// produced. Returns whether an in-flight attempt was actually interrupted.
    @discardableResult
    func cancel() -> Bool {
        guard launchState == .active else { return false }
        launchState = .cancelled
        return true
    }

    // MARK: - Private

    /// A single character inserted and removed again by the keystroke probe.
    private static let keystrokeProbe = "x"

    /// The number of milliseconds a `Duration` spans.
    static func milliseconds(of duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// The launch font: the configured monospace family and point size, falling
    /// back to the system monospace face when that family is unavailable.
    private static func documentFont(for typography: TypographySettings) -> NSFont {
        NSFont(name: typography.fontFamily, size: typography.pointSize)
            ?? NSFont.monospacedSystemFont(ofSize: typography.pointSize, weight: .regular)
    }

    /// The content-free reason for a launch failure. `AppStateError` descriptions
    /// are built from operation summaries, so they are preferred; anything else is
    /// described as-is. This feature adds no path, buffer, or note content.
    private static func failureMessage(for error: Error) -> String {
        let reason: String
        if let appStateError = error as? AppStateError {
            reason = appStateError.description
        } else {
            reason = String(describing: error)
        }

        let trimmed = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        let detail = trimmed.isEmpty ? "an unknown error" : trimmed

        return "The cold launch did not reach an editable window: \(detail). "
            + "Partial initialization was released, so no partially initialized "
            + "window remains and a relaunch starts from a clean state."
    }
}
