//
//  PersistTypographyAndKeybindingsInUserdefaultsFeatureTests.swift
//  MonospaceNotesTests
//
//  TASK-13-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS focused suite — owner
//  OWN-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS.
//
//  Covers FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS and its two
//  contracts against the real feature, the real `DataStore` and real
//  `UserDefaults(suiteName:)` suites:
//
//    * ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-01 — after changing the
//      point size to 16 and relaunching, the text view uses 16 points: the change is
//      written through the real store into the suite, the relaunch is a FRESH `DataStore`
//      and a FRESH feature over the SAME suite, and the resolved typography is put on a
//      real `NSTextView` whose font is read back (`pointSize == 16`).
//    * ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-02 — after changing the
//      save keybinding and relaunching, the new keybinding is the one that triggers
//      save: the relaunched resolution carries the new binding, the command surface
//      resolves that binding back to `.save`, and the old default no longer triggers
//      anything (the new binding is *the* one).
//    * ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-03 — an invalid stored
//      point size makes the app use 13 points WITHOUT failing to launch: every invalid
//      shape (a string, an empty string, a negative number, zero, NaN, positive
//      infinity, a number above the maximum) is seeded into the suite, the launch read
//      returns 13 points, `launchState == .succeeded`, no failure is reported, the
//      invalid stored value is left exactly as it was, and `appliedFallbacks` names the
//      setting with cause `.invalidStoredValue`. The invalid stored font family and the
//      invalid stored keybinding blob are covered the same way.
//    * ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-04 — on launch with no
//      stored values the text view uses Menlo at 13 points: a fresh suite resolves to
//      Menlo 13, the real text view's font is read back, and `appliedFallbacks` names
//      both settings with cause `.noStoredValue`.
//    * The exact default keybinding set — Cmd+O, Cmd+S, Cmd+Shift+S, Cmd+F, Cmd+, — is
//      asserted field by field (key, command, shift, option, control) and in menu form.
//    * RECOVERY (CON-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-RECOVERY): a
//      rejected change writes nothing, keeps the last valid stored values, reports
//      non-modally, and never claims a success; a cancelled change writes nothing; a
//      store that refuses the write or hands back values no surface can render cannot
//      produce a claimed success either.
//
//  Every test uses its own dedicated `UserDefaults(suiteName:)` suite and discards it
//  afterwards: nothing reads or writes the standard defaults. The suite constructs
//  AppKit objects, so it is `.serialized`.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import AppKit
import Foundation
import Testing

@testable import MonospaceNotes

// MARK: - Shorthand

/// The type under test, under a short file-private name.
private typealias PersistTestFeature = PersistTypographyAndKeybindingsInUserdefaultsFeature

// MARK: - Fixtures

/// A dedicated, unique `UserDefaults` suite so no test can see another one's state and
/// no test can touch the real standard defaults.
private func persistTestSuite() throws -> (name: String, defaults: UserDefaults) {
    let name = "com.monospace.notes.tests.persist-typography.\(UUID().uuidString)"
    let defaults = try #require(
        UserDefaults(suiteName: name),
        "A dedicated defaults suite is required"
    )
    return (name, defaults)
}

private func persistTestDiscardSuite(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
    // `removePersistentDomain` clears the values; drop the suite's preferences file as
    // well. macOS may recreate it as an empty plist when the preferences daemon next
    // flushes that domain, which is harmless: no stored values remain.
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
        .path
    if FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// One installation of the app over one dedicated defaults suite: a real `DataStore`
/// over that suite plus the feature that reads and writes through it. Two installations
/// over the same suite are two launches of the same app.
@MainActor
private struct PersistTestInstallation {
    let suiteName: String
    let defaults: UserDefaults
    let store: DataStore
    let feature: PersistTestFeature

    init(suiteName: String, defaults: UserDefaults) {
        let store = DataStore(defaults: defaults)
        self.suiteName = suiteName
        self.defaults = defaults
        self.store = store
        self.feature = PersistTestFeature(store: store, defaults: defaults)
    }

    /// A brand-new suite, store and feature.
    static func fresh() throws -> PersistTestInstallation {
        let suite = try persistTestSuite()
        return PersistTestInstallation(suiteName: suite.name, defaults: suite.defaults)
    }

    /// The SAME suite with a brand-new store and a brand-new feature: a relaunch of the
    /// app, which is what "relaunch" means for a persisted setting.
    func relaunching() -> PersistTestInstallation {
        PersistTestInstallation(suiteName: suiteName, defaults: defaults)
    }

    /// The launch read, as the app performs it while the window comes up.
    func launch() -> PersistTestFeature.Resolution {
        feature.loadAtLaunch()
    }

    /// The reported fallbacks of the last launch read, keyed by setting.
    var fallbackCauses: [PersistTestFeature.FallbackSetting: PersistTestFeature.FallbackCause] {
        var causes: [PersistTestFeature.FallbackSetting: PersistTestFeature.FallbackCause] = [:]
        for fallback in feature.fallbacks {
            causes[fallback.setting] = fallback.cause
        }
        return causes
    }

    /// The report entry for one setting, or `nil` when that setting did not fall back.
    func fallback(for setting: PersistTestFeature.FallbackSetting) -> PersistTestFeature.Fallback? {
        feature.fallbacks.first { $0.setting == setting }
    }

    /// The versioned settings keys this suite currently holds.
    func storedSettingsKeys() -> Set<String> {
        Set(
            defaults.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(DataStore.settingsKeyPrefix) }
        )
    }

    func discard() {
        persistTestDiscardSuite(suiteName)
    }
}

/// A raw value seeded into a defaults suite as if an older or a hostile build wrote it.
private enum PersistTypographyTestStoredValue: Sendable, CustomStringConvertible {
    case text(String)
    case number(Double)

    var description: String {
        switch self {
        case .text(let value): return "the string \"\(value)\""
        case .number(let value): return "the number \(value)"
        }
    }

    func apply(to defaults: UserDefaults, forKey key: String) {
        switch self {
        case .text(let value): defaults.set(value, forKey: key)
        case .number(let value): defaults.set(value, forKey: key)
        }
    }
}

/// What running a settings change inside an already-cancelled task produced.
private enum PersistTestCancellationOutcome: Sendable, Equatable {
    case threwCancellationError
    case returnedNormally
    case threwSomethingElse
}

/// A settings store that records what it was asked to persist and can refuse the write.
/// It covers the two branches a real `DataStore` cannot be driven into on demand: a store
/// that refuses every write, and a store that hands back values no surface can render.
private final class PersistTypographyTestRecordingStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let loadedTypography: TypographySettings
    private let loadedKeybindings: KeybindingSettings
    private let refusal: DataStore.OperationError?
    private var typographyWrites = 0
    private var keybindingWrites = 0
    private var lastStoredTypography: TypographySettings?
    private var lastStoredKeybindings: KeybindingSettings?

    init(loadedTypography: TypographySettings = .default,
         loadedKeybindings: KeybindingSettings = .default,
         refusal: DataStore.OperationError? = nil) {
        self.loadedTypography = loadedTypography
        self.loadedKeybindings = loadedKeybindings
        self.refusal = refusal
    }

    func loadTypography() -> TypographySettings { loadedTypography }

    func loadKeybindings() -> KeybindingSettings { loadedKeybindings }

    func storeTypography(_ settings: TypographySettings) throws {
        if let refusal { throw refusal }
        withLock {
            typographyWrites += 1
            lastStoredTypography = settings
        }
    }

    func storeKeybindings(_ settings: KeybindingSettings) throws {
        if let refusal { throw refusal }
        withLock {
            keybindingWrites += 1
            lastStoredKeybindings = settings
        }
    }

    var recordedTypographyWrites: Int { withLock { typographyWrites } }
    var recordedKeybindingWrites: Int { withLock { keybindingWrites } }
    var recordedTypography: TypographySettings? { withLock { lastStoredTypography } }
    var recordedKeybindings: KeybindingSettings? { withLock { lastStoredKeybindings } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A real document text view, configured the way the app's document surface is.
@MainActor
private func persistTestTextView() -> NSTextView {
    _ = NSApplication.shared
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    textView.isEditable = true
    textView.isSelectable = true
    textView.isRichText = false
    textView.string = ""
    return textView
}

/// Runs a settings change and returns the error it threw, or `nil` when it did not throw.
/// Called on the main actor, so the main-actor feature is driven directly.
@MainActor
private func persistTestThrownError(_ change: () throws -> Void) -> Error? {
    do {
        try change()
        return nil
    } catch {
        return error
    }
}

/// Runs `change` inside a task that is cancelled before the body executes, so the
/// feature's cancellation branch is exercised against the real `Task.isCancelled` signal.
private func persistTestRunCancelled(
    _ change: @escaping @MainActor () throws -> Void
) async -> PersistTestCancellationOutcome {
    let task = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            try change()
            return PersistTestCancellationOutcome.returnedNormally
        } catch is CancellationError {
            return .threwCancellationError
        } catch {
            return .threwSomethingElse
        }
    }
    return await task.value
}

/// The text of the feature's own source, for the structural network-freedom proof.
private func persistTestFeatureSourceText() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot
        .appendingPathComponent("Sources/MonospaceNotes/Features/PersistTypographyAndKeybindingsInUserdefaultsFeature.swift")
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

// MARK: - Suite

@Suite("FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS persistence", .serialized)
@MainActor
struct PersistTypographyAndKeybindingsInUserdefaultsFeatureTests {

    // MARK: - The locked defaults

    @Test("The documented defaults are the locked ones: Menlo 13 and the five Command bindings")
    func documentedDefaultsAreLocked() throws {
        let installation = try PersistTestInstallation.fresh()
        defer { installation.discard() }
        let feature = installation.feature

        #expect(PersistTestFeature.defaultTypography == TypographySettings(fontFamily: "Menlo", pointSize: 13))
        #expect(PersistTestFeature.defaultTypography == TypographySettings.default)
        #expect(PersistTestFeature.defaultTypography.fontFamily == DataStore.defaultFontFamily)
        #expect(PersistTestFeature.defaultTypography.fontFamily == "Menlo")
        #expect(PersistTestFeature.defaultTypography.pointSize == DataStore.defaultPointSize)
        #expect(PersistTestFeature.defaultTypography.pointSize == 13)
        #expect(PersistTestFeature.defaultKeybindings == KeybindingSettings.default)
        #expect(PersistTestFeature.defaultKeybindingSummary == "⌘O, ⌘S, ⇧⌘S, ⌘F, ⌘,")
        #expect(PersistTestFeature.typographyFallbackSettingName == "typography")
        #expect(PersistTestFeature.keybindingsFallbackSettingName == "keybindings")

        // The exact default set: Cmd+O, Cmd+S, Cmd+Shift+S, Cmd+F, Cmd+, — every modifier
        // of every binding, not just the key.
        let open = feature.keybinding(for: .open)
        #expect(open.key == "o")
        #expect(open.command)
        #expect(open.shift == false)
        #expect(open.option == false)
        #expect(open.control == false)
        #expect(open == KeyBinding.open)

        let save = feature.keybinding(for: .save)
        #expect(save.key == "s")
        #expect(save.command)
        #expect(save.shift == false)
        #expect(save.option == false)
        #expect(save.control == false)
        #expect(save == KeyBinding.save)

        let saveAs = feature.keybinding(for: .saveAs)
        #expect(saveAs.key == "s")
        #expect(saveAs.command)
        #expect(saveAs.shift)
        #expect(saveAs.option == false)
        #expect(saveAs.control == false)
        #expect(saveAs == KeyBinding.saveAs)

        let search = feature.keybinding(for: .search)
        #expect(search.key == "f")
        #expect(search.command)
        #expect(search.shift == false)
        #expect(search.option == false)
        #expect(search.control == false)
        #expect(search == KeyBinding.search)

        let settings = feature.keybinding(for: .settings)
        #expect(settings.key == ",")
        #expect(settings.command)
        #expect(settings.shift == false)
        #expect(settings.option == false)
        #expect(settings.control == false)
        #expect(settings == KeyBinding.settings)

        // Menu form, and every default binding resolves back to its own command.
        #expect(open.displayString == "⌘O")
        #expect(save.displayString == "⌘S")
        #expect(saveAs.displayString == "⇧⌘S")
        #expect(search.displayString == "⌘F")
        #expect(settings.displayString == "⌘,")
        #expect(feature.command(for: open) == .open)
        #expect(feature.command(for: save) == .save)
        #expect(feature.command(for: saveAs) == .saveAs)
        #expect(feature.command(for: search) == .search)
        #expect(feature.command(for: settings) == .settings)
        #expect(feature.conflictingBindings.isEmpty)
    }

    // MARK: - ACC-...-04: a first launch with no stored values

    @Test("ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-04: a launch with no stored values uses Menlo at 13 points")
    func firstLaunchWithNoStoredValuesUsesMenloAtThirteenPoints() throws {
        let installation = try PersistTestInstallation.fresh()
        defer { installation.discard() }

        let resolution = installation.launch()

        // Menlo at 13 points, the documented typography.
        #expect(resolution.typography == TypographySettings(fontFamily: "Menlo", pointSize: 13))
        #expect(resolution.typography.fontFamily == "Menlo")
        #expect(resolution.typography.pointSize == 13)
        #expect(installation.feature.typography == TypographySettings.default)

        // The exact default keybinding set.
        #expect(resolution.keybindings == KeybindingSettings.default)
        #expect(resolution.keybindings.open == KeyBinding(key: "o", command: true))
        #expect(resolution.keybindings.save == KeyBinding(key: "s", command: true))
        #expect(resolution.keybindings.saveAs == KeyBinding(key: "s", command: true, shift: true))
        #expect(resolution.keybindings.search == KeyBinding(key: "f", command: true))
        #expect(resolution.keybindings.settings == KeyBinding(key: ",", command: true))

        // The text view the launch shows renders Menlo at 13 points.
        let textView = persistTestTextView()
        let applied = installation.feature.apply(resolution, to: textView)
        let rendered = try #require(textView.font, "The document text view must carry a font")
        #expect(rendered.pointSize == 13)
        #expect(rendered.familyName == "Menlo")
        #expect(applied.familyName == "Menlo")
        #expect(applied.pointSize == 13)

        // The launch continued and wrote nothing.
        #expect(installation.feature.launchState == .succeeded)
        #expect(installation.feature.lastStatusMessage == nil)
        #expect(installation.storedSettingsKeys().isEmpty)
        #expect(installation.defaults.object(forKey: DataStore.fontFamilyKey) == nil)
        #expect(installation.defaults.object(forKey: DataStore.pointSizeKey) == nil)
        #expect(installation.defaults.object(forKey: DataStore.saveKeybindingKey) == nil)

        // The documented defaults really were applied, and they are reported as such: a
        // missing value is the fallback of a first launch, not an error.
        #expect(resolution.appliedFallbacks.count == 2)
        #expect(installation.fallbackCauses[.typography] == .noStoredValue)
        #expect(installation.fallbackCauses[.keybindings] == .noStoredValue)

        let typographyFallback = try #require(installation.fallback(for: .typography))
        #expect(typographyFallback.message.hasPrefix("typography:"))
        #expect(typographyFallback.message.contains("Menlo"))
        #expect(typographyFallback.message.contains("13 pt"))
        #expect(resolution.appliedFallbacks.contains(typographyFallback.message))

        let keybindingsFallback = try #require(installation.fallback(for: .keybindings))
        #expect(keybindingsFallback.message.hasPrefix("keybindings:"))
        #expect(keybindingsFallback.message.contains("⌘S"))
        #expect(resolution.appliedFallbacks.contains(keybindingsFallback.message))
    }

    // MARK: - ACC-...-01: the point size survives a relaunch

    @Test("ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-01: after changing the point size to 16 a relaunch renders 16 points")
    func pointSizeSixteenSurvivesARelaunch() throws {
        let installation = try PersistTestInstallation.fresh()
        defer { installation.discard() }

        let firstLaunch = installation.launch()
        #expect(firstLaunch.typography.pointSize == 13)

        // The user changes the point size to 16.
        let applied = try installation.feature.applyTypography(
            TypographySettings(fontFamily: "Menlo", pointSize: 16)
        )
        #expect(applied.pointSize == 16)
        #expect(installation.feature.typographyApplyState == .succeeded)
        #expect(installation.feature.typography.pointSize == 16)
        #expect(installation.feature.lastStatusMessage == nil)

        // The new value really is in the suite, under the store's versioned key.
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 16)
        #expect(installation.defaults.string(forKey: DataStore.fontFamilyKey) == "Menlo")

        // Relaunch: a FRESH store and a FRESH feature over the SAME suite.
        let relaunched = installation.relaunching()
        #expect(relaunched.store !== installation.store)
        #expect(relaunched.feature !== installation.feature)
        #expect(relaunched.defaults === installation.defaults)

        let resolution = relaunched.launch()
        #expect(resolution.typography.pointSize == 16)
        #expect(resolution.typography.fontFamily == "Menlo")
        #expect(resolution.typography == TypographySettings(fontFamily: "Menlo", pointSize: 16))
        #expect(relaunched.feature.typography.pointSize == 16)
        #expect(relaunched.feature.launchState == .succeeded)

        // The text view the relaunch shows renders 16 points.
        let textView = persistTestTextView()
        relaunched.feature.apply(resolution, to: textView)
        #expect(textView.font?.pointSize == 16)
        #expect(textView.font?.familyName == "Menlo")

        // The typography came back from the store, so no typography fallback was applied.
        #expect(relaunched.fallbackCauses[.typography] == nil)
        #expect(resolution.appliedFallbacks.contains { $0.hasPrefix("typography") } == false)

        // Once the keybindings are an explicit choice as well, a full relaunch resolves
        // every setting from the store with no fallback at all — and a further relaunch
        // is identical, so the values are genuinely durable.
        _ = try relaunched.feature.applyKeybindings(KeybindingSettings.default)
        let third = relaunched.relaunching().launch()
        #expect(third.typography.pointSize == 16)
        #expect(third.appliedFallbacks.isEmpty)
        #expect(third == PersistTestFeature.Resolution(
            typography: TypographySettings(fontFamily: "Menlo", pointSize: 16),
            keybindings: KeybindingSettings.default,
            appliedFallbacks: []
        ))
    }

    // MARK: - ACC-...-02: the changed save keybinding is the one that saves

    @Test("ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-02: after changing the save keybinding a relaunch makes the new binding the one that saves")
    func changedSaveKeybindingTriggersSaveAfterARelaunch() throws {
        let installation = try PersistTestInstallation.fresh()
        defer { installation.discard() }

        let firstLaunch = installation.launch()
        #expect(firstLaunch.keybindings.save == KeyBinding(key: "s", command: true))

        // The user moves Save from Cmd+S to Option+Cmd+K.
        let newSave = KeyBinding(key: "k", command: true, option: true)
        #expect(newSave.displayString == "⌥⌘K")
        var changed = KeybindingSettings.default
        changed.save = newSave

        let applied = try installation.feature.applyKeybindings(changed)
        #expect(applied.save == newSave)
        #expect(installation.feature.keybindingApplyState == .succeeded)
        #expect(installation.feature.keybindings.save == newSave)
        #expect(installation.defaults.data(forKey: DataStore.saveKeybindingKey) != nil)

        // Relaunch: a FRESH store and a FRESH feature over the SAME suite.
        let relaunched = installation.relaunching()
        let resolution = relaunched.launch()

        // The resolved keybinding equals the new one ...
        #expect(resolution.keybindings.save == newSave)
        #expect(relaunched.feature.keybinding(for: .save) == newSave)
        // ... and it is the one the command surface resolves Save from ...
        #expect(relaunched.feature.command(for: newSave) == .save)
        // ... while the old default no longer triggers Save at all.
        #expect(relaunched.feature.command(for: KeyBinding.save) == nil)
        #expect(relaunched.feature.command(for: KeyBinding(key: "s", command: true, shift: true, option: true)) == nil)

        // Only Save moved: the other four commands keep the documented defaults.
        #expect(relaunched.feature.keybinding(for: .open) == KeyBinding.open)
        #expect(relaunched.feature.keybinding(for: .saveAs) == KeyBinding.saveAs)
        #expect(relaunched.feature.keybinding(for: .search) == KeyBinding.search)
        #expect(relaunched.feature.keybinding(for: .settings) == KeyBinding.settings)
        #expect(relaunched.feature.command(for: KeyBinding.open) == .open)
        #expect(relaunched.feature.command(for: KeyBinding.search) == .search)
        #expect(relaunched.feature.conflictingBindings.isEmpty)
        #expect(resolution.appliedFallbacks.contains { $0.hasPrefix("keybindings") } == false)

        // The raw persisted blob carries the changed assignment, read back through the
        // store's own versioned record type.
        let blob = try #require(installation.defaults.data(forKey: DataStore.saveKeybindingKey))
        let record = try JSONDecoder().decode(DataStore.KeybindingRecord.self, from: blob)
        #expect(record.version == DataStore.KeybindingRecord.currentVersion)
        #expect(record.saveShortcut.key == "k")
        #expect(record.saveShortcut.command)
        #expect(record.saveShortcut.option)
        #expect(record.saveShortcut.shift == false)
        #expect(record.openShortcut.key == "o")
        #expect(record.saveAsShortcut.shift)
    }

    // MARK: - ACC-...-03: an invalid stored value falls back without failing the launch

    @Test("ACC-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-03: an invalid stored point size uses 13 points, is reported, and does not fail the launch")
    func invalidStoredPointSizesFallBackToThirteenAndAreReported() throws {
        let invalidCases: [(label: String, value: PersistTypographyTestStoredValue)] = [
            ("a string", .text("sixteen")),
            ("an empty string", .text("")),
            ("a negative number", .number(-1)),
            ("zero", .number(0)),
            ("NaN", .number(.nan)),
            ("positive infinity", .number(.infinity)),
            ("a number above the maximum", .number(100_000)),
        ]

        for invalidCase in invalidCases {
            let installation = try PersistTestInstallation.fresh()
            defer { installation.discard() }
            invalidCase.value.apply(to: installation.defaults, forKey: DataStore.pointSizeKey)

            // The launch read: no throw, no failure, 13 points.
            let resolution = installation.launch()
            #expect(resolution.typography.pointSize == 13, "\(invalidCase.label) must fall back to 13 points")
            #expect(resolution.typography.fontFamily == "Menlo", "\(invalidCase.label) keeps the Menlo default")
            #expect(installation.feature.launchState == .succeeded, "\(invalidCase.label) must not fail the launch")
            #expect(installation.feature.typography.pointSize == 13, "\(invalidCase.label) must publish 13 points")
            #expect(installation.feature.lastStatusMessage == nil, "\(invalidCase.label) is not a failure")

            // The fallback is reported, and it names the setting.
            let fallback = try #require(
                installation.fallback(for: .typography),
                "\(invalidCase.label) must be reported as an applied fallback"
            )
            #expect(fallback.cause == .invalidStoredValue, "\(invalidCase.label) is an invalid stored value")
            #expect(fallback.message.hasPrefix("typography:"), "\(invalidCase.label) must name the setting")
            #expect(fallback.message.contains("invalid"), "\(invalidCase.label) must name the cause")
            #expect(fallback.message.contains("13 pt"), "\(invalidCase.label) must name the value used")
            #expect(resolution.appliedFallbacks.contains(fallback.message))
            #expect(installation.fallbackCauses[.typography] == .invalidStoredValue)

            // The text view uses 13 points.
            let textView = persistTestTextView()
            installation.feature.apply(resolution, to: textView)
            #expect(textView.font?.pointSize == 13, "\(invalidCase.label) renders 13 points")
            #expect(textView.font?.familyName == "Menlo", "\(invalidCase.label) renders Menlo")

            // The invalid stored value is left exactly as it was: nothing was silently
            // repaired behind the user's back.
            #expect(installation.defaults.object(forKey: DataStore.pointSizeKey) != nil)

            // Relaunching with the invalid value still stored is still a working launch.
            let relaunched = installation.relaunching()
            #expect(relaunched.launch().typography.pointSize == 13)
            #expect(relaunched.fallbackCauses[.typography] == .invalidStoredValue)
            #expect(relaunched.feature.launchState == .succeeded)
        }

        // A valid stored value is used as it is and produces no fallback at all: the
        // fallback is reserved for values that cannot be used.
        let valid = try PersistTestInstallation.fresh()
        defer { valid.discard() }
        valid.defaults.set("Menlo", forKey: DataStore.fontFamilyKey)
        valid.defaults.set(16.0, forKey: DataStore.pointSizeKey)
        let validResolution = valid.launch()
        #expect(validResolution.typography.pointSize == 16)
        #expect(valid.fallbackCauses[.typography] == nil)
        #expect(validResolution.appliedFallbacks.contains { $0.hasPrefix("typography") } == false)
    }

    @Test("An invalid stored font family falls back to Menlo and is reported without failing the launch")
    func invalidStoredFontFamiliesFallBackToMenloAndAreReported() throws {
        let invalidCases: [(label: String, value: PersistTypographyTestStoredValue)] = [
            ("an empty string", .text("")),
            ("whitespace only", .text("   \n")),
            ("a number", .number(3)),
        ]

        for invalidCase in invalidCases {
            let installation = try PersistTestInstallation.fresh()
            defer { installation.discard() }
            invalidCase.value.apply(to: installation.defaults, forKey: DataStore.fontFamilyKey)

            let resolution = installation.launch()
            #expect(resolution.typography.fontFamily == "Menlo", "\(invalidCase.label) must fall back to Menlo")
            #expect(resolution.typography.pointSize == 13, "\(invalidCase.label) keeps 13 points")
            #expect(installation.feature.launchState == .succeeded, "\(invalidCase.label) must not fail the launch")

            let fallback = try #require(
                installation.fallback(for: .typography),
                "\(invalidCase.label) must be reported as an applied fallback"
            )
            #expect(fallback.cause == .invalidStoredValue)
            #expect(fallback.message.hasPrefix("typography:"))
            #expect(fallback.message.contains("font family"))
            #expect(fallback.message.contains("Menlo"))
        }
    }

    @Test("An invalid or unknown-version stored keybinding set falls back to the documented default set")
    func invalidStoredKeybindingBlobsFallBackToTheDefaultSet() throws {
        let unknownVersion = DataStore.KeybindingRecord(
            version: 99,
            openShortcut: DataStore.KeybindingRecord.Shortcut(.open),
            saveShortcut: DataStore.KeybindingRecord.Shortcut(.save),
            saveAsShortcut: DataStore.KeybindingRecord.Shortcut(.saveAs),
            searchShortcut: DataStore.KeybindingRecord.Shortcut(.search),
            settingsShortcut: DataStore.KeybindingRecord.Shortcut(.settings)
        )

        let invalidCases: [(label: String, blob: Data)] = [
            ("random bytes", Data("not a keybinding record".utf8)),
            ("truncated JSON", Data(#"{"version":1,"openShortcut":{"key":"o","#.utf8)),
            ("an unknown version", try JSONEncoder().encode(unknownVersion)),
        ]

        for invalidCase in invalidCases {
            let installation = try PersistTestInstallation.fresh()
            defer { installation.discard() }
            installation.defaults.set(invalidCase.blob, forKey: DataStore.saveKeybindingKey)

            let resolution = installation.launch()
            #expect(resolution.keybindings == KeybindingSettings.default, "\(invalidCase.label) must fall back to the default set")
            #expect(resolution.keybindings.save == KeyBinding(key: "s", command: true), "\(invalidCase.label) keeps Cmd+S for Save")
            #expect(resolution.keybindings.saveAs == KeyBinding(key: "s", command: true, shift: true), "\(invalidCase.label) keeps Shift+Cmd+S")
            #expect(installation.feature.launchState == .succeeded, "\(invalidCase.label) must not fail the launch")
            #expect(installation.feature.lastStatusMessage == nil)
            #expect(installation.feature.command(for: KeyBinding.save) == .save)

            let fallback = try #require(
                installation.fallback(for: .keybindings),
                "\(invalidCase.label) must be reported as an applied fallback"
            )
            #expect(fallback.cause == .invalidStoredValue)
            #expect(fallback.message.hasPrefix("keybindings:"))
            #expect(fallback.message.contains("⌘S"))
            #expect(resolution.appliedFallbacks.contains(fallback.message))
        }

        // A raw value under the key that is not a blob at all is invalid too.
        let nonBlob = try PersistTestInstallation.fresh()
        defer { nonBlob.discard() }
        nonBlob.defaults.set("s", forKey: DataStore.saveKeybindingKey)
        let nonBlobResolution = nonBlob.launch()
        #expect(nonBlobResolution.keybindings == KeybindingSettings.default)
        #expect(nonBlob.fallbackCauses[.keybindings] == .invalidStoredValue)
        #expect(nonBlob.feature.launchState == .succeeded)
    }

    @Test("A stored set that equals the documented default is the user's choice, not a fallback")
    func aStoredDefaultSetIsNotAFallback() throws {
        let installation = try PersistTestInstallation.fresh()
        defer { installation.discard() }

        // The store itself writes the documented defaults: a valid stored set that happens
        // to equal the defaults must not be reported as a fallback, which is why the report
        // is driven by the stored value and not by comparing against the default.
        installation.defaults.set("Menlo", forKey: DataStore.fontFamilyKey)
        installation.defaults.set(13.0, forKey: DataStore.pointSizeKey)
        try installation.store.storeKeybindings(KeybindingSettings.default)

        let resolution = installation.launch()
        #expect(resolution.keybindings == KeybindingSettings.default)
        #expect(resolution.typography == TypographySettings(fontFamily: "Menlo", pointSize: 13))
        #expect(resolution.appliedFallbacks.isEmpty)
        #expect(installation.feature.fallbacks.isEmpty)
        #expect(installation.feature.launchState == .succeeded)
    }

    // MARK: - Recovery: a rejected change keeps the last valid state

    @Test("A rejected typography change writes nothing, keeps the last valid settings, and reports non-modally")
    func rejectedTypographyChangeKeepsTheLastValidState() throws {
        let installation = try PersistTestInstallation.fresh()
        defer { installation.discard() }
        _ = installation.launch()
        _ = try installation.feature.applyTypography(TypographySettings(fontFamily: "Menlo", pointSize: 16))

        let rejections: [(label: String, value: TypographySettings)] = [
            ("a non-finite point size", TypographySettings(fontFamily: "Menlo", pointSize: .nan)),
            ("an infinite point size", TypographySettings(fontFamily: "Menlo", pointSize: .infinity)),
            ("a zero point size", TypographySettings(fontFamily: "Menlo", pointSize: 0)),
            ("a negative point size", TypographySettings(fontFamily: "Menlo", pointSize: -4)),
            ("a point size above the maximum", TypographySettings(fontFamily: "Menlo", pointSize: 513)),
            ("an empty font family", TypographySettings(fontFamily: "   ", pointSize: 16)),
        ]

        for rejection in rejections {
            let thrown = persistTestThrownError {
                _ = try installation.feature.applyTypography(rejection.value)
            }
            let storeError = try #require(
                thrown as? DataStore.OperationError,
                "\(rejection.label) must be rejected with the store's own error"
            )
            guard case .invalidTypography = storeError else {
                Issue.record("\(rejection.label) must be rejected as invalid typography, got \(storeError)")
                continue
            }

            #expect(installation.feature.typographyApplyState == .failed, "\(rejection.label) must fail the change")
            #expect(installation.feature.typography.pointSize == 16, "\(rejection.label) must keep the last valid point size")
            #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 16, "\(rejection.label) must not write")
            #expect(installation.defaults.string(forKey: DataStore.fontFamilyKey) == "Menlo")

            let status = try #require(installation.feature.lastStatusMessage, "\(rejection.label) must be reported")
            #expect(status.isFailure, "\(rejection.label) is a failure")
            #expect(status.text.contains("Rejected typography settings"), "\(rejection.label) must carry the store's reason")
            #expect(status.text.contains("unchanged"), "\(rejection.label) must say the previous settings stand")
        }

        // An explicit retry with a usable value works, and the state returns to succeeded.
        let reapplied = try installation.feature.applyTypography(
            TypographySettings(fontFamily: "Menlo", pointSize: 18)
        )
        #expect(reapplied.pointSize == 18)
        #expect(installation.feature.typographyApplyState == .succeeded)
        #expect(installation.feature.typography.pointSize == 18)
        #expect(installation.feature.lastStatusMessage == nil)
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 18)
    }

    @Test("A rejected keybinding change writes nothing and keeps the last valid set")
    func rejectedKeybindingChangeKeepsTheLastValidState() throws {
        let installation = try PersistTestInstallation.fresh()
        defer { installation.discard() }
        _ = installation.launch()

        let newSave = KeyBinding(key: "k", command: true, option: true)
        var valid = KeybindingSettings.default
        valid.save = newSave
        _ = try installation.feature.applyKeybindings(valid)
        let storedBlob = try #require(installation.defaults.data(forKey: DataStore.saveKeybindingKey))

        // A binding with no key can never be triggered: the store rejects it.
        var invalid = valid
        invalid.open = KeyBinding(key: "", command: true)
        let thrown = persistTestThrownError {
            _ = try installation.feature.applyKeybindings(invalid)
        }
        let storeError = try #require(
            thrown as? DataStore.OperationError,
            "An empty key must be rejected with the store's own error"
        )
        #expect(storeError == DataStore.OperationError.invalidKeybinding("the open keybinding has no key"))
        #expect(installation.feature.keybindingApplyState == .failed)
        #expect(installation.feature.keybindings == valid)
        #expect(installation.feature.keybinding(for: .open) == KeyBinding.open)
        #expect(installation.defaults.data(forKey: DataStore.saveKeybindingKey) == storedBlob)

        let status = try #require(installation.feature.lastStatusMessage)
        #expect(status.isFailure)
        #expect(status.text.contains("unchanged"))

        // A corrected set applies, and survives a relaunch.
        var corrected = valid
        corrected.open = KeyBinding(key: "p", command: true, shift: true)
        _ = try installation.feature.applyKeybindings(corrected)
        #expect(installation.feature.keybindingApplyState == .succeeded)
        #expect(installation.feature.keybinding(for: .open) == KeyBinding(key: "p", command: true, shift: true))
        let relaunched = installation.relaunching()
        let resolution = relaunched.launch()
        #expect(resolution.keybindings.save == newSave)
        #expect(resolution.keybindings.open == KeyBinding(key: "p", command: true, shift: true))
        #expect(relaunched.feature.command(for: KeyBinding(key: "p", command: true, shift: true)) == .open)
    }

    @Test("A store that refuses the write surfaces the failure and never claims a success")
    func refusingStoreSurfacesTheFailureWithoutClaimingSuccess() throws {
        let refusal = DataStore.OperationError.invalidTypography("the settings store refused the write")
        let store = PersistTypographyTestRecordingStore(
            loadedTypography: TypographySettings(fontFamily: "Menlo", pointSize: 16),
            loadedKeybindings: KeybindingSettings.default,
            refusal: refusal
        )
        let feature = PersistTestFeature(store: store)

        // Without a probe the feature cannot tell a stored value from a substituted one,
        // so it applies what the store returned and reports no fallback of its own.
        let resolution = feature.loadAtLaunch()
        #expect(resolution.typography == TypographySettings(fontFamily: "Menlo", pointSize: 16))
        #expect(resolution.keybindings == KeybindingSettings.default)
        #expect(resolution.appliedFallbacks.isEmpty)
        #expect(feature.launchState == .succeeded)

        let typographyError = persistTestThrownError {
            _ = try feature.applyTypography(TypographySettings(fontFamily: "Menlo", pointSize: 20))
        }
        #expect(typographyError as? DataStore.OperationError == refusal)
        #expect(store.recordedTypographyWrites == 0)
        #expect(feature.typographyApplyState == .failed)
        #expect(feature.typography.pointSize == 16)
        let typographyStatus = try #require(feature.lastStatusMessage)
        #expect(typographyStatus.isFailure)
        #expect(typographyStatus.text.contains("refused"))

        var changed = KeybindingSettings.default
        changed.search = KeyBinding(key: "j", command: true)
        let keybindingError = persistTestThrownError {
            _ = try feature.applyKeybindings(changed)
        }
        #expect(keybindingError as? DataStore.OperationError == refusal)
        #expect(store.recordedKeybindingWrites == 0)
        #expect(feature.keybindingApplyState == .failed)
        #expect(feature.keybindings == KeybindingSettings.default)
        #expect(feature.keybinding(for: .search) == KeyBinding.search)
        let keybindingStatus = try #require(feature.lastStatusMessage)
        #expect(keybindingStatus.isFailure)
        #expect(keybindingStatus.text.contains("unchanged"))
    }

    @Test("A store that hands back values no surface can render is substituted at the last gate and reported")
    func unusableStoreValuesAreSubstitutedAtTheLastGate() throws {
        let store = PersistTypographyTestRecordingStore(
            loadedTypography: TypographySettings(fontFamily: "   ", pointSize: .nan),
            loadedKeybindings: KeybindingSettings(
                open: KeyBinding(key: "", command: true),
                save: .save,
                saveAs: .saveAs,
                search: .search,
                settings: .settings
            )
        )
        let feature = PersistTestFeature(store: store)
        let resolution = feature.loadAtLaunch()

        // Nothing unusable reaches the surface: the documented defaults stand.
        #expect(resolution.typography == TypographySettings(fontFamily: "Menlo", pointSize: 13))
        #expect(resolution.keybindings == KeybindingSettings.default)
        #expect(feature.typography == TypographySettings.default)
        #expect(feature.keybindings == KeybindingSettings.default)
        #expect(feature.launchState == .succeeded)

        // Both settings are reported as invalid stored values.
        #expect(resolution.appliedFallbacks.count == 2)
        let typographyFallback = try #require(feature.fallbacks.first { $0.setting == .typography })
        #expect(typographyFallback.cause == .invalidStoredValue)
        #expect(typographyFallback.message.hasPrefix("typography:"))
        let keybindingsFallback = try #require(feature.fallbacks.first { $0.setting == .keybindings })
        #expect(keybindingsFallback.cause == .invalidStoredValue)
        #expect(keybindingsFallback.message.hasPrefix("keybindings:"))
        #expect(keybindingsFallback.message.contains("no key"))

        // The text view renders the substituted font, and the command surface resolves the
        // substituted set.
        let textView = persistTestTextView()
        feature.apply(resolution, to: textView)
        #expect(textView.font?.pointSize == 13)
        #expect(textView.font?.familyName == "Menlo")
        #expect(feature.command(for: KeyBinding.save) == .save)
    }

    @Test("A cancelled settings change writes nothing and keeps the last valid state")
    func cancelledChangeWritesNothingAndKeepsTheLastValidState() async throws {
        let installation = try PersistTestInstallation.fresh()
        defer { installation.discard() }
        _ = installation.launch()
        let feature = installation.feature

        let typographyOutcome = await persistTestRunCancelled {
            _ = try feature.applyTypography(TypographySettings(fontFamily: "Menlo", pointSize: 16))
        }
        #expect(typographyOutcome == .threwCancellationError)
        #expect(feature.typographyApplyState == .cancelled)
        #expect(feature.typography == TypographySettings.default)
        #expect(installation.storedSettingsKeys().isEmpty)
        let typographyStatus = try #require(feature.lastStatusMessage)
        #expect(typographyStatus.isFailure == false)

        let keybindingOutcome = await persistTestRunCancelled {
            _ = try feature.applyKeybindings(KeybindingSettings.default)
        }
        #expect(keybindingOutcome == .threwCancellationError)
        #expect(feature.keybindingApplyState == .cancelled)
        #expect(feature.keybindings == KeybindingSettings.default)
        #expect(installation.storedSettingsKeys().isEmpty)

        // The same call from a live task persists normally: the difference is the
        // cancellation, not the write path.
        _ = try feature.applyTypography(TypographySettings(fontFamily: "Menlo", pointSize: 16))
        #expect(feature.typographyApplyState == .succeeded)
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 16)
    }

    // MARK: - Command resolution

    @Test("A binding shared by two commands resolves to no command instead of guessing")
    func aBindingSharedByTwoCommandsResolvesToNoCommand() throws {
        let installation = try PersistTestInstallation.fresh()
        defer { installation.discard() }
        _ = installation.launch()

        // A stored set is allowed to contain the same key twice; the app must not pick one
        // command behind the user's back.
        var shared = KeybindingSettings.default
        shared.search = shared.save
        _ = try installation.feature.applyKeybindings(shared)

        #expect(installation.feature.keybinding(for: .save) == KeyBinding.save)
        #expect(installation.feature.keybinding(for: .search) == KeyBinding.save)
        #expect(installation.feature.command(for: KeyBinding.save) == nil)
        #expect(installation.feature.conflictingBindings == [KeyBinding.save])

        // The unambiguous commands still resolve.
        #expect(installation.feature.command(for: KeyBinding.open) == .open)
        #expect(installation.feature.command(for: KeyBinding.saveAs) == .saveAs)
        #expect(installation.feature.command(for: KeyBinding.settings) == .settings)

        // The conflict survives a relaunch: the store accepted the set, and the resolution
        // still refuses to guess.
        let relaunched = installation.relaunching()
        _ = relaunched.launch()
        #expect(relaunched.feature.command(for: KeyBinding.save) == nil)
        #expect(relaunched.feature.conflictingBindings == [KeyBinding.save])
    }

    // MARK: - Persistence boundaries

    @Test("A launch read writes nothing, and the only keys ever persisted are the settings keys")
    func theLaunchReadNeverWritesAndOnlySettingsKeysArePersisted() throws {
        let installation = try PersistTestInstallation.fresh()
        defer { installation.discard() }

        let first = installation.launch()
        #expect(installation.storedSettingsKeys().isEmpty)
        #expect(installation.defaults.object(forKey: DataStore.fontFamilyKey) == nil)
        #expect(installation.defaults.object(forKey: DataStore.pointSizeKey) == nil)
        #expect(installation.defaults.object(forKey: DataStore.saveKeybindingKey) == nil)

        // The read is repeatable and publishes the same resolution.
        #expect(installation.launch() == first)

        _ = try installation.feature.applyTypography(TypographySettings(fontFamily: "Menlo", pointSize: 16))
        #expect(installation.storedSettingsKeys() == [DataStore.fontFamilyKey, DataStore.pointSizeKey])

        _ = try installation.feature.applyKeybindings(KeybindingSettings.default)
        #expect(installation.storedSettingsKeys() == [
            DataStore.fontFamilyKey,
            DataStore.pointSizeKey,
            DataStore.saveKeybindingKey,
        ])
        #expect(DataStore.settingsKeyPrefix == "com.monospace.notes.settings.v1.")
        #expect(DataStore.fontFamilyKey == "com.monospace.notes.settings.v1.fontFamily")
        #expect(DataStore.pointSizeKey == "com.monospace.notes.settings.v1.pointSize")
        #expect(DataStore.saveKeybindingKey == "com.monospace.notes.settings.v1.saveKeybinding")
    }

    @Test("The feature issues no network request and performs no file I/O (structural proof)")
    func theFeatureIsFreeOfNetworkAndFileIO() throws {
        let source = try persistTestFeatureSourceText()

        for token in ["import Network", "URLSession", "NSURLConnection", "NSURLRequest", "CFNetwork", "NWConnection"] {
            #expect(source.contains(token) == false, "the feature source must not contain \(token)")
        }
        for token in ["FileManager", "FileHandle", "Data(contentsOf:", "write(to:", "URL(fileURLWithPath:"] {
            #expect(source.contains(token) == false, "the feature source must not contain \(token)")
        }

        #expect(source.contains("import AppKit"))
        // The only persistence service the feature holds is the settings store: it has no
        // note-file access at all, so the launch read cannot touch a note.
        #expect(source.contains("any SettingsStoring"))
        #expect(source.contains("any NoteFileAccess") == false)
        #expect(source.contains("UserDefaults.standard") == false)
    }
}
