//
//  SettingsWindowForTypographyAndKeybindingsFeature.swift
//  MonospaceNotes
//
//  TASK-14-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS — owner
//  OWN-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS.
//
//  Owns FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS:
//
//    * CON-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-INTERFACE — "the app opens a
//      Settings window with controls for font family, point size, and keybinding
//      assignments. Changes apply to the open document immediately and are written to
//      UserDefaults." Failure behavior: "if a chosen font family is unavailable, the app
//      keeps the previous font family and shows an inline message naming the unavailable
//      family."
//    * CON-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-RECOVERY — "preserve the last
//      valid state, explain the failure, and allow an explicit retry". Every attempt is
//      idle / active / succeeded / failed / cancelled; a rejected, refused or cancelled
//      change publishes nothing and the last valid settings stand in the window, in the
//      document and in UserDefaults.
//
//  Where the values come from and where they go
//  -------------------------------------------
//  Nothing about persistence or fallbacks is re-implemented here. Every read goes
//  through the injected `SettingsStoring` (`DataStore` in the app) and every write goes
//  through `PersistTypographyAndKeybindingsInUserdefaultsFeature` (TASK-13), so the
//  versioned `com.monospace.notes.settings.v1.*` keys, the validation rules and the
//  documented fallbacks — Menlo 13 and Cmd+O / Cmd+S / Shift+Cmd+S / Cmd+F / Cmd+, —
//  keep exactly one owner. `currentDraft()` reads the store, which is what makes
//  "reopening the Settings window shows the previously chosen values" true: the window
//  is a view of what is stored, never of a private copy.
//
//  What one apply guarantees
//  -------------------------
//  1. An unavailable font family is a REJECTED draft. The previous family and point
//     size stand, nothing is written to UserDefaults, the document's font is untouched,
//     and the window shows the exact inline message
//     `Font family “<name>” is unavailable.` — the failure is explained, not hidden, and
//     the user can retry immediately with another family.
//  2. An available family is written through the single settings gate (typography, then
//     keybindings) and applied to the open document's text view at once, so the window
//     and the document never disagree.
//  3. A store that refuses a write, and a change cancelled before it is written, throw
//     and publish nothing: the last valid state stands and the reason is reported
//     inline. This owner presents no modal alert, because the contract's recovery asks
//     for an inline message and an explicit retry.
//
//  Accessibility
//  -------------
//  Every control the window offers has a STABLE spoken label, value and hint produced by
//  `accessibilityElements()` / `accessibilityElements(for:)`, in focus order (font
//  family, point size, then the five keybindings in menu order). `SettingsView` renders
//  its visible labels and its accessibility labels/values/hints/identifiers from those
//  same elements, so VoiceOver and the keyboard operate on exactly what is on screen and
//  the spoken values follow the settings as they change.
//
//  Invariants honoured here
//  ------------------------
//    * No network APIs and no third-party dependencies.
//    * No file I/O at all: typography and keybindings travel through the injected store
//      (`UserDefaults`, and nothing else, is persisted). The open document buffer and the
//      workspace folder reference are never read, written or persisted by this file.
//    * A settings change touches the document surface only through its `font`; no path,
//      handle or file parameter exists on any API here.
//    * Reporting values name settings and reasons only — never note contents, buffers,
//      or file paths.
//    * This owner holds no task, stream, file handle or delegate, so every terminal path
//      is clean by construction: there is nothing to cancel or close beyond the
//      cancelled-change entry check.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
final class SettingsWindowForTypographyAndKeybindingsFeature {

    // MARK: - Locked surface

    /// One settings draft: exactly the values the Settings window is asking for.
    struct Draft: Equatable, Sendable {
        var typography: TypographySettings
        var keybindings: KeybindingSettings

        init(typography: TypographySettings = .default,
             keybindings: KeybindingSettings = .default) {
            self.typography = typography
            self.keybindings = keybindings
        }
    }

    /// The outcome of one apply, including the inline message the window shows.
    struct ApplyResult: Equatable, Sendable {
        /// The typography in effect after this apply: the draft's when it was accepted,
        /// otherwise the last valid settings.
        var typography: TypographySettings
        /// The keybindings in effect after this apply: the draft's when they were
        /// accepted, otherwise the last valid set.
        var keybindings: KeybindingSettings
        /// The inline (never modal) message: the unavailable-family message when the
        /// family could not be used, the store's own reason when a write was refused, and
        /// `nil` when the whole draft was accepted.
        var inlineMessage: String?
        /// Whether every part of the draft was applied and written.
        var accepted: Bool

        init(typography: TypographySettings,
             keybindings: KeybindingSettings,
             inlineMessage: String?,
             accepted: Bool) {
            self.typography = typography
            self.keybindings = keybindings
            self.inlineMessage = inlineMessage
            self.accepted = accepted
        }
    }

    /// The five commands the keybinding rows edit. This is the persistence owner's
    /// enum, reused by name rather than redeclared: the settings window and the stored
    /// set must never drift apart.
    typealias Command = PersistTypographyAndKeybindingsInUserdefaultsFeature.Command

    /// One control of the Settings window, with the stable label, value and hint a
    /// screen reader speaks and the stable identifier the UI tests address it by. The
    /// window renders from these, so what VoiceOver announces and what is on screen are
    /// the same strings.
    struct AccessibilityElement: Equatable, Sendable, Identifiable {
        enum Role: String, Sendable, Equatable {
            /// The font family picker.
            case fontFamilyPicker = "picker"
            /// The point size stepper.
            case pointSizeStepper = "stepper"
            /// One keybinding assignment row.
            case keyBindingPicker = "keyBindingPicker"
        }

        /// Which control this is.
        let role: Role
        /// The command this row edits; `nil` for the two typography controls.
        let command: Command?
        /// Stable identifier, e.g. `settings.keyBinding.save`.
        let identifier: String
        /// Stable spoken and visible label, e.g. `Save Key Binding`.
        let label: String
        /// The current spoken value, e.g. `⌘S` or `13 pt`.
        let value: String
        /// Stable hint describing how to operate the control with the keyboard.
        let hint: String

        var id: String { identifier }
    }

    /// The stable accessibility vocabulary of the window. Tests and the view read these
    /// names, so a label can never silently change under a VoiceOver user.
    enum Accessibility {
        static let fontFamilyLabel: String = "Font Family"
        static let pointSizeLabel: String = "Point Size"
        static let keyBindingLabelSuffix: String = " Key Binding"

        static func keyBindingLabel(for command: Command) -> String {
            command.displayName + keyBindingLabelSuffix
        }

        static let fontFamilyIdentifier: String = "settings.fontFamily"
        static let pointSizeIdentifier: String = "settings.pointSize"
        static let keyBindingIdentifierPrefix: String = "settings.keyBinding."
        static let inlineMessageIdentifier: String = "settings.inlineMessage"

        static func keyBindingIdentifier(for command: Command) -> String {
            keyBindingIdentifierPrefix + command.rawValue
        }

        static let fontFamilyHint: String =
            "Chooses the monospaced font family the document renders with. "
            + "Use the arrow keys to move through the available families."
        static let pointSizeHint: String =
            "Adjusts the document point size. Use the up and down arrow keys to change it."
        static let inlineMessageLabel: String = "Settings message"

        static func keyBindingHint(for command: Command) -> String {
            "Chooses the key combination that runs \(command.displayName). "
                + "Use the arrow keys to move through the available combinations."
        }
    }

    // MARK: - Documented values

    /// The five key combinations every row offers in addition to the assignment in
    /// effect, so a row can always be changed without a key-capture control.
    static let keyBindingPalette: [KeyBinding] = [
        KeyBinding(key: "o", command: true),
        KeyBinding(key: "s", command: true),
        KeyBinding(key: "s", command: true, shift: true),
        KeyBinding(key: "f", command: true),
        KeyBinding(key: ",", command: true),
        KeyBinding(key: "k", command: true),
        KeyBinding(key: "j", command: true),
        KeyBinding(key: "u", command: true),
        KeyBinding(key: "e", command: true),
        KeyBinding(key: "d", command: true),
        KeyBinding(key: "n", command: true),
        KeyBinding(key: "p", command: true),
    ]

    /// The point sizes the stepper offers. The store accepts up to
    /// `DataStore.maximumPointSize`; this is the range a person can read on screen.
    static let pointSizeRange: ClosedRange<Double> = 8...96
    static let pointSizeStep: Double = 1

    /// The unavailable-family message (CON-SETTINGS-WINDOW-...-INTERFACE failure
    /// behavior), with the locked curly quotes.
    static func unavailableFamilyMessage(for family: String) -> String {
        "Font family “\(family)” is unavailable."
    }

    /// The inline message of a change that was interrupted before it was written.
    static let cancelledMessage: String =
        "The settings change was cancelled. The previous settings are unchanged."

    /// The inline message of a change whose store refused the write without a reason of
    /// its own.
    static let refusedChangeMessage: String =
        "The settings change could not be saved. The previous settings are unchanged."

    // MARK: - Injected services

    /// The typography and keybinding persistence seam (CON-DATA-TYPOGRAPHY-SETTINGS /
    /// CON-DATA-KEYBINDING-SETTINGS). `DataStore` in the app.
    private let store: any SettingsStoring

    /// The single settings gate every write goes through (TASK-13). Its validation, its
    /// versioned keys, its non-modal failure wording and its fallback semantics are the
    /// ones this window uses — none of them are re-implemented here.
    private let persist: PersistTypographyAndKeybindingsInUserdefaultsFeature

    /// - Parameter store: the settings store the window reads and the settings gate it
    ///   writes through. The default is the real store, so the window shows and persists
    ///   the user's own choices.
    init(store: any SettingsStoring = DataStore()) {
        self.store = store
        self.persist = PersistTypographyAndKeybindingsInUserdefaultsFeature(store: store)
        self.typography = store.loadTypography()
        self.keybindings = store.loadKeybindings()
        self.inlineMessage = nil
        self.applyState = .idle
        self.lastResult = nil
    }

    // MARK: - State

    /// The last apply's operation state: idle before the first change, active while a
    /// change is being applied, and succeeded / failed / cancelled when it finished. A
    /// failed or cancelled change is never reported as a success.
    private(set) var applyState: OperationState

    /// The typography in effect: what the window shows and what the document renders.
    /// The documented default until a stored value or a change replaces it.
    private(set) var typography: TypographySettings

    /// The keybindings in effect: what the window shows and what the command surface
    /// resolves.
    private(set) var keybindings: KeybindingSettings

    /// The inline message of the most recent change: the unavailable-family message, the
    /// store's reason for a refused write, or the cancellation note. `nil` after an
    /// accepted change. Never presented as a modal alert.
    private(set) var inlineMessage: String?

    /// The most recent apply's result, including the ones that were not accepted.
    private(set) var lastResult: ApplyResult?

    // MARK: - What the window shows

    /// The values the window shows when it opens: read back from the store, so a window
    /// that is opened again shows the settings the user last chose — through the same
    /// documented fallbacks a launch uses for a missing or invalid stored value.
    func currentDraft() -> Draft {
        Draft(typography: store.loadTypography(), keybindings: store.loadKeybindings())
    }

    /// The font families the window offers: every monospaced family this Mac has,
    /// plus the family in effect and the documented default so the current choice is
    /// never missing from the list. Sorted, so the list is stable across openings.
    func availableFontFamilies() -> [String] {
        // Measuring every installed family is expensive, and the offered set is stable
        // for the life of the window, so it is measured once and then reused.
        if let cached = cachedAvailableFontFamilies { return cached }
        var offered = Set(Self.monospaceFamilies(NSFontManager.shared.availableFontFamilies))
        for family in [typography.fontFamily, DataStore.defaultFontFamily]
        where Self.isAvailableFamily(family) {
            offered.insert(family)
        }
        let families = offered.sorted()
        cachedAvailableFontFamilies = families
        return families
    }

    /// The measured monospaced-family list, computed on first use.
    private var cachedAvailableFontFamilies: [String]?

    /// The binding in effect for a command.
    func keybinding(for command: Command) -> KeyBinding {
        Self.binding(for: command, in: keybindings)
    }

    /// The key combinations one row offers: the binding in effect first (so the row
    /// always shows what is current), then the documented defaults, then the palette.
    static func keyBindingChoices(for command: Command, current: KeyBinding) -> [KeyBinding] {
        var choices: [KeyBinding] = [current]
        let candidates = Command.allCases.map { binding(for: $0, in: .default) } + keyBindingPalette
        for candidate in candidates where choices.contains(candidate) == false {
            choices.append(candidate)
        }
        return choices
    }

    /// The binding a settings set assigns to a command.
    static func binding(for command: Command, in keybindings: KeybindingSettings) -> KeyBinding {
        switch command {
        case .open: return keybindings.open
        case .save: return keybindings.save
        case .saveAs: return keybindings.saveAs
        case .search: return keybindings.search
        case .settings: return keybindings.settings
        }
    }

    /// Whether AppKit can render a font family. The family in effect is always offered
    /// by the picker, so this is the check that decides whether a chosen family can be
    /// used at all.
    static func isAvailableFamily(_ family: String) -> Bool {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return false }
        if NSFont(name: trimmed, size: DataStore.defaultPointSize) != nil { return true }
        return NSFontManager.shared.availableFontFamilies.contains {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    /// The families in a list that are really monospaced, measured from their own glyph
    /// advances by the appearance owner's probe rather than trusted from a flag.
    static func monospaceFamilies(_ families: [String]) -> [String] {
        families.filter { family in
            guard let font = NSFont(name: family, size: DataStore.defaultPointSize) else {
                return false
            }
            return DarkMonochromaticWindowAppearanceFeature.isMonospace(font)
        }
    }

    /// The font a document renders with for a typography setting: the configured
    /// monospace family at the configured point size. Reuses the persistence owner's
    /// resolution, so the window and a relaunch render the same font.
    static func resolvedFont(for typography: TypographySettings) -> NSFont {
        PersistTypographyAndKeybindingsInUserdefaultsFeature.resolvedFont(for: typography)
    }

    // MARK: - Applying a change

    /// Applies a draft without a document surface: the values are validated, written and
    /// published, which is what a change made before a note is open needs.
    @discardableResult
    func apply(_ draft: Draft) throws -> ApplyResult {
        try apply(draft, to: nil)
    }

    /// Applies a draft, and puts the resulting font on the open document's text view.
    ///
    /// Terminal paths:
    /// * A cancelled change throws `CancellationError`, writes nothing, publishes nothing
    ///   and leaves the surface alone.
    /// * A draft whose font family is unavailable is rejected: the previous family and
    ///   point size stand in the window, in the store and on the surface, and the result
    ///   carries the exact inline message naming the family.
    /// * A draft the store refuses throws the store's own error, keeps the last valid
    ///   settings and reports the store's reason inline.
    /// * An accepted draft writes both settings through the one gate, applies the font to
    ///   `textView` immediately, and carries no message.
    ///
    /// - Parameters:
    ///   - draft: the values the window is asking for.
    ///   - textView: the open document's text view, or `nil` when no note is open. The
    ///     surface is only ever given a font that was really persisted.
    @discardableResult
    func apply(_ draft: Draft, to textView: NSTextView?) throws -> ApplyResult {
        applyState = .active

        // Cancellation branch: a change that was interrupted before it was written must
        // not reach the store or the surface. The last valid state stands.
        guard !Task.isCancelled else {
            applyState = .cancelled
            inlineMessage = Self.cancelledMessage
            let result = ApplyResult(
                typography: typography,
                keybindings: keybindings,
                inlineMessage: inlineMessage,
                accepted: false
            )
            lastResult = result
            throw CancellationError()
        }

        let previous = Draft(typography: typography, keybindings: keybindings)

        // The unavailable-family gate. The whole draft is rejected rather than partially
        // applied: "keeps the previous font family" plus "preserve the last valid state"
        // means the window must not swap in a size that belongs to a font it refused.
        guard Self.isAvailableFamily(draft.typography.fontFamily) else {
            applyState = .failed
            inlineMessage = Self.unavailableFamilyMessage(for: draft.typography.fontFamily)
            let result = ApplyResult(
                typography: previous.typography,
                keybindings: previous.keybindings,
                inlineMessage: inlineMessage,
                accepted: false
            )
            lastResult = result
            return result
        }

        // Typography first: the document follows the change immediately.
        do {
            _ = try persist.applyTypography(draft.typography)
        } catch {
            // The store refused the change: nothing was written, the last valid settings
            // stand, and the refusal is explained inline. The store's own error is what
            // the caller sees, exactly as the persistence owner reports it.
            _ = record(
                failureOf: previous,
                message: persist.lastStatusMessage?.text
            )
            throw error
        }
        typography = draft.typography
        if let textView {
            textView.font = Self.resolvedFont(for: draft.typography)
        }

        // Then the keybindings. A refusal here keeps the typography that really was
        // written and the keybindings that really are still in effect.
        do {
            _ = try persist.applyKeybindings(draft.keybindings)
        } catch {
            _ = record(
                failureOf: Draft(typography: typography, keybindings: previous.keybindings),
                message: persist.lastStatusMessage?.text
            )
            throw error
        }
        keybindings = draft.keybindings

        inlineMessage = nil
        applyState = .succeeded
        let result = ApplyResult(
            typography: typography,
            keybindings: keybindings,
            inlineMessage: nil,
            accepted: true
        )
        lastResult = result
        return result
    }

    // MARK: - Accessibility

    /// The window's controls, grouped the way the window lays them out.
    struct Controls: Equatable, Sendable {
        /// The font family picker.
        let fontFamily: AccessibilityElement
        /// The point size stepper.
        let pointSize: AccessibilityElement
        /// One element per keybinding row, in menu order.
        let keyBindings: [AccessibilityElement]

        /// Every control in focus order: font family, point size, then the rows.
        var all: [AccessibilityElement] { [fontFamily, pointSize] + keyBindings }
    }

    /// The window's controls for the settings currently in effect.
    func controls() -> Controls {
        controls(for: Draft(typography: typography, keybindings: keybindings))
    }

    /// The window's controls for an explicit draft. Values are the draft's, so the spoken
    /// values follow the window as the user changes it.
    func controls(for draft: Draft) -> Controls {
        Controls(
            fontFamily: AccessibilityElement(
                role: .fontFamilyPicker,
                command: nil,
                identifier: Accessibility.fontFamilyIdentifier,
                label: Accessibility.fontFamilyLabel,
                value: draft.typography.fontFamily,
                hint: Accessibility.fontFamilyHint
            ),
            pointSize: AccessibilityElement(
                role: .pointSizeStepper,
                command: nil,
                identifier: Accessibility.pointSizeIdentifier,
                label: Accessibility.pointSizeLabel,
                value: Self.pointSizeValueText(draft.typography.pointSize),
                hint: Accessibility.pointSizeHint
            ),
            keyBindings: Command.allCases.map { command in
                AccessibilityElement(
                    role: .keyBindingPicker,
                    command: command,
                    identifier: Accessibility.keyBindingIdentifier(for: command),
                    label: Accessibility.keyBindingLabel(for: command),
                    value: Self.binding(for: command, in: draft.keybindings).displayString,
                    hint: Accessibility.keyBindingHint(for: command)
                )
            }
        )
    }

    /// The window's controls for the settings currently in effect, in focus order.
    func accessibilityElements() -> [AccessibilityElement] {
        controls().all
    }

    /// The window's controls for an explicit draft, in focus order: font family, point
    /// size, then one row per command. This is the surface the window renders.
    func accessibilityElements(for draft: Draft) -> [AccessibilityElement] {
        controls(for: draft).all
    }

    /// A point size in spoken form: "13 pt", not "13.0 pt".
    static func pointSizeValueText(_ pointSize: Double) -> String {
        let whole = pointSize.rounded() == pointSize ? String(Int(pointSize)) : String(pointSize)
        return whole + " pt"
    }

    // MARK: - Private

    /// Records a refused write: nothing is published as applied beyond what really was
    /// written, the reason is reported inline, and the result keeps the last valid state.
    private func record(failureOf previous: Draft, message: String?) -> ApplyResult {
        applyState = .failed
        inlineMessage = message ?? Self.refusedChangeMessage
        let result = ApplyResult(
            typography: previous.typography,
            keybindings: previous.keybindings,
            inlineMessage: inlineMessage,
            accepted: false
        )
        lastResult = result
        return result
    }
}

// MARK: - The Settings window surface

/// The Settings window (CON-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS-INTERFACE):
/// a font family picker, a point size stepper and one keybinding row per command.
///
/// Every control renders its visible label from the feature's accessibility element and
/// carries that element's label, value, hint and identifier, so the window is operable
/// with VoiceOver and with the keyboard, and the spoken values follow the settings as
/// they change. A change is applied immediately: it reaches the open document's text
/// view and UserDefaults at once, and a change the app refused leaves the previous
/// settings on screen with the inline message underneath.
struct SettingsView: View {

    /// The window's owner, under a short local name.
    typealias Model = SettingsWindowForTypographyAndKeybindingsFeature

    private let feature: Model
    private let documentTextView: () -> NSTextView?
    private let onApply: (Model.ApplyResult) -> Void

    /// The values the window is editing, seeded from the store when the window opens.
    @State private var draft: Model.Draft
    @State private var inlineMessage: String?

    /// The window heading, and the two section headings.
    static let title: String = "Settings"
    static let typographySectionTitle: String = "Typography"
    static let keyBindingsSectionTitle: String = "Keybindings"

    /// The locked window background (#000000) and the contrast-checked text colour,
    /// reused from the appearance owner so the Settings window matches the document
    /// surface instead of carrying a colour of its own.
    static var backgroundColor: NSColor {
        DarkMonochromaticWindowAppearanceFeature.backgroundColor.nsColor
    }

    static var textColor: NSColor {
        DarkMonochromaticWindowAppearanceFeature.foregroundColor(preferred: .white).nsColor
    }

    @MainActor
    init(
        feature: Model,
        documentTextView: @escaping () -> NSTextView? = { nil },
        onApply: @escaping (Model.ApplyResult) -> Void = { _ in }
    ) {
        self.feature = feature
        self.documentTextView = documentTextView
        self.onApply = onApply
        _draft = State(initialValue: feature.currentDraft())
        _inlineMessage = State(initialValue: feature.inlineMessage)
    }

    var body: some View {
        let controls = feature.controls(for: draft)

        Form {
            Section {
                Picker(
                    selection: fontFamilySelection
                ) {
                    ForEach(feature.availableFontFamilies(), id: \.self) { family in
                        Text(family).tag(family)
                    }
                } label: {
                    Text(controls.fontFamily.label)
                }
                .pickerStyle(.menu)
                .accessibilityLabel(Text(controls.fontFamily.label))
                .accessibilityValue(Text(controls.fontFamily.value))
                .accessibilityHint(Text(controls.fontFamily.hint))
                .accessibilityIdentifier(controls.fontFamily.identifier)

                Stepper(
                    value: pointSizeSelection,
                    in: Model.pointSizeRange,
                    step: Model.pointSizeStep
                ) {
                    HStack {
                        Text(controls.pointSize.label)
                        Spacer()
                        Text(controls.pointSize.value)
                            .monospacedDigit()
                            .foregroundStyle(Color(nsColor: Self.textColor).opacity(0.7))
                    }
                }
                .accessibilityLabel(Text(controls.pointSize.label))
                .accessibilityValue(Text(controls.pointSize.value))
                .accessibilityHint(Text(controls.pointSize.hint))
                .accessibilityIdentifier(controls.pointSize.identifier)

                fontPreview
            } header: {
                Text(Self.typographySectionTitle)
                    .accessibilityAddTraits(.isHeader)
            }

            Section {
                ForEach(controls.keyBindings) { element in
                    keyBindingRow(element)
                }
            } header: {
                Text(Self.keyBindingsSectionTitle)
                    .accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Changes apply immediately and are remembered between launches.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: Self.textColor).opacity(0.6))
            }

            if let message = inlineMessage {
                Section {
                    Label {
                        Text(message)
                            .font(.system(size: 12, design: .monospaced))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.55))
                    .accessibilityLabel(Text(Model.Accessibility.inlineMessageLabel))
                    .accessibilityValue(Text(message))
                    .accessibilityIdentifier(Model.Accessibility.inlineMessageIdentifier)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minWidth: 420, maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color(nsColor: Self.textColor))
        .background(Color(nsColor: Self.backgroundColor))
        .navigationTitle(Self.title)
    }

    /// A sample of the document text in the chosen family and size.
    private var fontPreview: some View {
        let font = NSFont(name: draft.typography.fontFamily, size: draft.typography.pointSize)
            ?? NSFont.monospacedSystemFont(ofSize: draft.typography.pointSize, weight: .regular)
        return Text("The quick brown fox jumps over the lazy dog.\n0123456789 {}[]()<>=+-*/")
            .font(Font(font))
            .foregroundStyle(Color(nsColor: Self.textColor))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: Self.backgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: Self.textColor).opacity(0.15), lineWidth: 1)
            )
            .accessibilityLabel(Text("Font preview"))
    }

    /// One keybinding assignment row: the command, its binding in effect, and the key
    /// combinations the row offers.
    @ViewBuilder
    private func keyBindingRow(_ element: Model.AccessibilityElement) -> some View {
        if let command = element.command {
            Picker(selection: keyBindingSelection(for: command)) {
                ForEach(keyBindingOptions(for: command), id: \.self) { binding in
                    Text(binding.displayString).tag(binding)
                }
            } label: {
                Text(command.displayName)
            }
            .pickerStyle(.menu)
            .accessibilityLabel(Text(element.label))
            .accessibilityValue(Text(element.value))
            .accessibilityHint(Text(element.hint))
            .accessibilityIdentifier(element.identifier)
        }
    }

    // MARK: - Draft plumbing

    private var fontFamilySelection: Binding<String> {
        Binding(
            get: { draft.typography.fontFamily },
            set: { family in
                var candidate = draft
                candidate.typography.fontFamily = family
                applyDraft(candidate)
            }
        )
    }

    private var pointSizeSelection: Binding<Double> {
        Binding(
            get: { draft.typography.pointSize },
            set: { pointSize in
                var candidate = draft
                candidate.typography.pointSize = pointSize
                applyDraft(candidate)
            }
        )
    }

    private func keyBindingOptions(for command: Model.Command) -> [KeyBinding] {
        Model.keyBindingChoices(for: command, current: currentBinding(for: command))
    }

    private func currentBinding(for command: Model.Command) -> KeyBinding {
        Model.binding(for: command, in: draft.keybindings)
    }

    private func keyBindingSelection(for command: Model.Command) -> Binding<KeyBinding> {
        Binding(
            get: { currentBinding(for: command) },
            set: { binding in
                var keybindings = draft.keybindings
                switch command {
                case .open: keybindings.open = binding
                case .save: keybindings.save = binding
                case .saveAs: keybindings.saveAs = binding
                case .search: keybindings.search = binding
                case .settings: keybindings.settings = binding
                }
                var candidate = draft
                candidate.keybindings = keybindings
                applyDraft(candidate)
            }
        )
    }

    /// Applies one change immediately. An accepted change updates the window and the
    /// document; a refused change puts the last valid settings back into the controls and
    /// shows the inline message.
    private func applyDraft(_ candidate: Model.Draft) {
        do {
            let result = try feature.apply(candidate, to: documentTextView())
            draft = Model.Draft(typography: result.typography, keybindings: result.keybindings)
            inlineMessage = result.inlineMessage
            onApply(result)
        } catch {
            let current = feature.currentDraft()
            draft = current
            inlineMessage = feature.inlineMessage
            onApply(
                Model.ApplyResult(
                    typography: current.typography,
                    keybindings: current.keybindings,
                    inlineMessage: inlineMessage,
                    accepted: false
                )
            )
        }
    }
}
