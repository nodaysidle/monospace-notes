//
//  SettingsWindowForTypographyAndKeybindingsFeatureTests.swift
//  MonospaceNotesTests
//
//  TASK-14-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS focused suite — owner
//  OWN-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS.
//
//  Covers FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS and its two contracts
//  against the real feature, the real `DataStore` and real `UserDefaults(suiteName:)`
//  suites:
//
//    * ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-01 — after changing a setting
//      the corresponding UserDefaults key contains the new value. The RAW stored values
//      are read straight out of the dedicated suite: the family string, the point size
//      `NSNumber`, and the keybinding blob decoded through the store's own versioned
//      record type.
//    * ACC-...-02 — choosing a font family and point size updates the text view's font to
//      that family and size: a real `NSTextView` carries a real `NSFont` whose
//      `familyName` is the chosen family and whose `pointSize` is the chosen size, and
//      the same font name AppKit resolves for that family and size.
//    * ACC-...-03 — choosing an UNAVAILABLE family leaves the text view font UNCHANGED
//      (the very same `NSFont` instance), writes nothing to the suite, keeps the previous
//      settings in effect, and shows the exact inline message
//      `Font family “<name>” is unavailable.` with the locked curly quotes.
//    * ACC-...-04 — reopening the Settings window shows the previously chosen values:
//      a fresh feature over the same suite reads them back through `currentDraft()`, and
//      its spoken values agree.
//    * The Accessibility contract (TRD.md "Accessibility Contracts"): every control — the
//      font family picker, the point size stepper and each of the five keybinding rows —
//      exposes a stable label, role, value and hint in focus order, the values follow the
//      settings, and `SettingsView` renders those same labels/values/hints/identifiers.
//    * RECOVERY (CON-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-RECOVERY): a rejected
//      or refused change writes nothing and keeps the last valid state; a cancelled change
//      writes nothing; an invalid stored value falls back through the store's documented
//      defaults without failing the window; an explicit retry afterwards works.
//
//  Every test uses its own dedicated `UserDefaults(suiteName:)` suite and discards it
//  afterwards: nothing reads or writes the standard defaults. The suite constructs AppKit
//  objects, so it is `.serialized`. No wall-clock timing is asserted; no UI is shown.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import AppKit
import Foundation
import Testing

@testable import MonospaceNotes

// MARK: - Shorthand

/// The type under test, under a short file-private name.
private typealias SettingsWindowFeature = SettingsWindowForTypographyAndKeybindingsFeature
private typealias SettingsWindowDraft = SettingsWindowForTypographyAndKeybindingsFeature.Draft
private typealias SettingsWindowResult = SettingsWindowForTypographyAndKeybindingsFeature.ApplyResult
private typealias SettingsWindowElement = SettingsWindowForTypographyAndKeybindingsFeature.AccessibilityElement
private typealias SettingsWindowCommand = PersistTypographyAndKeybindingsInUserdefaultsFeature.Command

// MARK: - Fixtures

/// A family no macOS installation offers. Measured on this machine: `NSFont(name:size:)`
/// returns nil for it and it is not in `NSFontManager.shared.availableFontFamilies`.
private let settingsWindowTestUnavailableFamily = "NoSuchFamily-MonospaceNotes"

/// A monospaced family that is not the default, so a change of family is observable.
private let settingsWindowTestAlternativeFamily = "Monaco"

/// A dedicated, unique `UserDefaults` suite so no test can see another one's state and
/// no test can touch the real standard defaults.
private func settingsWindowTestSuite() throws -> (name: String, defaults: UserDefaults) {
    let name = "com.monospace.notes.tests.settings-window.\(UUID().uuidString)"
    let defaults = try #require(
        UserDefaults(suiteName: name),
        "A dedicated defaults suite is required"
    )
    return (name, defaults)
}

private func settingsWindowTestDiscardSuite(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
        .path
    if FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// One opening of the Settings window over one dedicated defaults suite: a real
/// `DataStore` over that suite plus the feature the window is driven by. Two
/// installations over the same suite are two openings of the same window.
@MainActor
private struct SettingsWindowTestInstallation {
    let suiteName: String
    let defaults: UserDefaults
    let store: DataStore
    let feature: SettingsWindowFeature

    /// The app's window over a brand-new dedicated suite. The seeding closure runs before
    /// the window reads the store, so a stored value a test wants to replay can be put in
    /// place first.
    static func fresh(
        seeding: (UserDefaults) -> Void = { _ in }
    ) throws -> SettingsWindowTestInstallation {
        let suite = try settingsWindowTestSuite()
        seeding(suite.defaults)
        return installation(suiteName: suite.name, defaults: suite.defaults)
    }

    /// The SAME suite with a brand-new store and a brand-new window: reopening Settings.
    func reopening() -> SettingsWindowTestInstallation {
        Self.installation(suiteName: suiteName, defaults: defaults)
    }

    /// The versioned settings keys this suite currently holds.
    var storedSettingsKeys: Set<String> {
        Set(
            defaults.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(DataStore.settingsKeyPrefix) }
        )
    }

    /// The raw keybinding blob, as stored.
    var storedKeybindingBlob: Data? {
        defaults.data(forKey: DataStore.saveKeybindingKey)
    }

    func discard() {
        settingsWindowTestDiscardSuite(suiteName)
    }

    private static func installation(
        suiteName: String,
        defaults: UserDefaults
    ) -> SettingsWindowTestInstallation {
        let store = DataStore(defaults: defaults)
        return SettingsWindowTestInstallation(
            suiteName: suiteName,
            defaults: defaults,
            store: store,
            feature: SettingsWindowFeature(store: store)
        )
    }
}

/// A real document text view, configured the way the app's document surface is.
@MainActor
private func settingsWindowTestTextView() -> NSTextView {
    _ = NSApplication.shared
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    textView.isEditable = true
    textView.isSelectable = true
    textView.isRichText = false
    textView.string = ""
    return textView
}

/// Runs a settings change and returns the error it threw, or `nil` when it did not throw.
@MainActor
private func settingsWindowTestThrownError(_ change: () throws -> Void) -> Error? {
    do {
        try change()
        return nil
    } catch {
        return error
    }
}

/// What running a settings change inside an already-cancelled task produced.
private enum SettingsWindowTestCancellationOutcome: Sendable, Equatable {
    case threwCancellationError
    case returnedNormally
    case threwSomethingElse
}

/// Runs `change` inside a task that is cancelled before the body executes, so the
/// feature's cancellation branch is exercised against the real `Task.isCancelled` signal.
private func settingsWindowTestRunCancelled(
    _ change: @escaping @MainActor () throws -> Void
) async -> SettingsWindowTestCancellationOutcome {
    let task = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        do {
            try change()
            return SettingsWindowTestCancellationOutcome.returnedNormally
        } catch is CancellationError {
            return .threwCancellationError
        } catch {
            return .threwSomethingElse
        }
    }
    return await task.value
}

/// A settings store that records what it was asked to persist and can refuse every write.
/// It covers the branch a real `DataStore` cannot be driven into on demand: a store that
/// rejects the change, which must leave the last valid state untouched.
private final class SettingsWindowTestRecordingStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let loadedTypography: TypographySettings
    private let loadedKeybindings: KeybindingSettings
    private let refusal: DataStore.OperationError?
    private var typographyWrites = 0
    private var keybindingWrites = 0

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
        withLock { typographyWrites += 1 }
    }

    func storeKeybindings(_ settings: KeybindingSettings) throws {
        if let refusal { throw refusal }
        withLock { keybindingWrites += 1 }
    }

    var recordedTypographyWrites: Int { withLock { typographyWrites } }
    var recordedKeybindingWrites: Int { withLock { keybindingWrites } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The text of the source file that declares both the feature and its `SettingsView`,
/// for the structural proofs (network freedom, file-I/O freedom, accessibility wiring).
private func settingsWindowTestSourceText() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot
        .appendingPathComponent(
            "Sources/MonospaceNotes/Features/SettingsWindowForTypographyAndKeybindingsFeature.swift"
        )
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

/// The keybinding set the tests change: Save moves to Option+Cmd+K.
private func settingsWindowTestChangedKeybindings() -> KeybindingSettings {
    var keybindings = KeybindingSettings.default
    keybindings.save = KeyBinding(key: "k", command: true, option: true)
    return keybindings
}

@MainActor
private func settingsWindowTestElement(
    _ elements: [SettingsWindowElement],
    role: SettingsWindowElement.Role
) -> SettingsWindowElement? {
    elements.first { $0.role == role }
}

// MARK: - Suite

@Suite("FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS", .serialized)
@MainActor
struct SettingsWindowForTypographyAndKeybindingsFeatureTests {

    // MARK: - What the window offers

    @Test("The family list offers only real monospaced families and never the unavailable probe")
    func theFamilyListOffersRealMonospacedFamilies() throws {
        let installation = try SettingsWindowTestInstallation.fresh()
        defer { installation.discard() }
        let families = installation.feature.availableFontFamilies()

        // The documented default and a second real family are both offered.
        #expect(families.contains(DataStore.defaultFontFamily))
        #expect(families.contains("Menlo"))
        #expect(families.contains(settingsWindowTestAlternativeFamily))
        // The list is sorted, so it is stable across openings.
        #expect(families == families.sorted())
        // Every offered family is a real font this Mac can render, and it is really
        // monospaced — measured from the glyphs, not trusted from a trait.
        for family in families {
            let font = try #require(
                NSFont(name: family, size: DataStore.defaultPointSize),
                "\(family) must be a font AppKit can render"
            )
            #expect(
                DarkMonochromaticWindowAppearanceFeature.isMonospace(font),
                "\(family) must really be monospaced"
            )
        }

        // The unavailable probe is not offered, and the availability check agrees.
        #expect(families.contains(settingsWindowTestUnavailableFamily) == false)
        #expect(SettingsWindowFeature.isAvailableFamily(settingsWindowTestUnavailableFamily) == false)
        #expect(NSFont(name: settingsWindowTestUnavailableFamily, size: 13) == nil)
        #expect(SettingsWindowFeature.isAvailableFamily("") == false)
        #expect(SettingsWindowFeature.isAvailableFamily("   ") == false)
        #expect(SettingsWindowFeature.isAvailableFamily("Menlo"))
        #expect(SettingsWindowFeature.isAvailableFamily(settingsWindowTestAlternativeFamily))
    }

    @Test("A first opening shows the documented defaults: Menlo 13 and the five Command bindings")
    func aFirstOpeningShowsTheDocumentedDefaults() throws {
        let installation = try SettingsWindowTestInstallation.fresh()
        defer { installation.discard() }

        let draft = installation.feature.currentDraft()
        #expect(draft == SettingsWindowDraft())
        #expect(draft.typography == TypographySettings(fontFamily: "Menlo", pointSize: 13))
        #expect(draft.typography.fontFamily == DataStore.defaultFontFamily)
        #expect(draft.typography.pointSize == DataStore.defaultPointSize)
        #expect(draft.keybindings == KeybindingSettings.default)
        #expect(draft.keybindings.open == KeyBinding(key: "o", command: true))
        #expect(draft.keybindings.save == KeyBinding(key: "s", command: true))
        #expect(draft.keybindings.saveAs == KeyBinding(key: "s", command: true, shift: true))
        #expect(draft.keybindings.search == KeyBinding(key: "f", command: true))
        #expect(draft.keybindings.settings == KeyBinding(key: ",", command: true))

        // Opening the window changes nothing and starts idle.
        #expect(installation.feature.applyState == .idle)
        #expect(installation.feature.inlineMessage == nil)
        #expect(installation.storedSettingsKeys.isEmpty)

        // The default typography is a real font: Menlo at 13 points.
        let font = SettingsWindowFeature.resolvedFont(for: draft.typography)
        #expect(font.familyName == "Menlo")
        #expect(font.pointSize == 13)
        #expect(font == NSFont(name: "Menlo", size: 13))
    }

    // MARK: - ACC-...-01: the raw stored value follows the change

    @Test("ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-01: changing a setting writes the raw value into the dedicated suite")
    func changingASettingWritesTheRawValueIntoTheStore() throws {
        let installation = try SettingsWindowTestInstallation.fresh()
        defer { installation.discard() }
        #expect(installation.storedSettingsKeys.isEmpty)

        // The user chooses Monaco at 16 points and moves Save to Option+Cmd+K.
        let chosen = SettingsWindowDraft(
            typography: TypographySettings(
                fontFamily: settingsWindowTestAlternativeFamily,
                pointSize: 16
            ),
            keybindings: settingsWindowTestChangedKeybindings()
        )
        let result = try installation.feature.apply(chosen)

        #expect(result.accepted)
        #expect(result.inlineMessage == nil)
        #expect(result.typography == chosen.typography)
        #expect(result.keybindings == chosen.keybindings)
        #expect(installation.feature.applyState == .succeeded)
        #expect(installation.feature.lastResult == result)

        // The RAW values in the suite, not just what the store hands back.
        #expect(installation.defaults.string(forKey: DataStore.fontFamilyKey) == "Monaco")
        let rawFamily = installation.defaults.object(forKey: DataStore.fontFamilyKey)
        #expect(rawFamily is String)
        #expect(rawFamily as? String == "Monaco")
        let rawPointSize = installation.defaults.object(forKey: DataStore.pointSizeKey)
        #expect(rawPointSize is NSNumber)
        #expect((rawPointSize as? NSNumber)?.doubleValue == 16)
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 16)

        let blob = try #require(installation.storedKeybindingBlob, "The keybinding blob must be stored")
        let record = try JSONDecoder().decode(DataStore.KeybindingRecord.self, from: blob)
        #expect(record.version == DataStore.KeybindingRecord.currentVersion)
        #expect(record.saveShortcut.key == "k")
        #expect(record.saveShortcut.command)
        #expect(record.saveShortcut.option)
        #expect(record.saveShortcut.shift == false)
        #expect(record.saveShortcut.control == false)
        #expect(record.openShortcut.key == "o")
        #expect(record.saveAsShortcut.shift)

        // Typography and keybindings are the only things this window persists.
        #expect(installation.storedSettingsKeys == [
            DataStore.fontFamilyKey,
            DataStore.pointSizeKey,
            DataStore.saveKeybindingKey,
        ])

        // And the window now shows what it wrote.
        #expect(installation.feature.currentDraft() == chosen)

        // A second change updates the raw value again, without disturbing the family.
        let resized = SettingsWindowDraft(
            typography: TypographySettings(
                fontFamily: settingsWindowTestAlternativeFamily,
                pointSize: 18
            ),
            keybindings: chosen.keybindings
        )
        let second = try installation.feature.apply(resized)
        #expect(second.accepted)
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 18)
        #expect(installation.defaults.string(forKey: DataStore.fontFamilyKey) == "Monaco")
        #expect(installation.defaults.data(forKey: DataStore.saveKeybindingKey) != nil)
    }

    // MARK: - ACC-...-02: the text view font follows the choice

    @Test("ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-02: choosing a family and point size updates the text view font")
    func choosingAFamilyAndPointSizeUpdatesTheTextViewFont() throws {
        let installation = try SettingsWindowTestInstallation.fresh()
        defer { installation.discard() }
        let textView = settingsWindowTestTextView()

        // The window opens on the documented typography.
        _ = try installation.feature.apply(SettingsWindowDraft(), to: textView)
        #expect(textView.font?.familyName == "Menlo")
        #expect(textView.font?.pointSize == 13)

        // The user chooses Monaco at 16 points: the open document follows at once.
        let chosen = SettingsWindowDraft(
            typography: TypographySettings(
                fontFamily: settingsWindowTestAlternativeFamily,
                pointSize: 16
            )
        )
        let result = try installation.feature.apply(chosen, to: textView)
        #expect(result.accepted)
        #expect(result.typography == chosen.typography)

        let rendered = try #require(textView.font, "The document text view must carry a real font")
        #expect(rendered.familyName == settingsWindowTestAlternativeFamily)
        #expect(rendered.pointSize == 16)
        // The very font AppKit resolves for that family and size, not a substitute.
        let expected = try #require(NSFont(name: settingsWindowTestAlternativeFamily, size: 16))
        #expect(rendered == expected)
        #expect(rendered.fontName == expected.fontName)
        #expect(rendered.familyName != "Menlo")
        // The font the window resolves for the draft is the same one.
        let resolved = SettingsWindowFeature.resolvedFont(for: result.typography)
        #expect(resolved.familyName == settingsWindowTestAlternativeFamily)
        #expect(resolved.pointSize == 16)

        // Changing only the size moves the font to the new size, same family.
        let resized = SettingsWindowDraft(
            typography: TypographySettings(
                fontFamily: settingsWindowTestAlternativeFamily,
                pointSize: 22
            )
        )
        #expect(try installation.feature.apply(resized, to: textView).accepted)
        #expect(textView.font?.pointSize == 22)
        #expect(textView.font?.familyName == settingsWindowTestAlternativeFamily)
        #expect(SettingsWindowFeature.resolvedFont(for: resized.typography).pointSize == 22)

        // A different family renders that family.
        let back = SettingsWindowDraft(
            typography: TypographySettings(fontFamily: "Menlo", pointSize: 22)
        )
        #expect(try installation.feature.apply(back, to: textView).accepted)
        #expect(textView.font?.familyName == "Menlo")
        #expect(textView.font?.pointSize == 22)

        // The raw stored point size followed every change.
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 22)
        #expect(installation.defaults.string(forKey: DataStore.fontFamilyKey) == "Menlo")
    }

    // MARK: - ACC-...-03: an unavailable family is rejected, inline

    @Test("ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-03: an unavailable family leaves the font unchanged and shows the exact inline message")
    func anUnavailableFamilyLeavesTheFontUnchangedAndShowsTheMessage() throws {
        let installation = try SettingsWindowTestInstallation.fresh()
        defer { installation.discard() }
        let textView = settingsWindowTestTextView()

        // A first, valid choice: Monaco at 16 points, keybindings changed too.
        let chosen = SettingsWindowDraft(
            typography: TypographySettings(
                fontFamily: settingsWindowTestAlternativeFamily,
                pointSize: 16
            ),
            keybindings: settingsWindowTestChangedKeybindings()
        )
        #expect(try installation.feature.apply(chosen, to: textView).accepted)

        let fontBefore = try #require(textView.font)
        #expect(fontBefore.familyName == settingsWindowTestAlternativeFamily)
        let blobBefore = try #require(installation.storedKeybindingBlob)
        let familyBefore = try #require(installation.defaults.string(forKey: DataStore.fontFamilyKey))
        let sizeBefore = installation.defaults.double(forKey: DataStore.pointSizeKey)

        // The user picks a family this Mac does not have, together with a new size and a
        // new keybinding: the window must not half-apply it.
        var otherKeybindings = chosen.keybindings
        otherKeybindings.save = KeyBinding(key: "j", command: true, shift: true)
        let unavailable = SettingsWindowDraft(
            typography: TypographySettings(
                fontFamily: settingsWindowTestUnavailableFamily,
                pointSize: 22
            ),
            keybindings: otherKeybindings
        )

        let result = try installation.feature.apply(unavailable, to: textView)

        // Rejected, with the exact inline message (curly quotes, the chosen name).
        #expect(result.accepted == false)
        #expect(result.inlineMessage == "Font family “NoSuchFamily-MonospaceNotes” is unavailable.")
        #expect(result.inlineMessage == "Font family \u{201C}\(settingsWindowTestUnavailableFamily)\u{201D} is unavailable.")
        let message = try #require(result.inlineMessage)
        let scalars = message.unicodeScalars.map(\.value)
        #expect(scalars.contains(0x201C), "the message uses the locked left curly quote")
        #expect(scalars.contains(0x201D), "the message uses the locked right curly quote")
        #expect(scalars.contains(0x22) == false, "the message never uses a straight quote")
        #expect(message.hasPrefix("Font family "))
        #expect(message.hasSuffix(" is unavailable."))
        #expect(message.contains(settingsWindowTestUnavailableFamily))

        // The previous settings stand everywhere: the text view font is the very same
        // instance, the suite still holds the last valid values, and the window shows them.
        #expect(textView.font === fontBefore)
        #expect(textView.font?.familyName == settingsWindowTestAlternativeFamily)
        #expect(textView.font?.pointSize == 16)
        #expect(installation.defaults.string(forKey: DataStore.fontFamilyKey) == familyBefore)
        #expect(installation.defaults.string(forKey: DataStore.fontFamilyKey) == "Monaco")
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == sizeBefore)
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 16)
        #expect(installation.storedKeybindingBlob == blobBefore)
        #expect(installation.feature.typography == chosen.typography)
        #expect(installation.feature.keybindings == chosen.keybindings)
        #expect(installation.feature.currentDraft() == chosen)
        #expect(installation.feature.inlineMessage == message)
        #expect(installation.feature.applyState == .failed)
        #expect(installation.feature.lastResult?.accepted == false)

        // The window's spoken values still name the previous family and size.
        let elements = installation.feature.accessibilityElements()
        #expect(settingsWindowTestElement(elements, role: .fontFamilyPicker)?.value == "Monaco")
        #expect(settingsWindowTestElement(elements, role: .pointSizeStepper)?.value == "16 pt")

        // The recovery contract asks for an explicit retry: it works, and the window
        // reports the success it really had.
        let retried = SettingsWindowDraft(
            typography: TypographySettings(
                fontFamily: settingsWindowTestAlternativeFamily,
                pointSize: 22
            ),
            keybindings: otherKeybindings
        )
        let retryResult = try installation.feature.apply(retried, to: textView)
        #expect(retryResult.accepted)
        #expect(retryResult.inlineMessage == nil)
        #expect(installation.feature.applyState == .succeeded)
        #expect(textView.font?.pointSize == 22)
        #expect(textView.font?.familyName == settingsWindowTestAlternativeFamily)
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 22)
        #expect(installation.feature.currentDraft() == retried)
    }

    @Test("An unavailable family is rejected for every unusable name, and a blank family is never rendered")
    func everyUnusableFamilyIsRejectedWithItsOwnMessage() throws {
        let installation = try SettingsWindowTestInstallation.fresh()
        defer { installation.discard() }

        for family in [settingsWindowTestUnavailableFamily, "   ", "", "Menlo-Proportional-NoSuch"] {
            let draft = SettingsWindowDraft(
                typography: TypographySettings(fontFamily: family, pointSize: 20)
            )
            let result = try installation.feature.apply(draft)
            #expect(result.accepted == false, "\(family) cannot be rendered and must be rejected")
            #expect(result.inlineMessage == "Font family “\(family)” is unavailable.")
            #expect(result.typography == TypographySettings.default)
            #expect(result.keybindings == KeybindingSettings.default)
        }

        // Nothing was written by any of those attempts.
        #expect(installation.storedSettingsKeys.isEmpty)
        #expect(installation.feature.applyState == .failed)
    }

    // MARK: - ACC-...-04: reopening shows the chosen values

    @Test("ACC-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-04: reopening the Settings window shows the previously chosen values")
    func reopeningTheWindowShowsThePreviouslyChosenValues() throws {
        let installation = try SettingsWindowTestInstallation.fresh()
        defer { installation.discard() }

        let chosen = SettingsWindowDraft(
            typography: TypographySettings(
                fontFamily: settingsWindowTestAlternativeFamily,
                pointSize: 19
            ),
            keybindings: settingsWindowTestChangedKeybindings()
        )
        #expect(try installation.feature.apply(chosen).accepted)
        #expect(installation.feature.currentDraft() == chosen)

        // Reopening: a FRESH store and a FRESH feature over the SAME suite.
        let reopened = installation.reopening()
        #expect(reopened.store !== installation.store)
        #expect(reopened.feature !== installation.feature)
        #expect(reopened.defaults === installation.defaults)

        // The window shows what the user chose, read back from the store.
        #expect(reopened.feature.currentDraft() == chosen)
        #expect(reopened.feature.currentDraft().typography.fontFamily == settingsWindowTestAlternativeFamily)
        #expect(reopened.feature.currentDraft().typography.pointSize == 19)
        #expect(reopened.feature.currentDraft().keybindings.save == KeyBinding(key: "k", command: true, option: true))
        #expect(reopened.feature.typography == chosen.typography)
        #expect(reopened.feature.keybindings == chosen.keybindings)
        #expect(reopened.feature.applyState == .idle)
        #expect(reopened.feature.inlineMessage == nil)

        // Its controls speak the same values.
        let elements = reopened.feature.accessibilityElements()
        #expect(settingsWindowTestElement(elements, role: .fontFamilyPicker)?.value == "Monaco")
        #expect(settingsWindowTestElement(elements, role: .pointSizeStepper)?.value == "19 pt")
        let keyBindingElements = elements.filter { $0.role == .keyBindingPicker }
        #expect(keyBindingElements.count == SettingsWindowCommand.allCases.count)
        for element in keyBindingElements {
            let command = try #require(element.command)
            #expect(element.value == SettingsWindowFeature.binding(for: command, in: chosen.keybindings).displayString)
        }

        // The reopened window keeps rendering the chosen typography on the document, and
        // re-applying the values it shows is a success, not a silent repair.
        let textView = settingsWindowTestTextView()
        let reapplied = try reopened.feature.apply(reopened.feature.currentDraft(), to: textView)
        #expect(reapplied.accepted)
        #expect(textView.font?.familyName == settingsWindowTestAlternativeFamily)
        #expect(textView.font?.pointSize == 19)

        // A third opening over the same suite is identical: the choice is durable.
        let third = reopened.reopening()
        #expect(third.feature.currentDraft() == chosen)

        // A brand-new suite is a first launch again: the documented defaults.
        let firstLaunch = try SettingsWindowTestInstallation.fresh()
        defer { firstLaunch.discard() }
        #expect(firstLaunch.feature.currentDraft() == SettingsWindowDraft())
        #expect(firstLaunch.defaults.string(forKey: DataStore.fontFamilyKey) == nil)
        #expect(firstLaunch.defaults.object(forKey: DataStore.pointSizeKey) == nil)
        #expect(firstLaunch.defaults.data(forKey: DataStore.saveKeybindingKey) == nil)
    }

    // MARK: - The accessibility surface

    @Test("Every control exposes a stable label, role, value and hint, in focus order")
    func everyControlExposesStableLabelRoleValueAndHint() throws {
        let installation = try SettingsWindowTestInstallation.fresh()
        defer { installation.discard() }
        let feature = installation.feature

        let elements = feature.accessibilityElements()

        // Font family, point size, then one row per command: seven controls, in order.
        #expect(elements.count == 2 + SettingsWindowCommand.allCases.count)
        #expect(elements.map(\.role) == [
            .fontFamilyPicker,
            .pointSizeStepper,
            .keyBindingPicker, .keyBindingPicker, .keyBindingPicker,
            .keyBindingPicker, .keyBindingPicker,
        ])
        #expect(elements.map(\.identifier) == [
            "settings.fontFamily",
            "settings.pointSize",
            "settings.keyBinding.open",
            "settings.keyBinding.save",
            "settings.keyBinding.saveAs",
            "settings.keyBinding.search",
            "settings.keyBinding.settings",
        ])
        #expect(elements.map(\.label) == [
            "Font Family",
            "Point Size",
            "Open Key Binding",
            "Save Key Binding",
            "Save As Key Binding",
            "Search Key Binding",
            "Settings Key Binding",
        ])
        // The labels are stable AND distinct, so VoiceOver can tell the controls apart.
        #expect(Set(elements.map(\.label)).count == elements.count)
        #expect(Set(elements.map(\.identifier)).count == elements.count)
        #expect(elements.allSatisfy { $0.label.isEmpty == false })
        #expect(elements.allSatisfy { $0.value.isEmpty == false })
        #expect(elements.allSatisfy { $0.hint.isEmpty == false })
        // The rows carry their command, and the two typography controls carry none.
        #expect(elements.compactMap(\.command) == SettingsWindowCommand.allCases)
        #expect(elements.prefix(2).allSatisfy { $0.command == nil })

        // The spoken hints say how to operate each control from the keyboard.
        let fontFamily = try #require(settingsWindowTestElement(elements, role: .fontFamilyPicker))
        let pointSize = try #require(settingsWindowTestElement(elements, role: .pointSizeStepper))
        #expect(fontFamily.hint.contains("arrow keys"))
        #expect(pointSize.hint.contains("arrow keys"))
        #expect(pointSize.hint.contains("point size"))
        for element in elements.filter({ $0.role == .keyBindingPicker }) {
            let command = try #require(element.command)
            #expect(element.label.hasPrefix(command.displayName))
            #expect(element.hint.contains(command.displayName))
            #expect(element.hint.contains("arrow keys"))
        }

        // The values are live: a draft's values come out, the settings in effect come out,
        // and the documented defaults are what a first opening speaks.
        #expect(fontFamily.value == "Menlo")
        #expect(pointSize.value == "13 pt")
        #expect(elements.suffix(5).map(\.value) == ["⌘O", "⌘S", "⇧⌘S", "⌘F", "⌘,"])

        let changed = SettingsWindowDraft(
            typography: TypographySettings(
                fontFamily: settingsWindowTestAlternativeFamily,
                pointSize: 16
            ),
            keybindings: settingsWindowTestChangedKeybindings()
        )
        let changedElements = feature.accessibilityElements(for: changed)
        #expect(settingsWindowTestElement(changedElements, role: .fontFamilyPicker)?.value == "Monaco")
        #expect(settingsWindowTestElement(changedElements, role: .pointSizeStepper)?.value == "16 pt")
        #expect(changedElements.first { $0.command == .save }?.value == "⌥⌘K")
        #expect(changedElements.first { $0.command == .open }?.value == "⌘O")
        // The identifiers and labels do not move when the values do.
        #expect(changedElements.map(\.identifier) == elements.map(\.identifier))
        #expect(changedElements.map(\.label) == elements.map(\.label))

        // After a real change the window's own spoken values follow it.
        #expect(try feature.apply(changed).accepted)
        let spoken = feature.accessibilityElements()
        #expect(settingsWindowTestElement(spoken, role: .fontFamilyPicker)?.value == "Monaco")
        #expect(settingsWindowTestElement(spoken, role: .pointSizeStepper)?.value == "16 pt")
        #expect(spoken.first { $0.command == .save }?.value == "⌥⌘K")

        // The same controls, grouped the way the window lays them out.
        let controls = feature.controls()
        #expect(controls.all == spoken)
        #expect(controls.fontFamily == spoken[0])
        #expect(controls.pointSize == spoken[1])
        #expect(controls.keyBindings == Array(spoken.dropFirst(2)))
        #expect(controls.keyBindings.count == SettingsWindowCommand.allCases.count)
        let forDraft = feature.controls(for: changed)
        #expect(forDraft.all == changedElements)
        #expect(forDraft.fontFamily.value == "Monaco")
        #expect(forDraft.pointSize.value == "16 pt")
        #expect(forDraft.keyBindings.first?.command == .open)
        #expect(forDraft.keyBindings.last?.command == .settings)

        // Every keybinding row offers the binding in effect among its choices, so the
        // keyboard path can always leave the assignment as it is.
        for element in spoken {
            guard let command = element.command else { continue }
            let current = SettingsWindowFeature.binding(for: command, in: feature.keybindings)
            let choices = SettingsWindowFeature.keyBindingChoices(for: command, current: current)
            #expect(choices.contains(current))
            #expect(choices.first == current)
            #expect(choices.count >= SettingsWindowCommand.allCases.count)
        }

        // A point size in spoken form is the documented shape.
        #expect(SettingsWindowFeature.pointSizeValueText(13) == "13 pt")
        #expect(SettingsWindowFeature.pointSizeValueText(16) == "16 pt")
        #expect(SettingsWindowFeature.pointSizeRange.contains(DataStore.defaultPointSize))
    }

    @Test("The SettingsView carries those labels, values and hints into every control (structural proof)")
    func theSettingsViewCarriesTheAccessibilityContractIntoEveryControl() throws {
        let source = try settingsWindowTestSourceText()

        // The window is a SwiftUI `View` with a picker, a stepper and one row per command,
        // all rendered from the feature's accessibility elements.
        #expect(source.contains("struct SettingsView: View"))
        #expect(source.contains("Picker("))
        #expect(source.contains("Stepper("))
        #expect(source.contains("ForEach(controls.keyBindings)"))
        #expect(source.contains("feature.controls(for: draft)"))
        #expect(source.contains("accessibilityElements()"))
        #expect(source.contains("accessibilityElements(for:"))
        #expect(source.contains("controls.fontFamily.label"))
        #expect(source.contains("controls.fontFamily.value"))
        #expect(source.contains("controls.fontFamily.hint"))
        #expect(source.contains("controls.fontFamily.identifier"))
        #expect(source.contains("controls.pointSize.label"))
        #expect(source.contains("controls.pointSize.value"))
        #expect(source.contains("controls.pointSize.hint"))
        #expect(source.contains("controls.pointSize.identifier"))

        // Every control carries a label, a value, a hint and an identifier.
        for modifier in [
            ".accessibilityLabel(",
            ".accessibilityValue(",
            ".accessibilityHint(",
            ".accessibilityIdentifier(",
        ] {
            #expect(source.contains(modifier), "the window must apply \(modifier)")
        }
        #expect(source.contains("Accessibility.inlineMessageIdentifier"))
        #expect(source.contains("Accessibility.inlineMessageLabel"))

        // The window can be built the way the composition root builds it.
        let installation = try SettingsWindowTestInstallation.fresh()
        defer { installation.discard() }
        let textView = settingsWindowTestTextView()
        var applied: [SettingsWindowResult] = []
        let view = SettingsView(
            feature: installation.feature,
            documentTextView: { textView },
            onApply: { applied.append($0) }
        )
        _ = view
        #expect(SettingsView.title == "Settings")
        #expect(SettingsView.typographySectionTitle == "Typography")
        #expect(SettingsView.keyBindingsSectionTitle == "Keybindings")
        // The window renders the locked background and a foreground that clears the
        // contrast floor, both reused from the appearance owner.
        let windowBackground = try #require(
            DarkMonochromaticWindowAppearanceFeature.RGB.from(SettingsView.backgroundColor)
        )
        #expect(windowBackground == DarkMonochromaticWindowAppearanceFeature.backgroundColor)
        #expect(windowBackground.hexString == DarkMonochromaticWindowAppearanceFeature.backgroundHex)
        #expect(windowBackground.hexString == "#000000")
        let windowText = try #require(
            DarkMonochromaticWindowAppearanceFeature.RGB.from(SettingsView.textColor)
        )
        #expect(
            DarkMonochromaticWindowAppearanceFeature.contrastRatio(windowText, against: windowBackground)
                >= DarkMonochromaticWindowAppearanceFeature.minimumContrastRatio
        )
    }

    // MARK: - Recovery: refusals and cancellations

    @Test("A store that refuses the write throws, publishes nothing, and reports the reason inline")
    func aRefusingStoreLeavesTheLastValidStateAndNeverClaimsSuccess() throws {
        let refusal = DataStore.OperationError.invalidTypography("the settings store refused the write")
        let store = SettingsWindowTestRecordingStore(
            loadedTypography: TypographySettings(
                fontFamily: settingsWindowTestAlternativeFamily,
                pointSize: 16
            ),
            loadedKeybindings: settingsWindowTestChangedKeybindings(),
            refusal: refusal
        )
        let feature = SettingsWindowFeature(store: store)

        #expect(feature.currentDraft().typography == TypographySettings(
            fontFamily: settingsWindowTestAlternativeFamily,
            pointSize: 16
        ))

        let textView = settingsWindowTestTextView()
        textView.font = SettingsWindowFeature.resolvedFont(for: feature.currentDraft().typography)
        let fontBefore = try #require(textView.font)

        let thrown = settingsWindowTestThrownError {
            _ = try feature.apply(
                SettingsWindowDraft(typography: TypographySettings(fontFamily: "Menlo", pointSize: 20)),
                to: textView
            )
        }
        #expect(thrown as? DataStore.OperationError == refusal)
        #expect(store.recordedTypographyWrites == 0)
        #expect(store.recordedKeybindingWrites == 0)
        #expect(feature.applyState == .failed)
        #expect(feature.typography.pointSize == 16)
        #expect(feature.keybindings == settingsWindowTestChangedKeybindings())
        #expect(textView.font === fontBefore)

        let message = try #require(feature.inlineMessage, "a refusal is explained inline")
        #expect(message.contains("refused"))
        #expect(message.contains("unchanged"))
        #expect(feature.lastResult?.accepted == false)
        #expect(feature.lastResult?.inlineMessage == message)
        #expect(feature.lastResult?.typography == feature.typography)
    }

    @Test("A cancelled change writes nothing, publishes nothing, and keeps the last valid state")
    func aCancelledChangeWritesNothingAndKeepsTheLastValidState() async throws {
        let installation = try SettingsWindowTestInstallation.fresh()
        defer { installation.discard() }
        let feature = installation.feature
        let textView = settingsWindowTestTextView()
        #expect(try feature.apply(SettingsWindowDraft(), to: textView).accepted)
        let fontBefore = try #require(textView.font)
        let keysBefore = installation.storedSettingsKeys
        #expect(keysBefore.isEmpty == false)

        // Save the cancellation flag on the way in, so the next state check cannot race it.
        let outcome = await settingsWindowTestRunCancelled {
            _ = try feature.apply(
                SettingsWindowDraft(
                    typography: TypographySettings(
                        fontFamily: settingsWindowTestAlternativeFamily,
                        pointSize: 16
                    )
                ),
                to: textView
            )
        }
        #expect(outcome == .threwCancellationError)
        #expect(feature.applyState == .cancelled)
        #expect(feature.typography == TypographySettings.default)
        #expect(feature.keybindings == KeybindingSettings.default)
        #expect(textView.font === fontBefore)
        // Nothing was written by the cancelled change: the suite still holds exactly the
        // values the accepted change put there.
        #expect(installation.storedSettingsKeys == keysBefore)
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 13)
        #expect(installation.defaults.string(forKey: DataStore.fontFamilyKey) == "Menlo")
        let message = try #require(feature.inlineMessage)
        #expect(message.contains("cancelled"))
        #expect(feature.lastResult?.accepted == false)

        // The same call from a live task applies normally: the difference is the
        // cancellation, not the write path.
        #expect(try feature.apply(
            SettingsWindowDraft(
                typography: TypographySettings(
                    fontFamily: settingsWindowTestAlternativeFamily,
                    pointSize: 16
                )
            ),
            to: textView
        ).accepted)
        #expect(feature.applyState == .succeeded)
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 16)
        #expect(textView.font?.familyName == settingsWindowTestAlternativeFamily)
    }

    // MARK: - Recovery: the stored values the window opens on

    @Test("An invalid stored value falls back through the store's documented defaults, and an explicit retry repairs it")
    func invalidStoredValuesFallBackWithoutFailingTheWindow() throws {
        let installation = try SettingsWindowTestInstallation.fresh { defaults in
            defaults.set("sixteen", forKey: DataStore.pointSizeKey)
            defaults.set(3.0, forKey: DataStore.fontFamilyKey)
            defaults.set(Data("not a keybinding record".utf8), forKey: DataStore.saveKeybindingKey)
        }
        defer { installation.discard() }
        let feature = installation.feature

        // The window opens on the documented defaults instead of failing to open.
        let draft = feature.currentDraft()
        #expect(draft.typography == TypographySettings(fontFamily: "Menlo", pointSize: 13))
        #expect(draft.keybindings == KeybindingSettings.default)
        #expect(feature.applyState == .idle)
        #expect(feature.inlineMessage == nil)
        #expect(SettingsWindowFeature.resolvedFont(for: draft.typography).familyName == "Menlo")
        #expect(SettingsWindowFeature.resolvedFont(for: draft.typography).pointSize == 13)

        // The invalid stored values are left exactly as they were until the user changes
        // something: the window never silently repairs the store behind their back.
        #expect(installation.defaults.string(forKey: DataStore.pointSizeKey) == "sixteen")
        #expect(installation.defaults.data(forKey: DataStore.saveKeybindingKey) == Data("not a keybinding record".utf8))

        // An explicit retry with usable values writes them.
        let repaired = SettingsWindowDraft(
            typography: TypographySettings(
                fontFamily: settingsWindowTestAlternativeFamily,
                pointSize: 15
            )
        )
        #expect(try feature.apply(repaired).accepted)
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 15)
        #expect(installation.defaults.string(forKey: DataStore.fontFamilyKey) == "Monaco")
        #expect(installation.reopening().feature.currentDraft().typography == repaired.typography)
    }

    @Test("A stored point size the store rejects is replaced by the documented one through the gate")
    func anUnstorablePointSizeIsRejectedByTheStoreAndKeepsTheLastValidState() throws {
        let installation = try SettingsWindowTestInstallation.fresh()
        defer { installation.discard() }
        let feature = installation.feature
        #expect(try feature.apply(SettingsWindowDraft(
            typography: TypographySettings(fontFamily: "Menlo", pointSize: 16)
        )).accepted)

        // The store owns the point size rule; a draft that breaks it is refused and the
        // last valid size stands, stored and on screen.
        let thrown = settingsWindowTestThrownError {
            _ = try feature.apply(SettingsWindowDraft(
                typography: TypographySettings(fontFamily: "Menlo", pointSize: 0)
            ))
        }
        #expect(thrown as? DataStore.OperationError != nil)
        #expect(feature.applyState == .failed)
        #expect(feature.typography.pointSize == 16)
        #expect(installation.defaults.double(forKey: DataStore.pointSizeKey) == 16)
        let message = try #require(feature.inlineMessage)
        #expect(message.contains("point size"))
        #expect(message.contains("unchanged"))
    }

    // MARK: - Boundaries

    @Test("The feature issues no network request and performs no file I/O (structural proof)")
    func theFeatureIsFreeOfNetworkAndFileIO() throws {
        let source = try settingsWindowTestSourceText()

        for token in [
            "import Network", "URLSession", "NSURLConnection", "NSURLRequest",
            "CFNetwork", "NWConnection",
        ] {
            #expect(source.contains(token) == false, "the source must not contain \(token)")
        }
        for token in [
            "FileManager", "FileHandle", "Data(contentsOf:", "write(to:",
            "URL(fileURLWithPath:", "NSTemporaryDirectory", "runModal", "NSAlert",
        ] {
            #expect(source.contains(token) == false, "the source must not contain \(token)")
        }

        #expect(source.contains("import AppKit"))
        #expect(source.contains("import SwiftUI"))
        // The only persistence the window holds is the settings store: it has no note-file
        // access at all, so a settings change can never touch a note.
        #expect(source.contains("any SettingsStoring"))
        #expect(source.contains("any NoteFileAccess") == false)
        #expect(source.contains("UserDefaults.standard") == false)
    }
}
