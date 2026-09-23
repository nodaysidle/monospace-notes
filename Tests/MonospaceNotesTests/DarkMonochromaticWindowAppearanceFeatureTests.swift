//
//  DarkMonochromaticWindowAppearanceFeatureTests.swift
//  MonospaceNotesTests
//
//  TASK-05-DARK-MONOCHROMATIC-WINDOW-APPEARANCE focused suite — owner
//  OWN-DARK-MONOCHROMATIC-WINDOW-APPEARANCE.
//
//  Covers FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE and its two contracts
//  against the real `DarkMonochromaticWindowAppearanceFeature`:
//
//    * ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-01 — if the configured
//      foreground colour fails the contrast check, the RENDERED foreground
//      colour passes it: a deliberately failing mid-grey is substituted and the
//      colour read back from a real `NSTextView` is re-measured against the
//      colour read back from the same view's background.
//    * ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-02 — the text foreground clears
//      7:1 against #000000, computed with the real WCAG relative-luminance
//      formula `(L_lighter + 0.05) / (L_darker + 0.05)`. The formula is checked
//      against published WCAG reference values (white on #000000 is 21:1, pure
//      blue 2.444:1, pure red 5.252:1, pure green 15.304:1, a colour against
//      itself 1:1) and against an independent implementation of the same two
//      formulas written in this file, so the numbers do not only agree with
//      themselves.
//    * ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-03 — the text view uses the
//      configured monospace family and point size (Menlo 13 by default): the
//      family and size are asserted on a real `NSFont` and on the font read back
//      from a real `NSTextView`, and monospacedness is measured from glyph
//      advances (true for Menlo and Courier New, false for Helvetica and Arial).
//    * ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-04 — the window background
//      equals #000000: asserted through `backgroundHex`, the RGB triple, and the
//      background read back from a real `NSWindow` and a real `NSTextView`.
//
//  RECOVERY: the application is represented as idle / active / succeeded /
//  failed / cancelled; a failure or a cancellation publishes nothing, restores
//  the surface to the last valid appearance, produces no modal alert (the colour
//  fallback is automatic and requires no user retry), and the configuration step
//  runs exactly once per attempt — a retry is an explicit call, never automatic.
//
//  This suite constructs AppKit objects, so it is `.serialized`: its tests run
//  one at a time instead of flooding the main actor of a parallel run. No
//  assertion depends on serialization, and no test asserts on wall-clock timing.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import AppKit
import Foundation
import Testing

@testable import MonospaceNotes

/// Shorthand for the type under test; file-private, so no other test file can
/// collide with it.
private typealias DarkMono = DarkMonochromaticWindowAppearanceFeature

// MARK: - File-scope fixtures (unique names: every test file compiles together)

/// A `SettingsStoring` stand-in that returns fixed typography and counts the
/// reads, so "the appearance really came from the persisted settings" is
/// observable without touching the user's real defaults domain.
private final class DarkMonochromaticFakeSettingsStore: SettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var typography: TypographySettings
    private var typographyLoads = 0

    init(typography: TypographySettings = .default) {
        self.typography = typography
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
        typography = settings
    }

    func loadKeybindings() -> KeybindingSettings { .default }

    func storeKeybindings(_ settings: KeybindingSettings) throws {}

    var typographyLoadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return typographyLoads
    }
}

/// Records what the injected configuration step saw, so "the application was
/// active while the surface was configured" and "the configuration ran exactly
/// once per attempt" are assertable. `needsScriptedFailure()` makes one chosen
/// attempt report a failure, so the failure branch and the explicit retry are
/// both exercised on real surfaces.
private final class DarkMonochromaticConfigurationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observedStates: [OperationState] = []
    private let failureAttempt: Int?

    /// - Parameter failureAttempt: the 1-based attempt whose configuration step
    ///   must report a failure after partially applying the appearance. `nil`
    ///   never fails.
    init(failureAttempt: Int? = nil) {
        self.failureAttempt = failureAttempt
    }

    func note(_ state: OperationState) {
        lock.lock()
        defer { lock.unlock() }
        observedStates.append(state)
    }

    /// `true` when the attempt whose state was just noted must report a scripted
    /// failure.
    func needsScriptedFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return failureAttempt == observedStates.count
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return observedStates.count
    }

    var stateDuringConfiguration: OperationState? {
        lock.lock()
        defer { lock.unlock() }
        return observedStates.first
    }
}

/// Holds the feature the injected configuration step runs inside, so the
/// cancellation and active-state assertions need no global state.
private final class DarkMonochromaticFeatureBox: @unchecked Sendable {
    var feature: DarkMonochromaticWindowAppearanceFeature?
}

/// A real TextKit 2 document text view, never shown.
@MainActor
private func darkMonochromaticTextView(editable: Bool = true, text: String = "") -> NSTextView {
    _ = NSApplication.shared
    let textView = NSTextView(usingTextLayoutManager: true)
    textView.isEditable = editable
    textView.isSelectable = true
    textView.isRichText = false
    textView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
    textView.string = text
    return textView
}

/// Builds a colour through the feature's own `RGB` type, with the channel values
/// spelled out by the caller.
private func darkMonoRGB(_ r: Double, _ g: Double, _ b: Double) -> DarkMono.RGB {
    DarkMono.RGB(r: r, g: g, b: b)
}

/// The WCAG reference formulas, implemented here independently of the feature so
/// the feature's numbers can be checked against the standard (and against the
/// published reference values asserted in the suite) rather than only against
/// themselves.
private func darkMonoReferenceLuminance(_ color: DarkMono.RGB) -> Double {
    func linearised(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearised(color.r) + 0.7152 * linearised(color.g) + 0.0722 * linearised(color.b)
}

private func darkMonoReferenceContrast(_ first: DarkMono.RGB, _ second: DarkMono.RGB) -> Double {
    let a = darkMonoReferenceLuminance(first)
    let b = darkMonoReferenceLuminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

// MARK: - Suite

@Suite("FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE dark monochromatic appearance", .serialized)
@MainActor
struct DarkMonochromaticWindowAppearanceFeatureTests {

    /// The deliberately failing configured foreground used by the substitution
    /// tests: #808080, which measures about 5.32:1 against #000000.
    private var failingMidGrey: DarkMono.RGB {
        darkMonoRGB(128.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
    }

    // MARK: - Locked constants

    @Test("The locked appearance constants are the contract values")
    func lockedConstants() throws {
        #expect(DarkMono.backgroundHex == "#000000")
        #expect(DarkMono.backgroundColor == darkMonoRGB(0, 0, 0))
        #expect(DarkMono.backgroundColor.r == 0)
        #expect(DarkMono.backgroundColor.g == 0)
        #expect(DarkMono.backgroundColor.b == 0)
        #expect(DarkMono.minimumContrastRatio == 7)
        #expect(DarkMono.preferredForeground == darkMonoRGB(1, 1, 1))

        // The locked hex form and the RGB triple describe the same colour.
        let parsed = try #require(DarkMono.RGB.fromHex(DarkMono.backgroundHex))
        #expect(parsed == DarkMono.backgroundColor)
        #expect(DarkMono.backgroundColor.hexString == "#000000")
        #expect(DarkMono.backgroundHex.uppercased() == DarkMono.backgroundHex)
        #expect(DarkMono.backgroundColor.eightBitChannels.r == 0)
        #expect(DarkMono.backgroundColor.eightBitChannels.g == 0)
        #expect(DarkMono.backgroundColor.eightBitChannels.b == 0)
    }

    // MARK: - ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-02: the real WCAG formula

    @Test("contrastRatio is the real WCAG formula: published reference values")
    func contrastRatioMatchesPublishedWcagReferenceValues() {
        let black = DarkMono.backgroundColor
        let white = darkMonoRGB(1, 1, 1)
        let blue = darkMonoRGB(0, 0, 1)
        let red = darkMonoRGB(1, 0, 0)
        let green = darkMonoRGB(0, 1, 0)

        // WCAG relative luminance: 0.2126 R + 0.7152 G + 0.0722 B over the
        // linearised channels — not a plain channel average.
        #expect(abs(DarkMono.relativeLuminance(white) - 1.0) < 1e-12)
        #expect(abs(DarkMono.relativeLuminance(black) - 0.0) < 1e-12)
        #expect(abs(DarkMono.relativeLuminance(red) - 0.2126) < 1e-12)
        #expect(abs(DarkMono.relativeLuminance(green) - 0.7152) < 1e-12)
        #expect(abs(DarkMono.relativeLuminance(blue) - 0.0722) < 1e-12)

        // The ratios the WCAG contrast tables publish against #000000.
        #expect(abs(DarkMono.contrastRatio(white, against: black) - 21.0) < 1e-9)
        #expect(abs(DarkMono.contrastRatio(black, against: black) - 1.0) < 1e-12)
        #expect(abs(DarkMono.contrastRatio(blue, against: black) - 2.4440) < 0.0001)
        #expect(abs(DarkMono.contrastRatio(red, against: black) - 5.2520) < 0.0001)
        #expect(abs(DarkMono.contrastRatio(green, against: black) - 15.3040) < 0.0001)
        #expect(abs(DarkMono.contrastRatio(failingMidGrey, against: black) - 5.3172) < 0.0001)

        // The same numbers come out of the independent implementation in this
        // file, for every pair above.
        for colour in [white, black, blue, red, green, failingMidGrey] {
            #expect(
                abs(DarkMono.contrastRatio(colour, against: black)
                    - darkMonoReferenceContrast(colour, black)) < 1e-12
            )
        }
    }

    @Test("contrastRatio ignores the argument order and bottoms out at 1:1")
    func contrastRatioIsOrderIndependent() {
        #expect(DarkMono.contrastRatio(failingMidGrey, against: DarkMono.backgroundColor)
                == DarkMono.contrastRatio(DarkMono.backgroundColor, against: failingMidGrey))
        #expect(DarkMono.contrastRatio(failingMidGrey, against: failingMidGrey) == 1.0)
        #expect(DarkMono.contrastRatio(DarkMono.backgroundColor, against: DarkMono.backgroundColor) == 1.0)

        // A light foreground against the black background is always at least the
        // floor; the floor itself is the locked 7:1, not the WCAG AAA 7/4.5 mix.
        #expect(DarkMono.minimumContrastRatio == 7)
        #expect(DarkMono.contrastRatio(darkMonoRGB(1, 1, 1), against: DarkMono.backgroundColor) >= 7)
    }

    // MARK: - ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-04: #000000 background

    @Test("ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-04: the window background equals #000000")
    func windowBackgroundEqualsBlack() throws {
        let feature = DarkMonochromaticWindowAppearanceFeature(
            settings: DarkMonochromaticFakeSettingsStore()
        )

        // A real window, never ordered on screen.
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        let appearance = feature.applyToWindow(window, typography: .default)

        // The colour the window really renders.
        let rendered = try #require(
            DarkMono.RGB.from(window.backgroundColor),
            "the window background is not an sRGB colour"
        )
        #expect(rendered == DarkMono.backgroundColor)
        #expect(rendered.hexString == "#000000")
        #expect(rendered.r == 0)
        #expect(rendered.g == 0)
        #expect(rendered.b == 0)
        #expect(window.backgroundColor.usingColorSpace(.sRGB)?.redComponent == 0)
        #expect(window.backgroundColor.usingColorSpace(.sRGB)?.greenComponent == 0)
        #expect(window.backgroundColor.usingColorSpace(.sRGB)?.blueComponent == 0)
        #expect(window.appearance?.name == NSAppearance.Name.darkAqua,
                "the window chrome must not fight the black document surface")

        // The value side reports the same locked background.
        #expect(appearance.backgroundHex == "#000000")
        #expect(appearance.background == darkMonoRGB(0, 0, 0))
        #expect(appearance.background.eightBitChannels == (r: 0, g: 0, b: 0))
        #expect(feature.appearanceState == .succeeded)
        #expect(feature.lastAppliedAppearance == appearance)

        // The document surface is black too: no white text area is left inside
        // the black window.
        let textView = darkMonochromaticTextView(text: "note")
        let outcome = feature.apply(to: textView, typography: .default)
        #expect(outcome.state == .succeeded)
        #expect(textView.drawsBackground, "a text view that does not draw its background shows the default white")
        let surfaceBackground = try #require(DarkMono.RGB.from(textView.backgroundColor))
        #expect(surfaceBackground == DarkMono.backgroundColor)
        #expect(surfaceBackground.hexString == "#000000")
    }

    // MARK: - ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-02: 7:1 foreground

    @Test("ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-02: the text foreground clears 7:1 against #000000")
    func defaultForegroundClearsSevenToOne() {
        let black = DarkMono.backgroundColor
        let measured = DarkMono.contrastRatio(DarkMono.preferredForeground, against: black)
        print("ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-02: preferred foreground "
              + "\(DarkMono.preferredForeground.hexString) against #000000 = "
              + "\(measured):1 (floor \(DarkMono.minimumContrastRatio):1)")

        #expect(measured >= DarkMono.minimumContrastRatio)
        #expect(abs(measured - 21.0) < 1e-9, "white on #000000 is the maximum 21:1")
        #expect(abs(measured - darkMonoReferenceContrast(DarkMono.preferredForeground, black)) < 1e-12)

        // A foreground that already passes is rendered exactly as configured.
        #expect(DarkMono.foregroundColor(preferred: DarkMono.preferredForeground) == DarkMono.preferredForeground)
        let lightGrey = darkMonoRGB(224.0 / 255.0, 224.0 / 255.0, 224.0 / 255.0)
        let lightGreyRatio = DarkMono.contrastRatio(lightGrey, against: black)
        #expect(lightGreyRatio >= DarkMono.minimumContrastRatio)
        #expect(DarkMono.foregroundColor(preferred: lightGrey) == lightGrey)
        #expect(abs(lightGreyRatio - 15.9081) < 0.0001)

        // The appearance the surface renders carries the same measured ratio and
        // no substitution.
        let feature = DarkMonochromaticWindowAppearanceFeature(
            settings: DarkMonochromaticFakeSettingsStore()
        )
        let appearance = feature.resolve(typography: .default)
        #expect(appearance.foreground == DarkMono.preferredForeground)
        #expect(appearance.contrastRatio == measured)
        #expect(appearance.contrastRatio >= DarkMono.minimumContrastRatio)
        #expect(appearance.substitutedForeground == false)
        #expect(appearance.backgroundHex == "#000000")
        #expect(appearance.foregroundHex == DarkMono.preferredForeground.hexString)
    }

    // MARK: - ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-01: substitution

    @Test("ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-01: a configured foreground that fails is substituted")
    func failingConfiguredForegroundIsSubstituted() {
        let black = DarkMono.backgroundColor
        let configured = DarkMono.contrastRatio(failingMidGrey, against: black)
        print("ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-01: configured mid-grey "
              + "\(failingMidGrey.hexString) against #000000 = \(configured):1 — fails the "
              + "\(DarkMono.minimumContrastRatio):1 floor")

        #expect(configured < DarkMono.minimumContrastRatio,
                "the test's configured colour must really fail, or the branch is not exercised")
        #expect(abs(configured - 5.3172) < 0.0001)

        let substituted = DarkMono.foregroundColor(preferred: failingMidGrey)
        let measured = DarkMono.contrastRatio(substituted, against: black)
        print("ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-01: substituted color "
              + "\(substituted.hexString) against #000000 = \(measured):1 (floor "
              + "\(DarkMono.minimumContrastRatio):1)")

        #expect(substituted != failingMidGrey, "a failing colour must not be rendered as configured")
        #expect(measured >= DarkMono.minimumContrastRatio)
        #expect(abs(measured - darkMonoReferenceContrast(substituted, black)) < 1e-12)

        // The substitution lifts the configured colour toward white instead of
        // replacing it with an unrelated colour: a grey stays a neutral grey.
        #expect(substituted.r == substituted.g)
        #expect(substituted.g == substituted.b)
        #expect(substituted.r > failingMidGrey.r)

        // The resolved appearance reports the substitution and the measured ratio.
        let feature = DarkMonochromaticWindowAppearanceFeature(
            settings: DarkMonochromaticFakeSettingsStore()
        )
        let appearance = feature.resolve(typography: .default, preferredForeground: failingMidGrey)
        #expect(appearance.substitutedForeground)
        #expect(appearance.foreground == substituted)
        #expect(appearance.foregroundHex == substituted.hexString)
        #expect(appearance.contrastRatio >= DarkMono.minimumContrastRatio)
        #expect(appearance.backgroundHex == "#000000")

        // The substitution is not a grey-only special case: a dark coloured
        // foreground is lifted too, and the deepest possible foreground (black)
        // still comes back passing.
        let darkBlue = darkMonoRGB(0, 0, 128.0 / 255.0)
        #expect(DarkMono.contrastRatio(darkBlue, against: black) < DarkMono.minimumContrastRatio)
        let liftedBlue = DarkMono.foregroundColor(preferred: darkBlue)
        #expect(DarkMono.contrastRatio(liftedBlue, against: black) >= DarkMono.minimumContrastRatio)
        #expect(liftedBlue.b >= darkBlue.b, "the lift keeps the configured colour's channel order")

        let deepest = DarkMono.foregroundColor(preferred: darkMonoRGB(0, 0, 0))
        #expect(deepest != darkMonoRGB(0, 0, 0))
        #expect(DarkMono.contrastRatio(deepest, against: black) >= DarkMono.minimumContrastRatio)

        // The final fallback always passes, whatever the bisection did.
        #expect(DarkMono.contrastRatio(DarkMono.preferredForeground, against: black) >= DarkMono.minimumContrastRatio)
    }

    @Test("ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-01: the rendered text view foreground passes")
    func renderedForegroundClearsTheFloor() throws {
        let feature = DarkMonochromaticWindowAppearanceFeature(
            settings: DarkMonochromaticFakeSettingsStore()
        )
        let textView = darkMonochromaticTextView(text: "note")

        let outcome = feature.apply(
            to: textView,
            typography: .default,
            preferredForeground: failingMidGrey
        )
        #expect(outcome.state == .succeeded,
                "the substitution is automatic, so a failing configured colour does not fail the surface")

        let renderedColor = try #require(textView.textColor, "the surface has no text colour")
        let rendered = try #require(DarkMono.RGB.from(renderedColor))
        let background = try #require(DarkMono.RGB.from(textView.backgroundColor))
        let measured = DarkMono.contrastRatio(rendered, against: background)
        print("ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-01: rendered text colour "
              + "\(rendered.hexString) on \(background.hexString) = \(measured):1 (floor "
              + "\(DarkMono.minimumContrastRatio):1)")

        #expect(background == DarkMono.backgroundColor)
        #expect(rendered != failingMidGrey)
        #expect(measured >= DarkMono.minimumContrastRatio)
        #expect(outcome.appearance?.foreground == rendered)
        #expect(outcome.appearance?.substitutedForeground == true)
        #expect(outcome.appearance?.contrastRatio == measured)
        #expect(outcome.statusMessage == nil, "an automatic fallback is not reported as a problem")
        #expect(outcome.errorAlert == nil)

        // The insertion point uses the same passing foreground.
        #expect(DarkMono.RGB.from(textView.insertionPointColor) == rendered)
    }

    // MARK: - ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-03: monospace font

    @Test("ACC-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-03: the text view uses the configured monospace font")
    func textViewUsesConfiguredFont() throws {
        let feature = DarkMonochromaticWindowAppearanceFeature(
            settings: DarkMonochromaticFakeSettingsStore()
        )

        // A real NSFont for the configured Menlo 13.
        let menlo = DarkMono.resolvedFont(family: "Menlo", pointSize: 13)
        #expect(menlo.familyName == "Menlo")
        #expect(menlo.pointSize == 13)
        #expect(DarkMono.isMonospace(menlo))

        // The default typography reaches a real text view unchanged.
        let textView = darkMonochromaticTextView()
        let outcome = feature.apply(to: textView, typography: .default)
        #expect(outcome.state == .succeeded)
        let renderedFont = try #require(textView.font, "the document surface has no font")
        #expect(renderedFont.familyName == TypographySettings.default.fontFamily)
        #expect(renderedFont.familyName == "Menlo")
        #expect(renderedFont.pointSize == 13)
        #expect(Double(renderedFont.pointSize) == TypographySettings.default.pointSize)
        #expect(DarkMono.isMonospace(renderedFont))
        #expect(outcome.appearance?.fontFamily == "Menlo")
        #expect(outcome.appearance?.pointSize == 13)
        #expect(outcome.appearance?.fontIsMonospace == true)

        // A different configured family and size reaches the surface as well, so
        // the font is really driven by the setting and not hard-coded.
        let configured = TypographySettings(fontFamily: "Courier New", pointSize: 16)
        let secondView = darkMonochromaticTextView()
        let secondOutcome = feature.apply(to: secondView, typography: configured)
        #expect(secondOutcome.state == .succeeded)
        let secondFont = try #require(secondView.font)
        #expect(secondFont.familyName == "Courier New")
        #expect(secondFont.pointSize == 16)
        #expect(DarkMono.isMonospace(secondFont))
        #expect(secondOutcome.appearance?.fontFamily == configured.fontFamily)
        #expect(secondOutcome.appearance?.pointSize == configured.pointSize)
        #expect(secondFont.pointSize != renderedFont.pointSize)

        // Monospacedness is measured, not trusted: a known proportional face is
        // reported as proportional.
        let proportional = try #require(NSFont(name: "Helvetica", size: 13))
        #expect(proportional.familyName == "Helvetica")
        #expect(DarkMono.isMonospace(proportional) == false)
        let alsoProportional = try #require(NSFont(name: "Arial", size: 13))
        #expect(DarkMono.isMonospace(alsoProportional) == false)
        #expect(DarkMono.isMonospace(DarkMono.resolvedFont(family: "Courier New", pointSize: 13)))
    }

    @Test("The configured typography comes from the settings store")
    func configuredTypographyComesFromTheStore() {
        let store = DarkMonochromaticFakeSettingsStore(
            typography: TypographySettings(fontFamily: "Courier New", pointSize: 16)
        )
        let feature = DarkMonochromaticWindowAppearanceFeature(settings: store)

        let appearance = feature.resolvePersistedAppearance()

        #expect(store.typographyLoadCount == 1, "the resolution read the persisted typography exactly once")
        #expect(appearance.fontFamily == "Courier New")
        #expect(appearance.pointSize == 16)
        #expect(appearance.font.familyName == "Courier New")
        #expect(appearance.font.pointSize == 16)
        #expect(appearance.backgroundHex == "#000000")
        #expect(appearance.contrastRatio >= DarkMono.minimumContrastRatio)
    }

    @Test("An unavailable family falls back to a monospace face at the configured size")
    func unavailableFamilyFallsBackToMonospace() {
        let font = DarkMono.resolvedFont(family: "No Such Family 12345", pointSize: 15)
        #expect(font.familyName != "No Such Family 12345")
        #expect(font.pointSize == 15, "the configured size survives the family fallback")
        #expect(DarkMono.isMonospace(font))

        let blank = DarkMono.resolvedFont(family: "   ", pointSize: 13)
        #expect(blank.pointSize == 13)
        #expect(DarkMono.isMonospace(blank))
    }

    @Test("An invalid configured point size keeps the documented default of 13 points")
    func invalidPointSizeKeepsTheDocumentedDefault() {
        #expect(DarkMono.validPointSize(0) == 13)
        #expect(DarkMono.validPointSize(-4) == 13)
        #expect(DarkMono.validPointSize(.nan) == 13)
        #expect(DarkMono.validPointSize(.infinity) == 13)
        #expect(DarkMono.validPointSize(100_000) == 13)
        #expect(DarkMono.validPointSize(12.5) == 12.5)
        #expect(DarkMono.validPointSize(16) == 16)

        let store = DarkMonochromaticFakeSettingsStore(
            typography: TypographySettings(fontFamily: "Menlo", pointSize: .nan)
        )
        let feature = DarkMonochromaticWindowAppearanceFeature(settings: store)
        let appearance = feature.resolvePersistedAppearance()

        #expect(appearance.pointSize == 13)
        #expect(appearance.font.pointSize == 13)
        #expect(DarkMono.isMonospace(appearance.font))
        #expect(appearance.contrastRatio >= DarkMono.minimumContrastRatio)
    }

    @Test("A configured non-monospace family is reported by measurement, not trusted")
    func nonMonospaceFamilyIsReportedByMeasurement() {
        let store = DarkMonochromaticFakeSettingsStore(
            typography: TypographySettings(fontFamily: "Helvetica", pointSize: 13)
        )
        let feature = DarkMonochromaticWindowAppearanceFeature(settings: store)
        let appearance = feature.resolvePersistedAppearance()

        #expect(appearance.fontFamily == "Helvetica")
        #expect(appearance.fontIsMonospace == false,
                "the appearance reports what the font really is, so a caller can reject it")
        #expect(DarkMono.isMonospace(appearance.font) == false)
    }

    @Test("Channel values are clamped and a non-finite channel never reaches AppKit")
    func channelValuesAreClampedSafely() {
        #expect(darkMonoRGB(2, -1, 0.5).clamped() == darkMonoRGB(1, 0, 0.5))
        #expect(darkMonoRGB(.nan, 2, -1).hexString == "#00FF00")
        #expect(darkMonoRGB(.infinity, 2, -1).hexString == "#00FF00")
        #expect(darkMonoRGB(.infinity, 0, 0).hexString == "#000000",
                "a non-finite channel becomes 0 instead of reaching AppKit")
        #expect(darkMonoRGB(-.infinity, .nan, .infinity).hexString == "#000000")
        #expect(darkMonoRGB(.nan, .nan, .nan).hexString == "#000000")

        #expect(DarkMono.RGB.fromHex("#000000") == DarkMono.backgroundColor)
        #expect(DarkMono.RGB.fromHex("000000") == DarkMono.backgroundColor)
        #expect(DarkMono.RGB.fromHex("#ABCDEF") == darkMonoRGB(171.0 / 255.0, 205.0 / 255.0, 239.0 / 255.0))
        #expect(DarkMono.RGB.fromHex("#12345") == nil)
        #expect(DarkMono.RGB.fromHex("#1234567") == nil)
        #expect(DarkMono.RGB.fromHex("#GGGGGG") == nil)
        #expect(DarkMono.RGB.fromHex("+12345") == nil)
        #expect(DarkMono.RGB.fromHex("") == nil)
    }

    // MARK: - RECOVERY: failure, cancellation, last valid state

    @Test("A surface that refuses the configuration fails, rolls back, and leaves no alert")
    func refusedConfigurationPreservesTheLastValidAppearance() throws {
        let store = DarkMonochromaticFakeSettingsStore()
        let probe = DarkMonochromaticConfigurationProbe(failureAttempt: 1)
        let box = DarkMonochromaticFeatureBox()

        // A surface that partially applies the appearance and then reports a
        // failure, so the rollback is exercised against real attributes.
        let feature = DarkMonochromaticWindowAppearanceFeature(
            settings: store,
            configureSurface: { textView, appearance in
                box.feature.map { probe.note($0.appearanceState) }
                if probe.needsScriptedFailure() {
                    textView.drawsBackground = true
                    textView.backgroundColor = appearance.background.nsColor
                    textView.textColor = appearance.foreground.nsColor
                    return false
                }
                return DarkMono.configure(textView, with: appearance)
            }
        )
        box.feature = feature

        // The surface has a previous, valid appearance of its own.
        let textView = darkMonochromaticTextView(text: "note")
        let priorFont = try #require(NSFont(name: "Courier New", size: 11))
        textView.font = priorFont
        textView.textColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        textView.backgroundColor = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        textView.drawsBackground = false

        #expect(feature.appearanceState == .idle)

        let outcome = feature.apply(to: textView, typography: .default)

        #expect(outcome.state == .failed)
        #expect(outcome.appearance == nil, "a failed attempt publishes no appearance")
        #expect(outcome.restoredPreviousAppearance)
        #expect(outcome.lastValidAppearance == nil, "nothing had been applied before")
        #expect(outcome.errorAlert == nil,
                "the colour fallback is automatic: a failed configuration presents no modal alert")
        let status = try #require(outcome.statusMessage)
        #expect(status.isFailure)
        #expect(status.text == DarkMono.failureStatusText)
        #expect(status.text.contains("/") == false, "the message carries no file path")
        #expect(feature.appearanceState == .failed)
        #expect(feature.lastAppliedAppearance == nil)

        // The partial configuration was rolled back exactly.
        #expect(textView.drawsBackground == false)
        #expect(DarkMono.RGB.from(textView.backgroundColor) == darkMonoRGB(0.1, 0.1, 0.1))
        let restoredTextColor = try #require(textView.textColor)
        #expect(DarkMono.RGB.from(restoredTextColor) == darkMonoRGB(0.2, 0.4, 0.6))
        #expect(textView.font?.fontName == priorFont.fontName)
        #expect(textView.font?.pointSize == 11)

        // The configuration step ran exactly once: retrying is explicit.
        #expect(probe.callCount == 1)
        #expect(probe.stateDuringConfiguration == .active, "the attempt is active while it configures")

        // An explicit second attempt (the user-retry path) succeeds and publishes.
        let retry = feature.apply(to: textView, typography: .default)
        #expect(retry.state == .succeeded)
        #expect(retry.appearance != nil)
        #expect(retry.restoredPreviousAppearance == false)
        #expect(retry.errorAlert == nil)
        #expect(feature.appearanceState == .succeeded)
        #expect(feature.lastAppliedAppearance == retry.appearance)
        #expect(probe.callCount == 2)
        #expect(DarkMono.RGB.from(textView.backgroundColor) == DarkMono.backgroundColor)
        #expect(textView.drawsBackground)
        #expect(DarkMono.RGB.from(try #require(textView.textColor)) == DarkMono.preferredForeground)
    }

    @Test("A failure after a success preserves and re-renders the last valid appearance")
    func failureAfterSuccessPreservesTheLastValidAppearance() throws {
        let store = DarkMonochromaticFakeSettingsStore()
        let probe = DarkMonochromaticConfigurationProbe(failureAttempt: 2)
        let box = DarkMonochromaticFeatureBox()

        let feature = DarkMonochromaticWindowAppearanceFeature(
            settings: store,
            configureSurface: { textView, appearance in
                box.feature.map { probe.note($0.appearanceState) }
                if probe.needsScriptedFailure() {
                    // A partial configuration that reports a failure.
                    textView.textColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
                    return false
                }
                return DarkMono.configure(textView, with: appearance)
            }
        )
        box.feature = feature

        let textView = darkMonochromaticTextView(text: "note")
        let first = feature.apply(to: textView, typography: .default)
        #expect(first.state == .succeeded)
        let published = try #require(feature.lastAppliedAppearance)
        #expect(published == first.appearance)
        #expect(DarkMono.RGB.from(textView.backgroundColor) == DarkMono.backgroundColor)

        let second = feature.apply(to: textView, typography: .default)

        #expect(second.state == .failed)
        #expect(second.appearance == nil)
        #expect(second.restoredPreviousAppearance)
        #expect(second.lastValidAppearance == published,
                "the previously applied appearance stays published through a failure")
        #expect(feature.lastAppliedAppearance == published)
        #expect(feature.appearanceState == .failed)
        #expect(probe.callCount == 2)

        // The surface renders the last valid appearance again, not the partial
        // red the failed attempt had written.
        let restoredTextColor = try #require(textView.textColor)
        #expect(DarkMono.RGB.from(restoredTextColor) == published.foreground)
        #expect(DarkMono.RGB.from(textView.backgroundColor) == DarkMono.backgroundColor)
        #expect(textView.font?.familyName == published.fontFamily)
        #expect(textView.font?.pointSize == CGFloat(published.pointSize))
    }

    @Test("An interrupted application is cancelled, publishes nothing, and restores the surface")
    func cancelledApplicationRestoresTheSurface() throws {
        let box = DarkMonochromaticFeatureBox()
        let probe = DarkMonochromaticConfigurationProbe()

        let feature = DarkMonochromaticWindowAppearanceFeature(
            settings: DarkMonochromaticFakeSettingsStore(),
            configureSurface: { textView, appearance in
                box.feature.map { probe.note($0.appearanceState) }
                // The app terminates while the surface is being configured.
                _ = box.feature?.cancel()
                return DarkMono.configure(textView, with: appearance)
            }
        )
        box.feature = feature

        let textView = darkMonochromaticTextView(text: "note")
        textView.backgroundColor = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        textView.drawsBackground = false

        #expect(feature.cancel() == false, "there is no in-flight application to interrupt while idle")
        #expect(feature.appearanceState == .idle)

        let outcome = feature.apply(to: textView, typography: .default)

        #expect(outcome.state == .cancelled)
        #expect(outcome.appearance == nil, "an interrupted attempt is never published as a success")
        #expect(outcome.restoredPreviousAppearance)
        #expect(outcome.statusMessage == nil, "a cancellation is not an error")
        #expect(outcome.errorAlert == nil)
        #expect(feature.appearanceState == .cancelled)
        #expect(feature.lastAppliedAppearance == nil)
        #expect(probe.stateDuringConfiguration == .active)

        // The fully configured surface was rolled back.
        #expect(textView.drawsBackground == false)
        #expect(DarkMono.RGB.from(textView.backgroundColor) == darkMonoRGB(0.1, 0.1, 0.1))

        // Cancelling again reports no further interruption.
        #expect(feature.cancel() == false)
    }

    @Test("The application state moves idle → active → succeeded and publishes the appearance")
    func applicationStateMachine() throws {
        let probe = DarkMonochromaticConfigurationProbe()
        let box = DarkMonochromaticFeatureBox()

        let feature = DarkMonochromaticWindowAppearanceFeature(
            settings: DarkMonochromaticFakeSettingsStore(),
            configureSurface: { textView, appearance in
                box.feature.map { probe.note($0.appearanceState) }
                return DarkMono.configure(textView, with: appearance)
            }
        )
        box.feature = feature

        #expect(feature.appearanceState == .idle)
        #expect(feature.lastAppliedAppearance == nil)

        let textView = darkMonochromaticTextView(text: "note")
        let outcome = feature.apply(to: textView, typography: .default)

        #expect(probe.stateDuringConfiguration == .active)
        #expect(probe.callCount == 1)
        #expect(outcome.state == .succeeded)
        #expect(feature.appearanceState == .succeeded)
        #expect(feature.lastAppliedAppearance == outcome.appearance)

        let appearance = try #require(outcome.appearance)
        #expect(DarkMono.evaluate(appearance) == .succeeded)
        #expect(appearance.backgroundHex == DarkMono.backgroundHex)
        #expect(appearance.background == DarkMono.backgroundColor)
        #expect(appearance.contrastRatio >= DarkMono.minimumContrastRatio)
        #expect(appearance.fontIsMonospace)
        #expect(DarkMono.evaluate(appearance) == OperationState.succeeded)
    }
}
