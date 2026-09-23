//
//  ColdLaunchUnder100msFeatureTests.swift
//  MonospaceNotesTests
//
//  TASK-04-COLD-LAUNCH-UNDER-100MS focused suite — owner OWN-COLD-LAUNCH-UNDER-100MS.
//
//  Covers FEAT-COLD-LAUNCH-UNDER-100MS and its two contracts against the real
//  `ColdLaunchUnder100msFeature`:
//
//    * ACC-COLD-LAUNCH-UNDER-100MS-01 — at the moment the window is editable the
//      text view accepts keystrokes, asserted against a real `NSTextView`
//      (a character is inserted through the text-input entry point and the
//      string change is observed).
//    * ACC-COLD-LAUNCH-UNDER-100MS-02 — a failed initialization presents an
//      error alert titled "Could Not Launch" and leaves NO editable window
//      (`isEditable` stays false, nothing is retained, the partial
//      initialization is released).
//    * ACC-COLD-LAUNCH-UNDER-100MS-03 — the real initialization path to the
//      first editable window is measured with `ContinuousClock` on this machine
//      and asserted against the 100 ms budget constant. The real number is
//      printed by the suite, and a separate test proves the clock reports real
//      elapsed time instead of a constant.
//    * ACC-COLD-LAUNCH-UNDER-100MS-04 — no network request can be issued during
//      launch, proved STRUCTURALLY by scanning every `.swift` file under
//      `Sources/MonospaceNotes` for forbidden network tokens. This is a
//      structural proof over source text, not an observation of the network
//      stack; the report states that limitation.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import AppKit
import Foundation
import Testing

@testable import MonospaceNotes

// MARK: - File-scope fixtures (unique names: every test file compiles together)

/// A `SettingsStoring` stand-in that returns fixed launch settings and counts
/// the reads, so "the launch path really read the persisted settings" is
/// observable without touching the user's real defaults domain.
private final class ColdLaunchFakeSettingsStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let typography: TypographySettings
    private let keybindings: KeybindingSettings
    private var typographyLoads = 0
    private var keybindingsLoads = 0
    private var storedTypography: [TypographySettings] = []
    private var storedKeybindings: [KeybindingSettings] = []

    init(typography: TypographySettings = .default,
         keybindings: KeybindingSettings = .default) {
        self.typography = typography
        self.keybindings = keybindings
    }

    func loadTypography() -> TypographySettings {
        lock.lock()
        defer { lock.unlock() }
        typographyLoads += 1
        return typography
    }

    func storeTypography(_ settings: TypographySettings) throws {
        lock.lock()
        defer { lock.unlock() }
        storedTypography.append(settings)
    }

    func loadKeybindings() -> KeybindingSettings {
        lock.lock()
        defer { lock.unlock() }
        keybindingsLoads += 1
        return keybindings
    }

    func storeKeybindings(_ settings: KeybindingSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        storedKeybindings.append(settings)
    }

    var typographyLoadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return typographyLoads
    }

    var keybindingsLoadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return keybindingsLoads
    }

    var storedTypographyCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedTypography.count
    }

    var storedKeybindingsCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedKeybindings.count
    }
}

/// Counts how many times a registered partial-initialization resource was
/// actually released.
private final class ColdLaunchResourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var releases = 0

    func noteRelease() {
        lock.lock()
        defer { lock.unlock() }
        releases += 1
    }

    var releasedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return releases
    }
}

/// A real, editable TextKit 2 text view used as the initialization surface of
/// tests that do not need the production launch surface.
@MainActor
private func coldLaunchTextView(editable: Bool = true, text: String = "") -> NSTextView {
    _ = NSApplication.shared
    let textView = NSTextView(usingTextLayoutManager: true)
    textView.isEditable = editable
    textView.isSelectable = true
    textView.isRichText = false
    textView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
    textView.string = text
    return textView
}

/// The feature under test, with AppKit initialised the way a launched app has it.
@MainActor
private func coldLaunchFeature(
    settings: any SettingsStoring = ColdLaunchFakeSettingsStore()
) -> ColdLaunchUnder100msFeature {
    _ = NSApplication.shared
    return ColdLaunchUnder100msFeature(settings: settings)
}

/// A unique `UserDefaults` suite so the real-store launch test never reads or
/// writes the user's actual defaults domain.
private func coldLaunchTestDefaultsSuite() -> (defaults: UserDefaults, name: String) {
    let name = "com.monospace.notes.coldlaunch.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
        fatalError("could not create a dedicated UserDefaults suite for the test")
    }
    return (defaults, name)
}

/// A launch failure that is not one of the app's own error types, so the alert
/// path for an unknown error is exercised too.
private struct ColdLaunchTestUnknownFailure: Error {}

// MARK: - Suite 1: the measured launch transition

@Suite("FEAT-COLD-LAUNCH-UNDER-100MS cold launch")
@MainActor
struct ColdLaunchUnder100msFeatureTests {

    // MARK: Constants

    @Test("The locked budget is 100 ms in both representations")
    func budgetConstantsAreLocked() {
        #expect(ColdLaunchUnder100msFeature.launchBudget == .milliseconds(100))
        #expect(ColdLaunchUnder100msFeature.launchBudgetMilliseconds == 100)
        #expect(ColdLaunchUnder100msFeature.failureAlertTitle == "Could Not Launch")
    }

    // MARK: ACC-COLD-LAUNCH-UNDER-100MS-01

    @Test("ACC-COLD-LAUNCH-UNDER-100MS-01: at the editable moment the text view accepts keystrokes")
    func editableWindowAcceptsKeystrokes() throws {
        let feature = coldLaunchFeature()

        let measurement = feature.launch()

        // The launch published an editable window, and the probe taken at the
        // measured instant proved that window accepted a keystroke.
        #expect(measurement.editable)
        #expect(feature.launchState == .succeeded)
        #expect(feature.isEditable)

        let window = try #require(feature.documentView, "the launch published no document text view")
        #expect(window.isEditable)
        #expect(window.textLayoutManager != nil, "the launch surface is a TextKit 2 text view")

        // The probe restored the document exactly: the acceptance check leaves no
        // residue at the editable moment.
        #expect(window.string.isEmpty)

        // A keystroke entered at the editable window itself reaches the buffer.
        window.insertText("n", replacementRange: NSRange(location: 0, length: 0))
        #expect(window.string == "n")
        window.insertText("ote", replacementRange: NSRange(location: 1, length: 0))
        #expect(window.string == "note")
    }

    @Test("A non-editable text view refuses the keystroke probe")
    func nonEditableViewRefusesKeystrokes() {
        let readOnly = coldLaunchTextView(editable: false, text: "existing")
        #expect(ColdLaunchUnder100msFeature.acceptsKeystrokes(readOnly) == false)
        #expect(readOnly.string == "existing", "a refused probe must not touch the buffer")

        let editable = coldLaunchTextView(editable: true, text: "existing")
        #expect(ColdLaunchUnder100msFeature.acceptsKeystrokes(editable))
        #expect(editable.string == "existing", "the probe always restores the buffer")
    }

    // MARK: ACC-COLD-LAUNCH-UNDER-100MS-02

    @Test("ACC-COLD-LAUNCH-UNDER-100MS-02: a failed initialization presents 'Could Not Launch' and leaves no editable window")
    func failedInitializationPresentsCouldNotLaunchAlert() throws {
        let feature = coldLaunchFeature()
        let probe = ColdLaunchResourceProbe()
        feature.registerLaunchResource { probe.noteRelease() }

        let failure = AppStateError.initializationFailed("the document surface could not be created")
        var stateWhileLaunching: OperationState?

        let measurement = feature.measureLaunch {
            // The attempt builds part of its surface and then fails before any
            // editable window can be published.
            stateWhileLaunching = feature.launchState
            _ = coldLaunchTextView()
            throw failure
        }

        #expect(stateWhileLaunching == .active, "an attempt in flight is active")

        // No editable window remains …
        #expect(measurement.editable == false)
        #expect(feature.launchState == .failed)
        #expect(feature.isEditable == false)
        #expect(feature.documentView == nil, "no partially initialized window is retained")

        // … and the failure is reported with the locked alert.
        let alert = try #require(feature.errorAlert, "a failed initialization presented no alert")
        #expect(alert.title == "Could Not Launch")
        #expect(alert.title == ColdLaunchUnder100msFeature.failureAlertTitle)
        #expect(alert.message.isEmpty == false)
        #expect(alert.message.contains("/") == false, "the alert carries no file path")
        #expect(alert.message.contains("document surface could not be created"))

        // The partial initialization was released so a relaunch starts clean.
        #expect(feature.releasedResourceCount == 1)
        #expect(probe.releasedCount == 1)
        #expect(feature.lastLaunchMetBudget == nil)
        #expect(ColdLaunchUnder100msFeature.meetsBudget(measurement) == false)
    }

    @Test("A text view that is not editable fails the launch and leaves no editable window")
    func nonEditableSurfaceFailsTheLaunch() throws {
        let feature = coldLaunchFeature()

        let measurement = feature.measureLaunch {
            coldLaunchTextView(editable: false, text: "read only")
        }

        #expect(measurement.editable == false)
        #expect(feature.launchState == .failed)
        #expect(feature.isEditable == false)
        #expect(feature.documentView == nil)
        #expect(feature.errorAlert?.title == "Could Not Launch")
    }

    @Test("A failed attempt is retryable and starts from a clean state")
    func retryAfterFailureStartsClean() throws {
        let feature = coldLaunchFeature()
        let probe = ColdLaunchResourceProbe()
        feature.registerLaunchResource { probe.noteRelease() }

        let failed = feature.measureLaunch { throw AppStateError.initializationFailed("no surface") }
        #expect(failed.editable == false)
        #expect(feature.launchState == .failed)
        #expect(probe.releasedCount == 1)

        // The explicit retry succeeds; the released resource is not released twice.
        let retried = feature.measureLaunch { coldLaunchTextView() }
        #expect(retried.editable)
        #expect(feature.launchState == .succeeded)
        #expect(feature.isEditable)
        #expect(feature.errorAlert == nil, "a successful retry clears the launch alert")
        #expect(feature.documentView != nil)
        #expect(probe.releasedCount == 1)
        #expect(feature.releasedResourceCount == 1)
    }

    // MARK: ACC-COLD-LAUNCH-UNDER-100MS-03

    @Test("ACC-COLD-LAUNCH-UNDER-100MS-03: the real initialization path reaches an editable window inside the 100 ms budget")
    func coldLaunchMeasuresUnderBudget() throws {
        let store = ColdLaunchFakeSettingsStore(
            typography: TypographySettings(fontFamily: "Menlo", pointSize: 13)
        )
        let feature = coldLaunchFeature(settings: store)

        let measurement = feature.launch()

        // The reported number is real and compared against the budget constant.
        print("[TASK-04] ACC-03 in-process cold launch to the first editable window: "
              + "\(measurement.milliseconds) ms (budget \(ColdLaunchUnder100msFeature.launchBudgetMilliseconds) ms)")

        #expect(measurement.editable)
        #expect(measurement.milliseconds < ColdLaunchUnder100msFeature.launchBudgetMilliseconds)
        #expect(measurement.duration < ColdLaunchUnder100msFeature.launchBudget)
        #expect(ColdLaunchUnder100msFeature.meetsBudget(measurement))
        #expect(feature.lastLaunchMetBudget == true)
        #expect(ColdLaunchUnder100msFeature.milliseconds(of: measurement.duration) == measurement.milliseconds)

        // The measured path is the real one: it read the persisted launch
        // settings and built the configured surface.
        #expect(store.typographyLoadCount == 1)
        #expect(store.keybindingsLoadCount == 1)
        let window = try #require(feature.documentView)
        #expect(window.isEditable)
        #expect(window.font?.pointSize == 13)
    }

    @Test("Repeated cold-launch measurements on this machine all stay inside the budget")
    func repeatedMeasurementsStayInsideBudget() {
        let feature = coldLaunchFeature()
        var numbers: [Double] = []

        for _ in 0..<5 {
            let measurement = feature.launch()
            #expect(measurement.editable)
            #expect(measurement.milliseconds < ColdLaunchUnder100msFeature.launchBudgetMilliseconds)
            #expect(ColdLaunchUnder100msFeature.meetsBudget(measurement))
            numbers.append(measurement.milliseconds)
        }

        print("[TASK-04] ACC-03 five repeated cold-launch measurements (ms): "
              + numbers.map { String(format: "%.4f", $0) }.joined(separator: ", "))
        #expect(numbers.count == 5)
        #expect(numbers.max() != nil)
    }

    @Test("The measurement reports real elapsed time, not a constant")
    func measurementReflectsRealElapsedTime() {
        let feature = coldLaunchFeature()

        let measurement = feature.measureLaunch {
            Thread.sleep(forTimeInterval: 0.03)
            return coldLaunchTextView()
        }

        #expect(measurement.editable)
        #expect(measurement.milliseconds >= 30, "a 30 ms initialization cannot measure faster than 30 ms")
        #expect(feature.lastMeasurement == measurement)
    }

    @Test("A launch that misses the budget is a budget miss, never a reported launch failure")
    func budgetMissIsNotALaunchFailure() {
        let feature = coldLaunchFeature()

        let measurement = feature.measureLaunch {
            Thread.sleep(forTimeInterval: 0.12)
            return coldLaunchTextView()
        }

        #expect(measurement.editable)
        #expect(measurement.milliseconds >= ColdLaunchUnder100msFeature.launchBudgetMilliseconds)
        #expect(ColdLaunchUnder100msFeature.meetsBudget(measurement) == false)
        #expect(feature.lastLaunchMetBudget == false)
        // The window works, so nothing failed and no alert is presented.
        #expect(feature.launchState == .succeeded)
        #expect(feature.isEditable)
        #expect(feature.errorAlert == nil)
    }

    @Test("evaluate maps an editable window to succeeded and everything else to failed")
    func evaluateMapsMeasurements() {
        let feature = coldLaunchFeature()

        let editableFast = ColdLaunchUnder100msFeature.Measurement(
            duration: .milliseconds(4), milliseconds: 4, editable: true
        )
        let notEditable = ColdLaunchUnder100msFeature.Measurement(
            duration: .milliseconds(4), milliseconds: 4, editable: false
        )
        let editableSlow = ColdLaunchUnder100msFeature.Measurement(
            duration: .milliseconds(101), milliseconds: 101, editable: true
        )

        #expect(feature.evaluate(editableFast) == .succeeded)
        #expect(feature.evaluate(notEditable) == .failed)
        #expect(ColdLaunchUnder100msFeature.meetsBudget(editableFast))
        #expect(ColdLaunchUnder100msFeature.meetsBudget(notEditable) == false)
        #expect(ColdLaunchUnder100msFeature.meetsBudget(editableSlow) == false)
        #expect(feature.evaluate(editableSlow) == .succeeded)
    }

    // MARK: Cancellation

    @Test("Interrupting an in-flight launch publishes cancellation, never success")
    func cancelledAttemptIsNeverPublishedAsSuccess() {
        let feature = coldLaunchFeature()
        let probe = ColdLaunchResourceProbe()
        feature.registerLaunchResource { probe.noteRelease() }
        var cancelledInFlight = false

        let measurement = feature.measureLaunch {
            cancelledInFlight = feature.cancel()
            return coldLaunchTextView()
        }

        #expect(cancelledInFlight, "an attempt in flight must be interruptible")
        #expect(measurement.editable == false, "an interrupted attempt published no editable window")
        #expect(feature.launchState == .cancelled)
        #expect(feature.isEditable == false)
        #expect(feature.documentView == nil)
        #expect(feature.errorAlert == nil, "cancellation is not an error")
        #expect(feature.lastLaunchMetBudget == nil)
        #expect(probe.releasedCount == 1, "the interrupted attempt released its partial initialization")

        // Cancelling outside an attempt is a harmless no-op.
        #expect(feature.cancel() == false)
        #expect(feature.launchState == .cancelled)
    }

    // MARK: The launch read against the real settings store

    @Test("The launch reads the real persisted typography through the real store")
    func launchReadsPersistedTypographyFromTheRealStore() throws {
        let (defaults, suiteName) = coldLaunchTestDefaultsSuite()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        try store.storeTypography(TypographySettings(fontFamily: "Menlo", pointSize: 16))
        #expect(store.loadTypography().pointSize == 16)

        let feature = coldLaunchFeature(settings: store)
        let measurement = feature.launch()

        print("[TASK-04] ACC-03 cold launch through the REAL DataStore store: "
              + "\(measurement.milliseconds) ms (budget \(ColdLaunchUnder100msFeature.launchBudgetMilliseconds) ms)")

        #expect(measurement.editable)
        #expect(feature.isEditable)
        let window = try #require(feature.documentView)
        #expect(window.font?.pointSize == 16, "the launch applied the persisted point size")
        #expect(measurement.milliseconds < ColdLaunchUnder100msFeature.launchBudgetMilliseconds)
        #expect(recorder.mainThreadViolations == 0, "the launch read performed no main-thread file I/O")
    }

    // MARK: Failure reporting

    @Test("The launch-failure alert carries the locked title and no note content or path")
    func failureAlertIsContentFree() {
        let feature = coldLaunchFeature()

        let known = feature.failureAlert(
            for: AppStateError.initializationFailed("the document surface could not be created")
        )
        #expect(known.title == "Could Not Launch")
        #expect(known.message.contains("the document surface could not be created"))
        #expect(known.message.contains("/") == false)

        let blank = feature.failureAlert(for: AppStateError.initializationFailed(""))
        #expect(blank.title == "Could Not Launch")
        #expect(blank.message.isEmpty == false)
        #expect(blank.message.contains("Initialization failed"))
        #expect(blank.message.contains("/") == false)

        let unknown = feature.failureAlert(for: ColdLaunchTestUnknownFailure())
        #expect(unknown.title == "Could Not Launch")
        #expect(unknown.message.contains("ColdLaunchTestUnknownFailure"))
        #expect(unknown.message.contains("/") == false)
    }
}

// MARK: - Suite 2: ACC-04 structural network-freedom proof

/// Source-text tokens that would make a network request reachable.
private let coldLaunchForbiddenNetworkTokens = [
    "import Network",
    "URLSession",
    "NSURLConnection",
    "NSURLRequest",
    "CFNetwork",
]

/// The package root, found from this file's own compile-time path so the scan
/// does not depend on the process working directory.
private func coldLaunchPackageRoot(filePath: String = #filePath) -> URL? {
    var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    for _ in 0..<8 {
        if FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("Package.swift").path
        ) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    return nil
}

@Suite("FEAT-COLD-LAUNCH-UNDER-100MS structural network freedom")
struct ColdLaunchUnder100msNetworkScanTests {

    @Test("ACC-COLD-LAUNCH-UNDER-100MS-04: no network API exists anywhere in the Sources tree")
    func sourcesContainNoNetworkTokens() throws {
        let root = try #require(coldLaunchPackageRoot(), "package root not found")
        let sourcesRoot = root.appendingPathComponent("Sources/MonospaceNotes")
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        let sourcesExist = fileManager.fileExists(atPath: sourcesRoot.path, isDirectory: &isDirectory)
        #expect(sourcesExist)
        #expect(isDirectory.boolValue)

        let enumerator = try #require(
            fileManager.enumerator(at: sourcesRoot, includingPropertiesForKeys: [.isRegularFileKey]),
            "the Sources tree could not be enumerated"
        )
        let swiftFiles = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }

        // The scan must be over the real tree: a vacuous pass would prove nothing.
        #expect(swiftFiles.count >= 6, "expected the whole Sources tree, found \(swiftFiles.count) files")
        let scannedNames = Set(swiftFiles.map(\.lastPathComponent))
        #expect(scannedNames.contains("MonospaceNotesApp.swift"))
        #expect(scannedNames.contains("AppState.swift"))
        #expect(scannedNames.contains("ColdLaunchUnder100msFeature.swift"))
        #expect(scannedNames.contains("DataStore.swift"))

        var totalBytes = 0
        var forbiddenMatches: [String] = []
        for file in swiftFiles {
            let text = try String(contentsOf: file, encoding: .utf8)
            totalBytes += text.utf8.count
            for token in coldLaunchForbiddenNetworkTokens where text.contains(token) {
                forbiddenMatches.append("\(file.lastPathComponent): \(token)")
            }
        }

        #expect(totalBytes > 5_000, "the scan read implausibly little source text")
        #expect(
            forbiddenMatches.isEmpty,
            "network tokens found in Sources/MonospaceNotes: \(forbiddenMatches)"
        )
    }

    @Test("The launch path itself reaches only the injected settings seam")
    func launchPathTouchesOnlyTheSettingsSeam() throws {
        let root = try #require(coldLaunchPackageRoot())
        let featureSource = root.appendingPathComponent(
            "Sources/MonospaceNotes/Features/ColdLaunchUnder100msFeature.swift"
        )
        let text = try String(contentsOf: featureSource, encoding: .utf8)

        #expect(text.contains("import AppKit"))
        #expect(text.contains("import Foundation"))
        #expect(text.contains("import Network") == false)
        #expect(text.contains("URLSession") == false)
        #expect(text.contains("SettingsStoring"))
        // No file I/O API is reachable from the launch path.
        #expect(text.contains("FileManager") == false)
        #expect(text.contains("Data(contentsOf:") == false)
        #expect(text.contains("write(to:") == false)
        #expect(text.contains("FileHandle") == false)
    }
}

// MARK: - The composition root's launch

@Suite("FEAT-COLD-LAUNCH-UNDER-100MS launch through the app's own document surface")
@MainActor
struct ColdLaunchCompositionRootTests {

    @Test("The launch is in flight until the window's document surface exists, then succeeds on it")
    func launchCompletesOnTheRealDocumentSurface() {
        _ = NSApplication.shared
        let state = AppState(settings: ColdLaunchFakeSettingsStore())
        #expect(state.launchState == .active, "no surface yet, so the launch has not finished")
        #expect(state.coldLaunch.documentView == nil, "no throwaway surface is built at init")

        let surface = TextKit2DocumentView(state: state)
        let textView = TextKit2DocumentView.makeDocumentTextView(
            text: surface.text,
            font: surface.font,
            textColor: surface.textColor,
            backgroundColor: surface.backgroundColor,
            isEditable: surface.isEditable
        )
        state.completeLaunch(with: textView)

        #expect(state.launchState == .succeeded)
        #expect(state.isEditable)
        #expect(state.errorAlert == nil)
        #expect(state.coldLaunch.documentView === textView, "the launch adopted the real surface")
        let measurement = state.coldLaunch.lastMeasurement
        #expect(measurement?.editable == true)
        #expect((measurement?.milliseconds ?? -1) >= 0)

        // The keystroke probe leaves nothing behind: no text and no edit.
        #expect(textView.string.isEmpty)
        #expect(state.documentText.isEmpty)
        #expect(state.hasUnsavedChanges == false)

        // A second surface does not relaunch.
        let second = coldLaunchTextView(editable: false)
        state.completeLaunch(with: second)
        #expect(state.coldLaunch.documentView === textView)
        #expect(state.launchState == .succeeded)
    }

    @Test("A document surface that is not editable fails the launch with 'Could Not Launch'")
    func nonEditableSurfaceFailsTheLaunch() {
        _ = NSApplication.shared
        let state = AppState(settings: ColdLaunchFakeSettingsStore())
        state.completeLaunch(with: coldLaunchTextView(editable: false))

        #expect(state.launchState == .failed)
        #expect(state.isEditable == false, "no editable window remains")
        #expect(state.errorAlert?.title == ColdLaunchUnder100msFeature.failureAlertTitle)
        #expect(state.coldLaunch.documentView == nil)
    }
}
