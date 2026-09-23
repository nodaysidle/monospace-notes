//
//  PersistTypographyAndKeybindingsInUserdefaultsFeature.swift
//  MonospaceNotes
//
//  TASK-13-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS — owner
//  OWN-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS.
//
//  Owns FEAT-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS:
//
//    * CON-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-INTERFACE — "the app
//      reads typography and keybinding values from UserDefaults at launch and writes
//      them whenever they change. Missing values fall back to the defaults: font
//      family Menlo, point size 13, and Cmd+S for save."
//    * CON-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS-RECOVERY — "if a
//      stored value is missing or invalid, the app uses the default value for that
//      setting and continues launching." The fallback is automatic, the setting stays
//      usable, and no user retry is required.
//
//  What this owner is
//  ------------------
//  The single read/write gate between the app and the persisted typography and
//  keybinding settings (CON-DATA-TYPOGRAPHY-SETTINGS, CON-DATA-KEYBINDING-SETTINGS,
//  CON-PERSISTENCE-TYPOGRAPHY-SETTINGS, CON-PERSISTENCE-KEYBINDING-SETTINGS). It
//  never reaches into persistence on its own: every read and every write goes through
//  the injected `SettingsStoring` (`DataStore` in the app), whose versioned
//  `com.monospace.notes.settings.v1.*` keys and whose validation rules stay the single
//  source of truth. Nothing here re-implements a key string or a validation rule — the
//  probe below calls `DataStore`'s own published constants and validators.
//
//  Why the optional `UserDefaults` probe exists
//  -------------------------------------------
//  A load that fell back and a load that found the documented default *stored by the
//  user* produce the same value, so `loadAtLaunch()` cannot tell them apart from the
//  loaded value alone. The optional `defaults` probe is the same suite the store reads,
//  consulted only through `DataStore.storedFontFamily(_:)`, `DataStore.storedPointSize(_:)`
//  and `DataStore.KeybindingRecord`. With the probe the report names what was stored and
//  which setting had to fall back; without it the feature still applies, reports and
//  substitutes every value it cannot render, but it cannot tell a stored value from a
//  documented default the store itself substituted, so it reports no fallback in that
//  case rather than inventing one.
//
//  What the launch read guarantees
//  -------------------------------
//  `loadAtLaunch()` cannot fail and never throws: every unusable value is substituted
//  with the documented default and reported in `Resolution.appliedFallbacks`, which is
//  exactly the recovery the contract asks for ("continues launching ... require no user
//  retry"). A launch read also never writes: the values it resolved are not persisted
//  behind the user's back, so an untouched install still has no stored settings after
//  the first launch.
//
//  Invariants honoured here
//  ------------------------
//    * No network APIs and no third-party dependencies.
//    * No file I/O at all: the settings travel through the injected store, which
//      `DataStore` keeps in `UserDefaults`. `UserDefaults` is used for typography and
//      keybindings only; nothing else is persisted by this feature.
//    * The document buffer and the workspace folder reference are never read, never
//      written, and never persisted here.
//    * Every operation is idle / active / succeeded / failed / cancelled; a failed or
//      cancelled operation publishes nothing and the last valid settings stand.
//    * A failed write is reported non-modally. The documented fallback needs no user
//      retry, so this feature never presents a modal alert.
//    * Reporting values name settings and reasons only — never note contents, buffers,
//      or file paths.
//    * This feature holds no task, stream, file handle, or delegate, so every terminal
//      path is clean by construction: there is nothing to cancel or close beyond the
//      cancellation entry check of a change that has not been written yet.
//

import AppKit
import Foundation

@MainActor
final class PersistTypographyAndKeybindingsInUserdefaultsFeature {

    // MARK: - Locked surface

    /// Everything the app needs from the persisted settings at launch: the values it
    /// renders and binds with, plus one entry per setting that had to fall back.
    struct Resolution: Equatable, Sendable {
        /// The typography the document surface renders with. Always renderable:
        /// `resolvedFont(for:)` can draw it.
        var typography: TypographySettings
        /// The keybindings the command surface installs. Always complete: every
        /// command has a binding with a key.
        var keybindings: KeybindingSettings
        /// One message per setting the launch read resolved to a documented default,
        /// each naming its setting (`typography` / `keybindings`) and the cause. Empty
        /// when every stored value was usable. A missing value on a first launch is
        /// listed because the documented default really was applied — it is not an
        /// error, and it never asks for a retry.
        var appliedFallbacks: [String]
    }

    /// The five commands the keybindings drive. `rawValue` is stable and used in
    /// reports; `displayName` is the menu-facing name.
    enum Command: String, Sendable, Equatable, CaseIterable {
        case open
        case save
        case saveAs
        case search
        case settings

        var displayName: String {
            switch self {
            case .open: return "Open"
            case .save: return "Save"
            case .saveAs: return "Save As"
            case .search: return "Search"
            case .settings: return "Settings"
            }
        }
    }

    /// The two persisted settings this owner is responsible for. The raw value is the
    /// name that appears in `Resolution.appliedFallbacks`.
    enum FallbackSetting: String, Sendable, Equatable, CaseIterable {
        case typography
        case keybindings
    }

    /// Why a setting was resolved to its documented default. The launch read reports
    /// the cause, and never an error the user would have to act on.
    enum FallbackCause: String, Sendable, Equatable {
        /// Nothing was stored for the setting — the documented default of a first
        /// launch.
        case noStoredValue
        /// Something was stored and it cannot be used — the documented fallback that
        /// keeps the app launching.
        case invalidStoredValue
    }

    /// One applied fallback: the setting it belongs to, why it was applied, and the
    /// exact message that is reported.
    struct Fallback: Equatable, Sendable, CustomStringConvertible {
        /// The setting that fell back.
        let setting: FallbackSetting
        /// Why it fell back.
        let cause: FallbackCause
        /// The reported message, starting with the setting's name.
        let message: String

        var description: String { message }
    }

    // MARK: - Documented defaults

    /// Menlo at 13 points: the typography a launch with no usable stored value
    /// renders with. `DataStore.defaultFontFamily` / `DataStore.defaultPointSize` are
    /// the same values, published by the persistence owner.
    static let defaultTypography: TypographySettings = .default

    /// Cmd+O, Cmd+S, Shift+Cmd+S, Cmd+F, Cmd+, — the keybindings a launch with no
    /// usable stored set installs.
    static let defaultKeybindings: KeybindingSettings = .default

    /// The default set in menu form: "⌘O, ⌘S, ⇧⌘S, ⌘F, ⌘,".
    static let defaultKeybindingSummary: String = {
        let defaults = KeybindingSettings.default
        return [defaults.open, defaults.save, defaults.saveAs, defaults.search, defaults.settings]
            .map(\.displayString)
            .joined(separator: ", ")
    }()

    /// The setting names that appear in `Resolution.appliedFallbacks`.
    static let typographyFallbackSettingName: String = FallbackSetting.typography.rawValue
    static let keybindingsFallbackSettingName: String = FallbackSetting.keybindings.rawValue

    // MARK: - Injected services

    /// The typography and keybinding persistence seam (CON-DATA-TYPOGRAPHY-SETTINGS /
    /// CON-DATA-KEYBINDING-SETTINGS). `DataStore` in the app.
    private let store: any SettingsStoring

    /// The same defaults suite the store reads, used only to tell a missing stored value
    /// from an invalid one. `nil` when no probe is available: every value the store hands
    /// back that cannot be rendered is still substituted and reported, but a value that
    /// merely equals the documented default is taken at face value.
    private let defaults: UserDefaults?

    /// - Parameters:
    ///   - store: the settings store the launch read and every change go through. The
    ///     default is the real store, so the composition root persists the user's
    ///     choices in `UserDefaults`.
    ///   - defaults: the suite `store` reads, consulted through `DataStore`'s own key
    ///     constants and validators to report *why* a setting fell back. Pass `nil`
    ///     (the default) when the store is not a `DataStore`.
    init(store: any SettingsStoring = DataStore(), defaults: UserDefaults? = nil) {
        self.store = store
        self.defaults = defaults
    }

    // MARK: - The effective settings and their operation states

    /// The launch read's state: idle before the read, active while it runs, and
    /// succeeded once the resolution is published. It is never `.failed`: every
    /// unusable value becomes an applied fallback, because the contract requires the
    /// app to keep launching.
    private(set) var launchState: OperationState = .idle

    /// The state of the last typography change.
    private(set) var typographyApplyState: OperationState = .idle

    /// The state of the last keybinding change.
    private(set) var keybindingApplyState: OperationState = .idle

    /// The typography in effect. `TypographySettings.default` (Menlo, 13 pt) until the
    /// first launch read, so the app always has a renderable value.
    private(set) var typography: TypographySettings = .default

    /// The keybindings in effect. `KeybindingSettings.default` until the first launch
    /// read, so every command always has a binding.
    private(set) var keybindings: KeybindingSettings = .default

    /// The fallbacks applied by the most recent launch read, one per affected setting.
    /// A successful write of a usable value for a setting resolves that setting's
    /// entry: the stored value is then the user's explicit choice.
    private(set) var fallbacks: [Fallback] = []

    /// The non-modal explanation of the last failed or cancelled change; `nil` when
    /// the last change succeeded or nothing has been changed yet.
    private(set) var lastStatusMessage: StatusMessage?

    /// The fallback messages of the most recent launch read, in report form.
    var appliedFallbacks: [String] { fallbacks.map(\.message) }

    // MARK: - Launch read

    /// Reads the persisted typography and keybindings for a launch (or a relaunch of
    /// the same suite) and returns the values the app renders and binds with.
    ///
    /// Terminal behaviour:
    /// * A stored, usable value is used as it is.
    /// * A missing value resolves to its documented default and is reported with
    ///   cause `.noStoredValue`.
    /// * A stored but unusable value resolves to its documented default and is reported
    ///   with cause `.invalidStoredValue`.
    /// * The read never throws, never fails, and never writes: the app continues
    ///   launching and the setting stays usable, which is the whole recovery contract.
    func loadAtLaunch() -> Resolution {
        launchState = .active

        let (resolvedTypography, typographyFallback) = resolveTypography()
        let (resolvedKeybindings, keybindingsFallback) = resolveKeybindings()

        let applied = [typographyFallback, keybindingsFallback].compactMap { $0 }

        typography = resolvedTypography
        keybindings = resolvedKeybindings
        fallbacks = applied
        launchState = .succeeded

        return Resolution(
            typography: resolvedTypography,
            keybindings: resolvedKeybindings,
            appliedFallbacks: applied.map(\.message)
        )
    }

    // MARK: - Changes

    /// Writes a typography change through the settings store and makes it the
    /// typography in effect.
    ///
    /// A rejected value (an empty family, a non-finite, `<= 0` or `> 512` point size)
    /// throws the store's own error, publishes nothing, and leaves the previous
    /// settings in effect and in `UserDefaults` — the last valid state. A change
    /// cancelled before it was written throws `CancellationError` and writes nothing.
    @discardableResult
    func applyTypography(_ typography: TypographySettings) throws -> TypographySettings {
        guard !Task.isCancelled else {
            typographyApplyState = .cancelled
            lastStatusMessage = StatusMessage(
                text: "Typography settings were not saved: the change was cancelled. "
                    + "The previous settings are unchanged.",
                isFailure: false
            )
            throw CancellationError()
        }

        typographyApplyState = .active
        do {
            try store.storeTypography(typography)
        } catch {
            typographyApplyState = .failed
            lastStatusMessage = StatusMessage(
                text: "Typography settings were not saved: \(Self.reason(for: error)) "
                    + "The previous settings are unchanged.",
                isFailure: true
            )
            throw error
        }

        self.typography = typography
        // The user's explicit choice replaces the launch fallback for this setting.
        fallbacks.removeAll { $0.setting == .typography }
        typographyApplyState = .succeeded
        lastStatusMessage = nil
        return typography
    }

    /// Writes a keybinding change through the settings store and makes it the set the
    /// command surface resolves against.
    ///
    /// A rejected value (a binding without a key) throws the store's own error,
    /// publishes nothing, and leaves the previous set in effect and in `UserDefaults`.
    /// A change cancelled before it was written throws `CancellationError` and writes
    /// nothing.
    @discardableResult
    func applyKeybindings(_ keybindings: KeybindingSettings) throws -> KeybindingSettings {
        guard !Task.isCancelled else {
            keybindingApplyState = .cancelled
            lastStatusMessage = StatusMessage(
                text: "Keybinding settings were not saved: the change was cancelled. "
                    + "The previous settings are unchanged.",
                isFailure: false
            )
            throw CancellationError()
        }

        keybindingApplyState = .active
        do {
            try store.storeKeybindings(keybindings)
        } catch {
            keybindingApplyState = .failed
            lastStatusMessage = StatusMessage(
                text: "Keybinding settings were not saved: \(Self.reason(for: error)) "
                    + "The previous settings are unchanged.",
                isFailure: true
            )
            throw error
        }

        self.keybindings = keybindings
        fallbacks.removeAll { $0.setting == .keybindings }
        keybindingApplyState = .succeeded
        lastStatusMessage = nil
        return keybindings
    }

    // MARK: - Command resolution

    /// The binding assigned to `command` in the settings currently in effect.
    func keybinding(for command: Command) -> KeyBinding {
        switch command {
        case .open: return keybindings.open
        case .save: return keybindings.save
        case .saveAs: return keybindings.saveAs
        case .search: return keybindings.search
        case .settings: return keybindings.settings
        }
    }

    /// The command a key binding triggers, or `nil` when no single command owns it.
    ///
    /// `nil` means exactly one of two things, and deliberately does not guess between
    /// them: the binding is unbound (no command has it — e.g. the old default after the
    /// user moved a command to another key), or it is ambiguous (two commands share it,
    /// which a stored set is allowed to contain). `conflictingBindings` names the
    /// ambiguous ones.
    func command(for binding: KeyBinding) -> Command? {
        let matching = Command.allCases.filter { keybinding(for: $0) == binding }
        guard matching.count == 1 else { return nil }
        return matching[0]
    }

    /// The bindings assigned to more than one command, in the order they are first
    /// seen. Empty for every set the settings surface can produce with distinct keys.
    var conflictingBindings: [KeyBinding] {
        var owner: [KeyBinding: Command] = [:]
        var conflicts: [KeyBinding] = []
        for command in Command.allCases {
            let binding = keybinding(for: command)
            if owner[binding] != nil {
                if !conflicts.contains(binding) {
                    conflicts.append(binding)
                }
            } else {
                owner[binding] = command
            }
        }
        return conflicts
    }

    /// The binding assigned to every command, in the order the File menu presents them.
    /// The command surface installs these on the menu items and on the key equivalents.
    var commandBindings: [(command: Command, binding: KeyBinding)] {
        Command.allCases.map { ($0, keybinding(for: $0)) }
    }

    // MARK: - Rendering

    /// The font a document surface renders `typography` with: the configured monospace
    /// family at the configured point size, or the system monospace face at the same
    /// size when the family is unavailable. The size is sanitised first, so a value the
    /// settings never allowed cannot reach AppKit.
    static func resolvedFont(for typography: TypographySettings) -> NSFont {
        let size = usablePointSize(typography.pointSize)
        let family = typography.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if family.isEmpty == false, let requested = NSFont(name: family, size: size) {
            return requested
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// A point size AppKit can draw: the configured one when it satisfies the settings
    /// rule (`DataStore.isStorablePointSize(_:)` — finite, greater than 0, at most
    /// 512), otherwise the documented default (13 pt).
    static func usablePointSize(_ pointSize: Double) -> Double {
        DataStore.isStorablePointSize(pointSize) ? pointSize : DataStore.defaultPointSize
    }

    /// Puts a resolution on a real document text view: the resolved family and point
    /// size. This is what "the text view uses 16 points" means on screen, and it is how
    /// the launch read is applied to the surface the user types into.
    @discardableResult
    func apply(_ resolution: Resolution, to textView: NSTextView) -> NSFont {
        let font = Self.resolvedFont(for: resolution.typography)
        textView.font = font
        return font
    }

    // MARK: - Private: resolution

    /// Resolves the typography the launch renders with and the report entry it needs.
    ///
    /// Two checks, in this order: first the value the store handed back must be
    /// renderable at all (the last gate before the font reaches the text view), then
    /// the probe says whether anything usable was stored. Both checks substitute
    /// `DataStore`'s documented defaults and never throw.
    private func resolveTypography() -> (TypographySettings, Fallback?) {
        let loaded = store.loadTypography()
        var family = loaded.fontFamily
        var pointSize = loaded.pointSize

        let familyCause = causeForLoadedFamily(loaded.fontFamily)
        if familyCause != nil {
            family = DataStore.defaultFontFamily
        }

        let pointSizeCause = causeForLoadedPointSize(loaded.pointSize)
        if pointSizeCause != nil {
            pointSize = DataStore.defaultPointSize
        }

        let applied = TypographySettings(fontFamily: family, pointSize: pointSize)

        guard let cause = Self.combinedCause(familyCause, pointSizeCause) else {
            return (applied, nil)
        }

        let detail = Self.typographyDetail(
            familyCause: familyCause,
            pointSizeCause: pointSizeCause,
            familyFallback: familyCause != nil,
            pointSizeFallback: pointSizeCause != nil
        )
        var used: [String] = []
        if familyCause != nil {
            used.append("\(DataStore.defaultFontFamily) for the font family")
        }
        if pointSizeCause != nil {
            used.append("\(Self.pointSizeText(DataStore.defaultPointSize)) pt for the point size")
        }

        return (
            applied,
            Fallback(
                setting: .typography,
                cause: cause,
                message: "\(Self.typographyFallbackSettingName): \(detail); using "
                    + used.joined(separator: " and ") + "."
            )
        )
    }

    /// Resolves the keybindings the launch installs and the report entry it needs.
    private func resolveKeybindings() -> (KeybindingSettings, Fallback?) {
        let loaded = store.loadKeybindings()

        // Last gate: a set with a binding that has no key can never be triggered, so it
        // must not reach the command surface.
        if let reason = DataStore.invalidKeybindingReason(loaded) {
            return (
                Self.defaultKeybindings,
                Self.keybindingsFallback(cause: .invalidStoredValue, detail: reason)
            )
        }

        switch storedKeybindingState() {
        case .absent:
            return (
                Self.defaultKeybindings,
                Self.keybindingsFallback(
                    cause: .noStoredValue,
                    detail: "no keybinding set is stored"
                )
            )
        case .undecodable:
            return (
                Self.defaultKeybindings,
                Self.keybindingsFallback(
                    cause: .invalidStoredValue,
                    detail: "the stored keybinding set is invalid"
                )
            )
        case .decodable, .none:
            return (loaded, nil)
        }
    }

    /// Why the loaded font family cannot be used, or `nil` when it can.
    private func causeForLoadedFamily(_ family: String) -> FallbackCause? {
        guard Self.canRenderFamily(family) else { return .invalidStoredValue }
        switch storedFamilyState() {
        case .absent: return .noStoredValue
        case .invalid: return .invalidStoredValue
        case .usable, .none: return nil
        }
    }

    /// Why the loaded point size cannot be used, or `nil` when it can.
    private func causeForLoadedPointSize(_ pointSize: Double) -> FallbackCause? {
        guard Self.canRenderPointSize(pointSize) else { return .invalidStoredValue }
        switch storedPointSizeState() {
        case .absent: return .noStoredValue
        case .invalid: return .invalidStoredValue
        case .usable, .none: return nil
        }
    }

    /// A family can be rendered when it is not blank. An unavailable family is not a
    /// fallback here: the settings contract for an unavailable family belongs to the
    /// settings surface, and `resolvedFont(for:)` still draws the configured size.
    private static func canRenderFamily(_ family: String) -> Bool {
        !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A point size can be rendered when it satisfies the settings rule the store
    /// publishes (`DataStore.isStorablePointSize(_:)`).
    private static func canRenderPointSize(_ pointSize: Double) -> Bool {
        DataStore.isStorablePointSize(pointSize)
    }

    /// The reported cause when both parts are considered together: an invalid stored
    /// value is the more actionable signal, so it wins over a missing one.
    private static func combinedCause(
        _ first: FallbackCause?,
        _ second: FallbackCause?
    ) -> FallbackCause? {
        switch (first, second) {
        case (nil, nil): return nil
        case (.invalidStoredValue, _), (_, .invalidStoredValue): return .invalidStoredValue
        default: return .noStoredValue
        }
    }

    /// The detail a typography fallback reports: exactly which parts fell back and why.
    private static func typographyDetail(
        familyCause: FallbackCause?,
        pointSizeCause: FallbackCause?,
        familyFallback: Bool,
        pointSizeFallback: Bool
    ) -> String {
        if familyFallback && pointSizeFallback {
            return familyCause == .invalidStoredValue || pointSizeCause == .invalidStoredValue
                ? "the stored font family and point size were invalid"
                : "no font family or point size is stored"
        }
        if familyFallback {
            return familyCause == .invalidStoredValue
                ? "the stored font family was invalid"
                : "no font family is stored"
        }
        return pointSizeCause == .invalidStoredValue
            ? "the stored point size was invalid"
            : "no point size is stored"
    }

    private static func keybindingsFallback(cause: FallbackCause, detail: String) -> Fallback {
        Fallback(
            setting: .keybindings,
            cause: cause,
            message: "\(keybindingsFallbackSettingName): \(detail); using the documented default "
                + "set (\(defaultKeybindingSummary))."
        )
    }

    /// A point size in report form: "13", not "13.0".
    private static func pointSizeText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    // MARK: - Private: the stored-value probe

    /// What the probe found for one stored value.
    private enum StoredValueState {
        /// The key is absent.
        case absent
        /// The key holds a value the store's own validator rejects.
        case invalid
        /// The key holds a value the store's own validator accepts.
        case usable
    }

    /// What the probe found under the keybinding key.
    private enum StoredBlobState {
        /// The key is absent.
        case absent
        /// The key holds something that is not a keybinding record the store can use.
        case undecodable
        /// The key holds a record the store can use.
        case decodable
    }

    /// The stored font family, classified by `DataStore.storedFontFamily(_:)`. `nil`
    /// when no probe is available.
    private func storedFamilyState() -> StoredValueState? {
        guard let defaults else { return nil }
        guard let rawValue = defaults.object(forKey: DataStore.fontFamilyKey) else { return .absent }
        return DataStore.storedFontFamily(rawValue) == nil ? .invalid : .usable
    }

    /// The stored point size, classified by `DataStore.storedPointSize(_:)`. `nil` when
    /// no probe is available.
    private func storedPointSizeState() -> StoredValueState? {
        guard let defaults else { return nil }
        guard let rawValue = defaults.object(forKey: DataStore.pointSizeKey) else { return .absent }
        return DataStore.storedPointSize(rawValue) == nil ? .invalid : .usable
    }

    /// The stored keybinding blob, classified by `DataStore.KeybindingRecord` — the
    /// same versioned record the store decodes. `nil` when no probe is available.
    private func storedKeybindingState() -> StoredBlobState? {
        guard let defaults else { return nil }
        guard let rawValue = defaults.object(forKey: DataStore.saveKeybindingKey) else { return .absent }
        let data = rawValue as? Data
        guard let data,
              let record = try? JSONDecoder().decode(DataStore.KeybindingRecord.self, from: data),
              record.keybindingSettings != nil else {
            return .undecodable
        }
        return .decodable
    }

    // MARK: - Private

    /// The short, content-free reason a store's rejection is reported with. Every
    /// `Error` is `CustomStringConvertible`, so the store's own description is what
    /// reaches the status area.
    private static func reason(for error: Error) -> String {
        String(describing: error)
    }
}
