//
//  DarkMonochromaticWindowAppearanceFeature.swift
//  MonospaceNotes
//
//  TASK-05-DARK-MONOCHROMATIC-WINDOW-APPEARANCE — owner
//  OWN-DARK-MONOCHROMATIC-WINDOW-APPEARANCE.
//
//  Owns the dark monochromatic window appearance of
//  FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE:
//
//    * CON-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-INTERFACE — the window
//      background is #000000 and the text is rendered in the configured
//      monospace font at the configured point size with a foreground colour
//      that meets a contrast ratio of at least 7:1 against #000000.
//    * CON-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-RECOVERY — a configured
//      foreground that does not meet the ratio is substituted automatically,
//      without a user retry. The appearance application is represented as
//      idle / active / succeeded / failed / cancelled, and every terminal path
//      that publishes nothing puts the surface back on the last valid
//      appearance.
//
//  How the ratio is met
//  --------------------
//  `contrastRatio(_:against:)` is the real WCAG relative-luminance formula:
//  each sRGB channel is linearised
//  (`c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ^ 2.4`), the channels are
//  combined as `0.2126 R + 0.7152 G + 0.0722 B`, and the ratio is
//  `(L_lighter + 0.05) / (L_darker + 0.05)`. White on #000000 therefore
//  measures exactly 21:1, which is what `preferredForeground` resolves to.
//  `foregroundColor(preferred:)` returns the configured colour unchanged when it
//  already clears `minimumContrastRatio`, and otherwise lifts it along a
//  straight line toward white — luminance is non-decreasing along that line, so
//  a bisection finds the smallest lift that clears the floor (plus
//  `substitutionMargin`, so a passing colour never sits exactly on the
//  threshold). If a lift could not be found at all, the colour falls back to
//  `preferredForeground`, which always passes because it is white.
//
//  What "rendered" means here
//  --------------------------
//  `resolve(typography:preferredForeground:)` is the value side: it returns the
//  `ResolvedAppearance` a surface must render. `apply(to:typography:)` is the
//  rendered side: it writes that appearance onto a real `NSTextView` (background,
//  text colour, insertion point, font) and `applyToWindow(_:typography:)` writes
//  the #000000 background and the dark appearance onto a real `NSWindow`. The
//  configuration step is injected, so the failure and cancellation branches are
//  exercised against real surfaces without pretending that AppKit failed.
//
//  Invariants honoured here
//  ------------------------
//    * No network APIs, no third-party dependencies, and no UI presented by this
//      feature: nothing here calls `runModal()`, opens a panel, or shows a sheet.
//    * No file I/O. The only persisted values this feature reads are the
//      typography settings, through the injected `SettingsStoring` seam
//      (CON-DATA-TYPOGRAPHY-SETTINGS / CON-PERSISTENCE-TYPOGRAPHY-SETTINGS).
//    * Reporting values never carry note contents, buffers, or file paths.
//    * Nothing is retained that would need releasing later: this feature holds no
//      task, stream, handle, or delegate, so every terminal path is clean by
//      construction.
//

import AppKit
import CoreText
import Foundation

@MainActor
final class DarkMonochromaticWindowAppearanceFeature {

    // MARK: - Locked surface

    /// A colour in the sRGB space this appearance is defined in. Channels are
    /// 0...1; anything outside that range is clamped on the way out, never
    /// wrapped or silently misinterpreted.
    struct RGB: Equatable, Sendable {
        var r: Double
        var g: Double
        var b: Double

        init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        static let black = RGB(r: 0, g: 0, b: 0)
        static let white = RGB(r: 1, g: 1, b: 1)

        /// `#RRGGBB`, upper case — the form the window background is locked to.
        var hexString: String {
            let channels = eightBitChannels
            return String(format: "#%02X%02X%02X", channels.r, channels.g, channels.b)
        }

        /// The 8-bit channels `hexString` is built from.
        var eightBitChannels: (r: Int, g: Int, b: Int) {
            let safe = clamped()
            return (
                r: Int((safe.r * 255).rounded()),
                g: Int((safe.g * 255).rounded()),
                b: Int((safe.b * 255).rounded())
            )
        }

        /// The colour AppKit renders for this triple.
        var nsColor: NSColor {
            let safe = clamped()
            return NSColor(srgbRed: safe.r, green: safe.g, blue: safe.b, alpha: 1)
        }

        /// The triple behind a real `NSColor`, or `nil` when that colour cannot
        /// be expressed in sRGB. Reading colours back from AppKit objects is how
        /// the rendered surface is checked.
        static func from(_ nsColor: NSColor) -> RGB? {
            guard let converted = nsColor.usingColorSpace(.sRGB) else { return nil }
            return RGB(
                r: Double(converted.redComponent),
                g: Double(converted.greenComponent),
                b: Double(converted.blueComponent)
            )
        }

        /// Parses `#RRGGBB` or `RRGGBB`. Anything else is `nil`, so an
        /// unparsable value can never be mistaken for a colour.
        static func fromHex(_ hex: String) -> RGB? {
            let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            guard digits.count == 6,
                  digits.allSatisfy({ $0.isHexDigit }),
                  let value = UInt32(digits, radix: 16) else {
                return nil
            }
            return RGB(
                r: Double((value >> 16) & 0xFF) / 255,
                g: Double((value >> 8) & 0xFF) / 255,
                b: Double(value & 0xFF) / 255
            )
        }

        /// Every channel inside 0...1. A non-finite channel becomes 0 instead of
        /// travelling into AppKit, where it has no meaning.
        func clamped() -> RGB {
            RGB(r: Self.channel(r), g: Self.channel(g), b: Self.channel(b))
        }

        private static func channel(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return min(max(value, 0), 1)
        }
    }

    /// The locked window background (CON-DARK-MONOCHROMATIC-WINDOW-APPEARANCE-
    /// INTERFACE: "the window background is #000000").
    static let backgroundHex: String = "#000000"

    /// The same background as an RGB triple: black, every channel 0.
    static let backgroundColor: RGB = .black

    /// The locked minimum contrast ratio of the text foreground against
    /// #000000.
    static let minimumContrastRatio: Double = 7

    /// The foreground this app prefers: pure white, the highest contrast a
    /// foreground can have against #000000 (21:1).
    static let preferredForeground: RGB = .white

    /// How far above the locked ratio the automatic substitution aims, so a
    /// substituted colour never sits exactly on the floor where rounding could
    /// flip it back below.
    static let substitutionMargin: Double = 0.01

    // MARK: - The real WCAG contrast computation

    /// The relative luminance of `color` (WCAG 2.2 definition) from its sRGB
    /// channels.
    static func relativeLuminance(_ color: RGB) -> Double {
        let safe = color.clamped()
        return 0.2126 * linearised(safe.r)
            + 0.7152 * linearised(safe.g)
            + 0.0722 * linearised(safe.b)
    }

    /// The real WCAG contrast ratio `(L_lighter + 0.05) / (L_darker + 0.05)`
    /// between two colours. Order never matters; the lighter colour is always the
    /// numerator, so the result is always at least 1.
    static func contrastRatio(_ foreground: RGB, against background: RGB) -> Double {
        let first = relativeLuminance(foreground)
        let second = relativeLuminance(background)
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The foreground this app renders for a configured colour: the configured
    /// colour when it already clears `minimumContrastRatio` against the locked
    /// background, otherwise a substituted colour that does.
    static func foregroundColor(preferred: RGB) -> RGB {
        let configured = preferred.clamped()
        if contrastRatio(configured, against: backgroundColor) >= minimumContrastRatio {
            return configured
        }
        return substituting(configured)
    }

    /// The documented failure behaviour of the interface contract: "if the
    /// configured foreground color does not meet the contrast ratio, the app
    /// substitutes a foreground color that does". The substitution is automatic
    /// and requires no user retry.
    static func substituting(_ preferred: RGB) -> RGB {
        let target = minimumContrastRatio + substitutionMargin

        // Pure white is the bound of the search and always clears the target
        // (21:1 against #000000). Nothing below the floor is ever returned.
        guard contrastRatio(blend(preferred, towardWhite: 1), against: backgroundColor) >= target else {
            return preferredForeground
        }

        var below = 0.0
        var above = 1.0
        for _ in 0..<64 {
            let middle = (below + above) / 2
            if contrastRatio(blend(preferred, towardWhite: middle), against: backgroundColor) >= target {
                above = middle
            } else {
                below = middle
            }
        }

        let candidate = blend(preferred, towardWhite: above)
        // Final guard on the documented floor. The bisection cannot land below
        // it, and if it ever did, white would still pass.
        return contrastRatio(candidate, against: backgroundColor) >= minimumContrastRatio
            ? candidate
            : preferredForeground
    }

    // MARK: - The configured monospace font

    /// The font a document surface renders with: the configured monospace family
    /// at the configured point size, or the system monospace face at the same
    /// size when that family is unavailable. The size is sanitised first, so a
    /// broken stored value can never produce a font AppKit cannot draw.
    ///
    /// The family is trusted to be monospace because a monospace family is all
    /// the settings surface offers; `isMonospace(_:)` and
    /// `ResolvedAppearance.fontIsMonospace` are how a caller verifies that.
    static func resolvedFont(family: String, pointSize: Double) -> NSFont {
        let size = validPointSize(pointSize)
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false, let requested = NSFont(name: trimmed, size: size) {
            return requested
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The point size a surface can actually render: a finite value in
    /// (0, 512]. Anything else falls back to the documented default (13 pt,
    /// `TypographySettings.default`), mirroring the settings rule
    /// (CON-DATA-TYPOGRAPHY-SETTINGS: an invalid stored record never replaces the
    /// last valid state with something unusable).
    static func validPointSize(_ pointSize: Double) -> Double {
        guard pointSize.isFinite, pointSize > 0, pointSize <= 512 else {
            return TypographySettings.default.pointSize
        }
        return pointSize
    }

    /// Whether a real font is monospaced. Every sampled character must occupy the
    /// same advance width, measured from the font's own glyph metrics — a
    /// measurement rather than a trusted flag, so a face that merely claims the
    /// monospace trait is not accepted on that claim alone.
    static func isMonospace(_ font: NSFont) -> Bool {
        let advances = advances(of: monospaceProbeCharacters, in: font)
        guard advances.count == monospaceProbeCharacters.count,
              let first = advances.first,
              first > 0 else {
            return false
        }
        let tolerance = max(0.01, first * 0.001)
        return advances.allSatisfy { abs($0 - first) <= tolerance }
    }

    /// The characters the monospace probe measures: wide, narrow, digit,
    /// punctuation, and space glyphs, which a proportional face cannot draw at
    /// one advance.
    private static let monospaceProbeCharacters: [Character] = ["W", "i", "m", "1", ".", "l", "M", "0", " "]

    /// The horizontal advance of each character in `font`, or `[]` when the font
    /// cannot map one of them.
    private static func advances(of characters: [Character], in font: NSFont) -> [CGFloat] {
        var unichars: [UniChar] = []
        for character in characters {
            guard let scalar = character.unicodeScalars.first, scalar.value <= 0xFFFF else { return [] }
            unichars.append(UniChar(scalar.value))
        }

        let coreTextFont = font as CTFont
        var glyphs = [CGGlyph](repeating: 0, count: unichars.count)
        guard CTFontGetGlyphsForCharacters(coreTextFont, &unichars, &glyphs, unichars.count) else {
            return []
        }

        var sizes = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(coreTextFont, .horizontal, &glyphs, &sizes, glyphs.count)
        return sizes.map(\.width)
    }

    // MARK: - Resolved appearance

    /// Everything a surface renders for one typography setting.
    struct ResolvedAppearance: Equatable, Sendable {
        /// Always `#000000` (the locked window background).
        let backgroundHex: String
        /// The window background as a triple.
        let background: RGB
        /// The foreground the surface renders. Never a colour that fails
        /// `minimumContrastRatio` against `background`.
        let foreground: RGB
        /// `foreground` in `#RRGGBB` form.
        let foregroundHex: String
        /// The measured WCAG ratio of `foreground` against `background`; always
        /// at least `minimumContrastRatio`.
        let contrastRatio: Double
        /// Whether the configured foreground failed the check and was replaced by
        /// the automatic substitution.
        let substitutedForeground: Bool
        /// The configured monospace family.
        let fontFamily: String
        /// The configured point size, sanitised to a drawable value.
        let pointSize: Double
        /// Whether the resolved font really is monospaced, measured from its
        /// glyph advances.
        let fontIsMonospace: Bool

        /// The real font this appearance renders with.
        @MainActor var font: NSFont {
            DarkMonochromaticWindowAppearanceFeature.resolvedFont(family: fontFamily, pointSize: pointSize)
        }
    }

    /// The result of one attempt to put a resolved appearance on a real surface.
    struct AppearanceOutcome: Equatable, Sendable {
        /// `.succeeded`, `.failed`, or `.cancelled`; a completed application is
        /// never `.idle` or `.active`.
        let state: OperationState
        /// The appearance the surface now renders — present only for
        /// `.succeeded`.
        let appearance: ResolvedAppearance?
        /// The most recent successfully applied appearance, whatever this attempt
        /// did: a failed or cancelled attempt preserves it.
        let lastValidAppearance: ResolvedAppearance?
        /// Whether this attempt put the surface back on the last valid appearance
        /// after a partial configuration.
        let restoredPreviousAppearance: Bool
        /// Non-modal, content-free explanation of a failed or cancelled attempt;
        /// `nil` when the surface was configured successfully.
        let statusMessage: StatusMessage?
        /// Always `nil`: the contract's fallback is automatic and requires no user
        /// retry, so this feature never presents a modal alert.
        let errorAlert: ErrorAlert?
    }

    /// The non-modal text a failed application reports. It names no file, buffer,
    /// or note content, and it never asks the user to retry — the colour fallback
    /// is automatic, so a failed surface configuration is explained and left with
    /// the last valid appearance in effect.
    static let failureStatusText: String =
        "Window appearance could not be applied: the document surface refused the configuration. "
        + "The previous appearance is still in effect."

    // MARK: - Injected services

    /// The typography read (font family and point size) — the only persisted
    /// values this feature consumes (CON-DATA-TYPOGRAPHY-SETTINGS).
    private let settings: any SettingsStoring

    /// How a real document surface is configured. Returns `false` when the
    /// surface refused the configuration. Injected so the failure branch is
    /// exercised against a real `NSTextView`.
    private let configureSurface: SurfaceConfigurator

    /// Configures a real document surface with a resolved appearance and reports
    /// whether the surface now carries it.
    typealias SurfaceConfigurator = @MainActor (NSTextView, ResolvedAppearance) -> Bool

    /// - Parameters:
    ///   - settings: the settings store the typography read uses. The default is
    ///     the real store, so the composition root renders the user's persisted
    ///     family and point size.
    ///   - configureSurface: the surface configuration step. The default writes
    ///     the appearance onto the text view through AppKit.
    init(
        settings: any SettingsStoring = DataStore(),
        configureSurface: @escaping SurfaceConfigurator = DarkMonochromaticWindowAppearanceFeature.configure(_:with:)
    ) {
        self.settings = settings
        self.configureSurface = configureSurface
    }

    // MARK: - Application state (idle / active / succeeded / failed / cancelled)

    /// The appearance application's operation state. Starts `.idle`: nothing has
    /// been applied.
    private(set) var appearanceState: OperationState = .idle

    /// The most recent appearance that was applied successfully; `nil` until the
    /// first success. A failed or cancelled attempt leaves it untouched, which is
    /// what "preserve the last valid user state" means for this feature.
    private(set) var lastAppliedAppearance: ResolvedAppearance?

    // MARK: - Resolution

    /// Resolves the appearance for one typography setting. Pure: it changes no
    /// state and touches no surface.
    ///
    /// - Parameter preferredForeground: the configured foreground colour. It is
    ///   rendered as-is when it clears the ratio and substituted automatically
    ///   when it does not.
    func resolve(
        typography: TypographySettings,
        preferredForeground: RGB = DarkMonochromaticWindowAppearanceFeature.preferredForeground
    ) -> ResolvedAppearance {
        let background = Self.backgroundColor
        let rendered = Self.foregroundColor(preferred: preferredForeground)
        let size = Self.validPointSize(typography.pointSize)
        let font = Self.resolvedFont(family: typography.fontFamily, pointSize: size)

        return ResolvedAppearance(
            backgroundHex: Self.backgroundHex,
            background: background,
            foreground: rendered,
            foregroundHex: rendered.hexString,
            contrastRatio: Self.contrastRatio(rendered, against: background),
            substitutedForeground: rendered != preferredForeground.clamped(),
            fontFamily: typography.fontFamily,
            pointSize: size,
            fontIsMonospace: Self.isMonospace(font)
        )
    }

    /// Resolves the appearance for the typography that is currently persisted
    /// (the launch read and the read after a settings change).
    func resolvePersistedAppearance(
        preferredForeground: RGB = DarkMonochromaticWindowAppearanceFeature.preferredForeground
    ) -> ResolvedAppearance {
        resolve(typography: settings.loadTypography(), preferredForeground: preferredForeground)
    }

    /// The operation state of a resolved appearance: `.succeeded` when the
    /// foreground the surface will render clears the ratio floor against the
    /// locked #000000 background — which the automatic substitution guarantees —
    /// and `.failed` otherwise.
    static func evaluate(_ appearance: ResolvedAppearance) -> OperationState {
        appearance.contrastRatio >= minimumContrastRatio
            && appearance.background == backgroundColor
            ? .succeeded
            : .failed
    }

    // MARK: - Rendering on real surfaces

    /// Puts the resolved appearance on a real document text view: the #000000
    /// background, the contrast-checked foreground, the insertion point, and the
    /// configured monospace font.
    ///
    /// Terminal paths:
    /// * `.succeeded` — the surface now carries the appearance, which is also
    ///   published as `lastAppliedAppearance`.
    /// * `.failed` — the surface refused the configuration (or a partial
    ///   configuration was reported as failed). The surface is rolled back to the
    ///   last valid appearance, the failure is explained non-modally, and no modal
    ///   alert is produced because the contract requires no user retry.
    /// * `.cancelled` — `cancel()` interrupted the attempt while it was in flight.
    ///   Nothing is published and the surface is rolled back.
    ///
    /// The configuration step runs exactly once per attempt: this feature never
    /// retries on its own.
    @discardableResult
    func apply(
        to textView: NSTextView,
        typography: TypographySettings = .default,
        preferredForeground: RGB = DarkMonochromaticWindowAppearanceFeature.preferredForeground
    ) -> AppearanceOutcome {
        let appearance = resolve(typography: typography, preferredForeground: preferredForeground)
        appearanceState = .active

        let snapshot = SurfaceSnapshot(of: textView)
        let configured = configureSurface(textView, appearance)

        // A cancellation wins over the configuration result: an attempt the app
        // interrupted is never published as a success.
        if appearanceState == .cancelled {
            snapshot.restore(in: textView)
            appearanceState = .cancelled
            return AppearanceOutcome(
                state: .cancelled,
                appearance: nil,
                lastValidAppearance: lastAppliedAppearance,
                restoredPreviousAppearance: true,
                statusMessage: nil,
                errorAlert: nil
            )
        }

        guard configured else {
            snapshot.restore(in: textView)
            appearanceState = .failed
            return AppearanceOutcome(
                state: .failed,
                appearance: nil,
                lastValidAppearance: lastAppliedAppearance,
                restoredPreviousAppearance: true,
                statusMessage: StatusMessage(text: Self.failureStatusText, isFailure: true),
                errorAlert: nil
            )
        }

        appearanceState = Self.evaluate(appearance)
        guard appearanceState == .succeeded else {
            // A resolved appearance that does not clear the floor must never be
            // published; the surface goes back to the last valid appearance.
            snapshot.restore(in: textView)
            return AppearanceOutcome(
                state: .failed,
                appearance: nil,
                lastValidAppearance: lastAppliedAppearance,
                restoredPreviousAppearance: true,
                statusMessage: StatusMessage(text: Self.failureStatusText, isFailure: true),
                errorAlert: nil
            )
        }

        lastAppliedAppearance = appearance
        return AppearanceOutcome(
            state: .succeeded,
            appearance: appearance,
            lastValidAppearance: appearance,
            restoredPreviousAppearance: false,
            statusMessage: nil,
            errorAlert: nil
        )
    }

    /// Puts the resolved appearance on a real window: the #000000 background and
    /// the dark appearance, so the window chrome does not fight the black
    /// document surface. Window configuration is a pair of property writes and
    /// cannot be interrupted part-way, so it has no cancellation branch; the
    /// state it publishes is `evaluate(_:)` of the resolved appearance.
    @discardableResult
    func applyToWindow(
        _ window: NSWindow,
        typography: TypographySettings = .default,
        preferredForeground: RGB = DarkMonochromaticWindowAppearanceFeature.preferredForeground
    ) -> ResolvedAppearance {
        let appearance = resolve(typography: typography, preferredForeground: preferredForeground)

        appearanceState = .active
        window.backgroundColor = appearance.background.nsColor
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = true
        appearanceState = Self.evaluate(appearance)

        if appearanceState == .succeeded {
            lastAppliedAppearance = appearance
        }
        return appearance
    }

    /// The default configuration step: writes the appearance onto a real text
    /// view and reports whether the surface now carries it. The post-condition is
    /// read back from the surface itself, so a text view that does not end up with
    /// the resolved colours and font is reported as a failure instead of being
    /// claimed as applied.
    static func configure(_ textView: NSTextView, with appearance: ResolvedAppearance) -> Bool {
        textView.drawsBackground = true
        textView.backgroundColor = appearance.background.nsColor
        textView.textColor = appearance.foreground.nsColor
        textView.insertionPointColor = appearance.foreground.nsColor
        textView.font = appearance.font

        guard textView.drawsBackground,
              let renderedBackground = RGB.from(textView.backgroundColor),
              let renderedTextColor = textView.textColor,
              let renderedForeground = RGB.from(renderedTextColor),
              textView.font != nil else {
            return false
        }

        return renderedBackground == appearance.background
            && renderedForeground == appearance.foreground
    }

    // MARK: - Cancellation

    /// Interrupts an application that is still in flight, e.g. because the
    /// application is terminating while a surface is being configured. Nothing
    /// about the interrupted attempt is published: it becomes `.cancelled`, the
    /// surface is restored to the last valid appearance, and no alert is produced
    /// (a cancellation is not an error). Returns whether an in-flight application
    /// was actually interrupted.
    @discardableResult
    func cancel() -> Bool {
        guard appearanceState == .active else { return false }
        appearanceState = .cancelled
        return true
    }

    // MARK: - Private

    /// A colour part-way between `color` and pure white. Luminance is
    /// non-decreasing in `t`, which is what makes the substitution searchable.
    static func blend(_ color: RGB, towardWhite t: Double) -> RGB {
        let amount = min(max(t, 0), 1)
        let safe = color.clamped()
        return RGB(
            r: safe.r + (1 - safe.r) * amount,
            g: safe.g + (1 - safe.g) * amount,
            b: safe.b + (1 - safe.b) * amount
        )
    }

    /// The linearised value of one sRGB channel (WCAG 2.2).
    private static func linearised(_ channel: Double) -> Double {
        channel <= 0.03928
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// The surface attributes an attempt may change, captured before it starts, so
    /// a terminal path that publishes nothing can put the surface back exactly as
    /// it was.
    @MainActor
    private struct SurfaceSnapshot {
        let font: NSFont?
        let textColor: NSColor?
        let backgroundColor: NSColor
        let drawsBackground: Bool
        let insertionPointColor: NSColor

        init(of textView: NSTextView) {
            font = textView.font
            textColor = textView.textColor
            backgroundColor = textView.backgroundColor
            drawsBackground = textView.drawsBackground
            insertionPointColor = textView.insertionPointColor
        }

        func restore(in textView: NSTextView) {
            textView.font = font
            textView.textColor = textColor
            textView.backgroundColor = backgroundColor
            textView.drawsBackground = drawsBackground
            textView.insertionPointColor = insertionPointColor
        }
    }
}
