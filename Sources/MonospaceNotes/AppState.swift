//
//  AppState.swift
//  MonospaceNotes
//
//  TASK-01-FOUNDATION — owner OWN-FOUNDATION.
//
//  Declares the locked shared surface for Monospace Notes:
//    * Section 2   shared types
//    * Section 2.1 protocol seams
//    * Section 2.2 neutral placeholders
//    * Section 3   the single presentation owner, `AppState`
//
//  Later tasks replace stub *bodies* and add their own feature property plus a
//  default argument in `AppState.init`. They never rename, re-shape, or relocate
//  an existing member declared here.
//
//  Invariants honoured throughout this file:
//    * No network APIs and no third-party dependencies.
//    * No file I/O here: every read/write travels through the injected
//      `NoteFileAccess`, whose contract is to run off the main actor.
//    * `UserDefaults` is reached only through `SettingsStoring` (typography and
//      keybindings). The document buffer and workspace folder stay in memory.
//    * Error/status values never carry note contents, buffers, or file paths.
//

import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Section 2: shared types

enum OperationState: Sendable, Equatable {
    case idle
    case active
    case succeeded
    case failed
    case cancelled
}

struct ErrorAlert: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let message: String

    init(title: String, message: String) {
        self.id = UUID()
        self.title = title
        self.message = message
    }
}

struct StatusMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let isFailure: Bool

    init(text: String, isFailure: Bool) {
        self.id = UUID()
        self.text = text
        self.isFailure = isFailure
    }
}

struct KeyBinding: Equatable, Sendable, Hashable {
    var key: String
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool

    init(key: String,
         command: Bool = false,
         shift: Bool = false,
         option: Bool = false,
         control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    static let open = KeyBinding(key: "o", command: true)
    static let save = KeyBinding(key: "s", command: true)
    static let saveAs = KeyBinding(key: "s", command: true, shift: true)
    static let search = KeyBinding(key: "f", command: true)
    static let settings = KeyBinding(key: ",", command: true)

    /// Menu form, e.g. "⌘O", "⌘S", "⇧⌘S", "⌘F", "⌘,".
    /// Symbols follow the canonical macOS order: control, option, shift, command.
    var displayString: String {
        var symbols = ""
        if control { symbols += "⌃" }
        if option { symbols += "⌥" }
        if shift { symbols += "⇧" }
        if command { symbols += "⌘" }
        return symbols + key.uppercased()
    }
}

struct KeybindingSettings: Equatable, Sendable {
    var open: KeyBinding
    var save: KeyBinding
    var saveAs: KeyBinding
    var search: KeyBinding
    var settings: KeyBinding

    init(open: KeyBinding = .open,
         save: KeyBinding = .save,
         saveAs: KeyBinding = .saveAs,
         search: KeyBinding = .search,
         settings: KeyBinding = .settings) {
        self.open = open
        self.save = save
        self.saveAs = saveAs
        self.search = search
        self.settings = settings
    }

    /// Cmd+O, Cmd+S, Shift+Cmd+S, Cmd+F, Cmd+,
    static let `default` = KeybindingSettings()
}

struct TypographySettings: Equatable, Sendable {
    var fontFamily: String
    var pointSize: Double

    init(fontFamily: String = "Menlo", pointSize: Double = 13) {
        self.fontFamily = fontFamily
        self.pointSize = pointSize
    }

    /// Menlo at 13 points.
    static let `default` = TypographySettings()
}

enum SearchMatchField: String, Sendable, Equatable {
    case fileName
    case contents
}

struct SearchResult: Identifiable, Equatable, Sendable, Hashable {
    let url: URL
    let score: Int
    let matchedField: SearchMatchField

    var id: URL { url }
    var displayName: String { url.lastPathComponent }
}

enum AppStateError: Error, Equatable, CustomStringConvertible {
    case initializationFailed(String)
    case documentUnavailable(String)
    case unsupportedCharacter(String)

    /// Human-readable and safe to display: callers pass an operation summary,
    /// never note contents, buffers, or file paths.
    var description: String {
        switch self {
        case .initializationFailed(let detail):
            return "Initialization failed: \(detail)"
        case .documentUnavailable(let detail):
            return "Document unavailable: \(detail)"
        case .unsupportedCharacter(let detail):
            return "Unsupported character: \(detail)"
        }
    }
}

/// Single source of truth for the locked identity. Resources/ and
/// Scripts/package_app.sh must agree with these values exactly.
enum LockedIdentity {
    static let bundleIdentifier: String = "com.monospace.notes"
    static let bundleName: String = "Monospace Notes"
    static let executableName: String = "MonospaceNotes"
    static let iconName: String = "AppIcon"
    static let artifactPath: String = "dist/Monospace Notes.app"
    static let shortVersion: String = "1.0.0"
    static let buildVersion: String = "1"
    static let minimumSystemVersion: String = "14.0"
}

/// Runtime proof that file I/O never runs on the main thread.
final class FileIOThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var operations = 0
    private var violations = 0

    init() {}

    func record(isMainThread: Bool = Thread.isMainThread) {
        lock.lock()
        defer { lock.unlock() }
        operations += 1
        if isMainThread {
            violations += 1
        }
    }

    var totalOperations: Int {
        lock.lock()
        defer { lock.unlock() }
        return operations
    }

    var mainThreadViolations: Int {
        lock.lock()
        defer { lock.unlock() }
        return violations
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        operations = 0
        violations = 0
    }
}

// MARK: - Section 2.1: protocol seams

protocol NoteFileAccess: Sendable {
    /// Reads the file as UTF-8. Throws on any read or decode failure.
    func readUTF8(from url: URL) async throws -> String
    /// Same-directory temporary file + rename(2) over the destination.
    func writeAtomically(_ contents: String, to url: URL) async throws
}

protocol PanelPresenting: Sendable {
    /// Standard macOS open panel restricted to .txt. Returns nil when the user cancels.
    func chooseExistingNote() async -> URL?
    /// Standard macOS save panel restricted to .txt. Returns nil when the user cancels.
    func chooseNewNoteDestination(suggestedName: String) async -> URL?
}

protocol SettingsStoring: Sendable {
    /// Missing or invalid stored values fall back to `.default` (Menlo 13).
    func loadTypography() -> TypographySettings
    func storeTypography(_ settings: TypographySettings) throws
    /// Missing or undecodable stored values fall back to `.default` (Cmd+O/S/Shift+Cmd+S/F/,).
    func loadKeybindings() -> KeybindingSettings
    func storeKeybindings(_ settings: KeybindingSettings) throws
}

// MARK: - Section 2.2: neutral placeholders (TASK-01 only)

/// Wave-1 stand-in so the shell compiles and runs before the real services
/// land. It never fakes a success: every read or write reports the
/// unconfigured state as `AppStateError.initializationFailed`.
struct UnconfiguredNoteFileAccess: NoteFileAccess {
    init() {}

    func readUTF8(from url: URL) async throws -> String {
        throw AppStateError.initializationFailed("Note file access is not configured.")
    }

    func writeAtomically(_ contents: String, to url: URL) async throws {
        throw AppStateError.initializationFailed("Note file access is not configured.")
    }
}

/// Returns nil, i.e. "the user cancelled", so no unconfigured panel can ever
/// pretend the user chose a path.
struct UnconfiguredPanelPresenter: PanelPresenting {
    init() {}

    func chooseExistingNote() async -> URL? { nil }

    func chooseNewNoteDestination(suggestedName: String) async -> URL? { nil }
}

/// Returns the documented defaults and stores nothing, so an unconfigured
/// composition root can never claim a setting was persisted.
struct UnconfiguredSettingsStore: SettingsStoring {
    init() {}

    func loadTypography() -> TypographySettings { .default }

    func storeTypography(_ settings: TypographySettings) throws {}

    func loadKeybindings() -> KeybindingSettings { .default }

    func storeKeybindings(_ settings: KeybindingSettings) throws {}
}

// MARK: - Section 3: AppState

/// The single presentation owner. Owns presentation state, receives feature
/// services at the composition root, and hands out the three view surfaces.
///
/// Wave-1 command bodies are honest stubs: they move their operation to
/// `.failed`, report the unconfigured state through `statusMessage` /
/// `errorAlert`, and never claim a success they did not perform. The owning
/// task replaces each body; the signature stays exactly as written here.
@Observable
@MainActor
final class AppState {
    // Injected services (composition root). Defaults are replaced as services land.
    let noteFiles: any NoteFileAccess
    let panels: any PanelPresenting
    let settings: any SettingsStoring
    let ioRecorder: FileIOThreadRecorder
    /// Owner-level launch and termination coordinator (OWN-LIFECYCLE-COORDINATOR).
    /// `launchState` mirrors its launch operation state so the composition root has a
    /// single source of truth for the launch transition.
    let lifecycle: LifecycleCoordinator
    /// Filesystem permission owner (OWN-PERMISSION-COORDINATOR). Every user-selected
    /// location is reached through it, and every access scope it holds is released on
    /// termination.
    let permissions: PermissionCoordinator
    /// Cold-launch owner (OWN-COLD-LAUNCH-UNDER-100MS). Owns the measured launch
    /// transition to the first editable window; `launchState` and `isEditable` mirror
    /// its outcome, and a failed launch presents its alert and leaves no editable
    /// window.
    let coldLaunch: ColdLaunchUnder100msFeature
    /// Dark monochromatic window appearance owner
    /// (OWN-DARK-MONOCHROMATIC-WINDOW-APPEARANCE). Resolves the locked #000000
    /// window background, the contrast-checked text foreground — a configured
    /// foreground that fails the 7:1 floor is substituted automatically — and the
    /// configured monospace font for the document surface.
    let windowAppearance: DarkMonochromaticWindowAppearanceFeature
    /// Keystroke-rendering owner (OWN-KEYSTROKE-RENDERING-UNDER-16MS). Owns the
    /// measured keystroke path — insert, force TextKit 2 layout, draw — and the
    /// TextKit 2 document surface. `keystrokeState` mirrors the last keystroke's
    /// outcome (idle / active / succeeded / failed / cancelled); a failed keystroke
    /// leaves `documentText` at its last valid value.
    let keystrokeRendering: KeystrokeRenderingUnder16msFeature
    /// Typography and keybinding persistence owner
    /// (OWN-PERSIST-TYPOGRAPHY-AND-KEYBINDINGS-IN-USERDEFAULTS). Reads the stored
    /// typography and keybindings at launch through the settings store, applies the
    /// documented fallback - Menlo at 13 points and Cmd+O / Cmd+S / Shift+Cmd+S /
    /// Cmd+F / Cmd+, - for a missing or invalid stored value, and reports which
    /// settings fell back. The settings surface writes a changed setting back through it.
    let persistTypographyAndKeybindings: PersistTypographyAndKeybindingsInUserdefaultsFeature
    /// Settings-window owner (OWN-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS). Owns
    /// the font family / point size / keybinding draft, rejects a draft whose font family
    /// is unavailable (nothing is written and the document keeps its font), writes an
    /// accepted draft through the same settings gate, applies the resulting font to the
    /// open document immediately, and reports the inline message.
    let settingsWindow: SettingsWindowForTypographyAndKeybindingsFeature
    /// Explicit-save owner (OWN-EXPLICIT-SAVE-WITH-CMD-S). Owns Cmd+S: the current
    /// buffer is written to the document's own path as UTF-8 through the shared
    /// same-directory temporary-then-rename writer, a document that has no path gets a
    /// save panel first, and a failed write is reported as a MODAL alert — never in the
    /// non-modal status area, which belongs to the background autosave. Its outcome
    /// tells the composition root whether the unsaved-changes marker is cleared.
    let explicitSave: ExplicitSaveWithCmdSFeature
    /// Fuzzy-search owner (OWN-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE). Owns Cmd+F: the
    /// query is matched against note file names and note contents in the folder of the
    /// note that is open — the parent folder of the current document, held in memory
    /// only, and never written to disk — and a selected result hands back the URL of the
    /// note to open.
    let fuzzySearch: FuzzySearchAcrossTheOpenWorkspaceFeature
    /// Non-blocking background-save owner (OWN-NON-BLOCKING-BACKGROUND-SAVE). Owns the
    /// autosave timer: it fires 30000 ms after the last edit — never on Cmd+S, which
    /// `explicitSave` owns — and writes the buffer of that last edit through the same
    /// shared same-directory temporary-then-rename writer, off the main actor, so the
    /// text view keeps accepting keystrokes while the document is written. A failure is
    /// reported in the NON-MODAL status area and NEVER as a modal alert.
    let backgroundSave: NonBlockingBackgroundSaveFeature
    /// Open-and-edit owner (OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE). Owns Cmd+O: the note the
    /// user selects in the .txt-restricted open panel is read as UTF-8 through the shared
    /// note-file seam, off the main actor, and only a succeeded attempt is adopted - the
    /// buffer, the document path, the note's LAST PATH COMPONENT as the window title, and the
    /// note's parent folder as the in-memory-only workspace folder. A read that fails
    /// presents the modal "Could Not Open Note" alert naming the file and adopts nothing, so
    /// the document that is open stays displayed and unchanged.
    let openAndEdit: OpenAndEditAPlainTextNoteFeature
    /// Open-and-save-panel owner (OWN-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS). Owns
    /// the panel-level contract of the app: the .txt-restricted open and save panels, the exact
    /// path a selection is read from or written to, and Save As (Cmd+Shift+S), which commits the
    /// buffer to exactly the chosen path through the same shared same-directory
    /// temporary-then-rename writer Cmd+S uses. A cancelled panel adopts nothing and raises no
    /// alert; a failed write presents the modal "Could Not Save Note" alert naming the path and
    /// leaves the document on its last valid path, so the explicit retry is another Cmd+Shift+S.
    let openAndSavePanels: OpenAndSavePanelsForLocalFilesystemAccessFeature

    // Document presentation
    private(set) var documentText: String
    private(set) var documentURL: URL?
    private(set) var workspaceFolder: URL?
    private(set) var hasUnsavedChanges: Bool
    /// `documentURL?.lastPathComponent ?? LockedIdentity.bundleName`; the task
    /// that opens a document updates it.
    var windowTitle: String

    // Typography / keybindings
    private(set) var typography: TypographySettings
    private(set) var keybindings: KeybindingSettings
    /// Inline settings message, e.g. an unavailable font family.
    private(set) var settingsMessage: String?
    /// One entry per setting the launch read had to resolve to a documented default,
    /// naming the setting and the cause; empty when every stored value was usable.
    private(set) var appliedSettingsFallbacks: [String]

    // MARK: Dark monochromatic window appearance
    // FEAT-DARK-MONOCHROMATIC-WINDOW-APPEARANCE. The values below are derived from
    // `typography`, so the root view and the document surface always render the
    // configured family/size and never carry a colour that fails the contrast floor.

    /// The appearance the document surface renders: a #000000 background, a
    /// foreground that clears the locked 7:1 contrast floor (substituted
    /// automatically when the configured colour fails), and the configured
    /// monospace font at the configured point size.
    var resolvedAppearance: DarkMonochromaticWindowAppearanceFeature.ResolvedAppearance {
        windowAppearance.resolve(typography: typography)
    }

    /// The document text view's font: the configured monospace family and point
    /// size (Menlo 13 by default).
    var documentFont: NSFont { resolvedAppearance.font }

    /// The document text view's foreground colour: high-contrast against #000000.
    var documentTextColor: NSColor { resolvedAppearance.foreground.nsColor }

    /// The window background colour: #000000.
    var windowBackgroundColor: NSColor { resolvedAppearance.background.nsColor }

    /// The measured contrast ratio of the rendered text colour against the window
    /// background — at least 7:1.
    var documentContrastRatio: Double { resolvedAppearance.contrastRatio }

    // Search presentation
    /// Whether the search palette is on screen. Cmd+F presents it; Escape, a click
    /// outside it, or opening a result dismisses it and returns focus to the document.
    private(set) var isSearchPresented: Bool = false
    private(set) var searchQuery: String
    private(set) var searchResults: [SearchResult]
    private(set) var searchEmptyStateText: String?

    // Operation states
    private(set) var launchState: OperationState
    private(set) var openState: OperationState
    private(set) var saveState: OperationState
    private(set) var backgroundSaveState: OperationState
    private(set) var searchState: OperationState
    private(set) var isEditable: Bool

    // Reporting surfaces
    var errorAlert: ErrorAlert?
    var statusMessage: StatusMessage?

    /// The application-termination observer installed by `installTerminationHook()`.
    private var terminationObserver: NSObjectProtocol?

    /// When initialisation began: the start of the measured cold launch.
    private let launchStartedAt: ContinuousClock.Instant = ContinuousClock.now

    /// The concrete services are optional so that the composition root can share one
    /// `ioRecorder` with the default `DataStore`: a Swift default argument cannot
    /// reference another parameter, which would otherwise give the default store a
    /// private recorder and make `ioRecorder`'s no-main-thread-I/O proof vacuous for
    /// AppState-driven I/O.
    init(noteFiles: (any NoteFileAccess)? = nil,
         panels: (any PanelPresenting)? = nil,
         settings: (any SettingsStoring)? = nil,
         ioRecorder: FileIOThreadRecorder = FileIOThreadRecorder(),
         lifecycle: LifecycleCoordinator = LifecycleCoordinator(),
         permissions: PermissionCoordinator = PermissionCoordinator(),
         coldLaunch: ColdLaunchUnder100msFeature? = nil,
         windowAppearance: DarkMonochromaticWindowAppearanceFeature? = nil,
         keystrokeRendering: KeystrokeRenderingUnder16msFeature? = nil,
         persistTypographyAndKeybindings: PersistTypographyAndKeybindingsInUserdefaultsFeature? = nil,
         settingsWindow: SettingsWindowForTypographyAndKeybindingsFeature? = nil,
         explicitSave: ExplicitSaveWithCmdSFeature? = nil,
         fuzzySearch: FuzzySearchAcrossTheOpenWorkspaceFeature? = nil,
         backgroundSave: NonBlockingBackgroundSaveFeature? = nil,
         openAndEdit: OpenAndEditAPlainTextNoteFeature? = nil,
         openAndSavePanels: OpenAndSavePanelsForLocalFilesystemAccessFeature? = nil) {
        self.ioRecorder = ioRecorder
        self.lifecycle = lifecycle
        self.permissions = permissions

        let defaultStore = DataStore(recorder: ioRecorder)
        self.noteFiles = noteFiles ?? defaultStore
        self.panels = panels ?? NativePanelPresenter()
        self.settings = settings ?? defaultStore
        self.coldLaunch = coldLaunch
            ?? ColdLaunchUnder100msFeature(settings: settings ?? defaultStore)
        self.windowAppearance = windowAppearance
            ?? DarkMonochromaticWindowAppearanceFeature(settings: settings ?? defaultStore)
        self.keystrokeRendering = keystrokeRendering ?? KeystrokeRenderingUnder16msFeature()
        self.persistTypographyAndKeybindings = persistTypographyAndKeybindings
            ?? PersistTypographyAndKeybindingsInUserdefaultsFeature(store: settings ?? defaultStore)
        self.settingsWindow = settingsWindow
            ?? SettingsWindowForTypographyAndKeybindingsFeature(store: settings ?? defaultStore)
        self.explicitSave = explicitSave
            ?? ExplicitSaveWithCmdSFeature(
                noteFiles: noteFiles ?? defaultStore,
                panels: panels ?? NativePanelPresenter()
            )
        self.fuzzySearch = fuzzySearch
            ?? FuzzySearchAcrossTheOpenWorkspaceFeature(noteFiles: noteFiles ?? defaultStore)
        self.backgroundSave = backgroundSave
            ?? NonBlockingBackgroundSaveFeature(
                noteFiles: noteFiles ?? defaultStore,
                temporaryFileVerifier: DirectoryTemporarySaveFileVerifier(recorder: ioRecorder)
            )
        self.openAndEdit = openAndEdit
            ?? OpenAndEditAPlainTextNoteFeature(
                noteFiles: noteFiles ?? defaultStore,
                panels: panels ?? NativePanelPresenter()
            )
        self.openAndSavePanels = openAndSavePanels
            ?? OpenAndSavePanelsForLocalFilesystemAccessFeature(
                panels: panels ?? NativePanelPresenter(),
                permissions: permissions,
                noteFiles: noteFiles ?? defaultStore
            )

        self.documentText = ""
        self.documentURL = nil
        self.workspaceFolder = nil
        self.hasUnsavedChanges = false
        self.windowTitle = LockedIdentity.bundleName

        // Launch read: stored typography and keybindings, with the documented
        // defaults for missing or invalid values, reported in
        // `appliedSettingsFallbacks`. Nothing else is hydrated.
        let settingsResolution = self.persistTypographyAndKeybindings.loadAtLaunch()
        self.typography = settingsResolution.typography
        self.keybindings = settingsResolution.keybindings
        self.appliedSettingsFallbacks = settingsResolution.appliedFallbacks
        self.settingsMessage = nil

        self.searchQuery = ""
        self.searchResults = []
        self.searchEmptyStateText = nil

        self.launchState = self.lifecycle.launchState
        self.openState = .idle
        self.saveState = .idle
        self.backgroundSaveState = .idle
        self.searchState = .idle
        // The document surface is built editable; a failed launch turns it read-only.
        self.isEditable = true

        self.errorAlert = nil
        self.statusMessage = nil

        // FEAT-COLD-LAUNCH-UNDER-100MS: the launch is in flight from here until the
        // window's real document surface exists (`completeLaunch(with:)`), so the
        // measured transition covers the actual first editable window.
        self.lifecycle.beginLaunch()
        self.launchState = self.lifecycle.launchState

        // CON-LIFECYCLE-APPLICATION-TERMINATION + CON-PERMISSION-FILESYSTEM: the
        // frozen app entry carries no termination hook, so the composition root
        // installs one here.
        installTerminationHook()

        // FEAT-NON-BLOCKING-BACKGROUND-SAVE: an autosave's terminal outcome reaches the
        // presentation state through `backgroundSaveState` and the NON-MODAL
        // `statusMessage` only — a failed background save is never a modal alert, so
        // `errorAlert` is left exactly as the Cmd+S route left it.
        self.backgroundSave.onOutcome = { [weak self] outcome in
            guard let self else { return }
            self.backgroundSaveState = outcome.state
            self.statusMessage = outcome.statusMessage
        }
    }

    /// FEAT-COLD-LAUNCH-UNDER-100MS: completes the cold launch once the window's document
    /// text view exists. It succeeds when that surface is editable and accepts a
    /// keystroke; otherwise it presents "Could Not Launch" and leaves no editable window
    /// (`isEditable` becomes false). Runs once: later surfaces do not relaunch.
    func completeLaunch(with textView: NSTextView) {
        guard coldLaunch.launchState == .idle else { return }
        coldLaunch.launch(adopting: textView, since: launchStartedAt)
        launchState = coldLaunch.launchState
        isEditable = coldLaunch.isEditable
        if let launchAlert = coldLaunch.errorAlert {
            errorAlert = launchAlert
            _ = lifecycle.failLaunch(AppStateError.initializationFailed(launchAlert.message))
        } else if launchState == .succeeded {
            lifecycle.completeLaunch()
            launchState = lifecycle.launchState
        }
    }

    // MARK: Command surface (TASK-01 stubs; the owning task replaces the body)

    /// FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE: Cmd+O.
    ///
    /// The open panel is restricted to `.txt` by the permission coordinator, and the selected
    /// note is read as UTF-8 through the shared note-file seam, off the main actor. Only a
    /// succeeded attempt is adopted: the buffer, the document path, the workspace folder (the
    /// note's parent folder, in memory only and never persisted), the window title (the note's
    /// last path component) and the cleared unsaved-changes marker move together, and the
    /// opened text is written onto the live document surface as well, so the text view shows
    /// exactly the file's contents. A cancelled panel changes nothing; a read that failed
    /// presents the modal "Could Not Open Note" alert naming the file and leaves the open
    /// document displayed and unchanged, so an explicit retry (another Cmd+O) is possible.
    func openDocument() async {
        let outcome = await openAndEdit.openViaPanel()
        openState = outcome.state
        // Assigned on every terminal path: an open that did not fail (or was cancelled)
        // dismisses the alert of one that did.
        errorAlert = outcome.errorAlert

        guard outcome.opened, let url = outcome.url, let text = outcome.text else {
            // A cancelled panel and a failed read both adopt nothing: the document, its path,
            // its workspace folder and the unsaved-changes marker keep their last valid value.
            return
        }

        documentText = text
        documentURL = url
        workspaceFolder = url.deletingLastPathComponent()
        windowTitle = outcome.windowTitle ?? OpenAndEditAPlainTextNoteFeature.windowTitle(for: url)
        hasUnsavedChanges = false
        openAndEdit.adoptOpenedDocument(
            outcome,
            into: keystrokeRendering.documentTextView ?? coldLaunch.documentView
        )
    }

    /// FEAT-EXPLICIT-SAVE-WITH-CMD-S: Cmd+S.
    ///
    /// The current buffer is written to the document's own path as UTF-8 through the
    /// feature's shared same-directory atomic writer. A document without a path gets a
    /// save panel first, and the chosen path is the one written and adopted. A writer
    /// failure keeps the last valid state — the buffer, the document path and
    /// `hasUnsavedChanges` — and presents the modal alert the feature built (never the
    /// non-modal status area, which belongs to the background autosave).
    func save() async {
        let outcome = await explicitSave.save(
            text: documentText,
            documentURL: documentURL,
            // A note that has never been saved is suggested as "Untitled.txt"; the panel
            // itself stays restricted to .txt through the permission coordinator.
            suggestedName: documentURL?.lastPathComponent ?? "Untitled.txt"
        )

        saveState = outcome.state
        errorAlert = outcome.errorAlert

        if outcome.clearedUnsavedMarker {
            hasUnsavedChanges = false
        }

        // Only a succeeded attempt is adopted: a failed or cancelled save leaves the
        // document on its last valid path, buffer and unsaved-changes marker, and the
        // modal alert explains the failure so the user can retry with Cmd+S.
        if outcome.state == .succeeded, let savedURL = outcome.url {
            documentURL = savedURL
            workspaceFolder = savedURL.deletingLastPathComponent()
            windowTitle = savedURL.lastPathComponent
        }
    }

    /// FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS: Cmd+Shift+S.
    ///
    /// Save As always presents the .txt-restricted save panel — even for a document that
    /// already has a path — and commits the current buffer to EXACTLY the path the user chose,
    /// through the same shared same-directory temporary-then-rename writer Cmd+S uses, which
    /// runs that write off the main actor. Only a succeeded attempt is adopted: the document
    /// path, the workspace folder (the new destination's parent folder, in memory only), the
    /// window title and the cleared unsaved-changes marker move together. A cancelled panel
    /// adopts nothing and raises no alert; a failed write presents the modal alert the panel
    /// owner built (title exactly "Could Not Save Note", naming the path and the write error)
    /// and leaves the document on its last valid path, so the explicit retry is another
    /// Cmd+Shift+S.
    func saveAs() async {
        // CON-DATA-OPEN-DOCUMENT-BUFFER: the buffer this command commits is the live one.
        openAndSavePanels.documentText = documentText

        let outcome = await openAndSavePanels.chooseSaveDestination(
            suggestedName: OpenAndSavePanelsForLocalFilesystemAccessFeature.suggestedName(
                for: documentURL
            )
        )

        saveState = outcome.state
        // Assigned on every terminal path: an attempt that did not fail dismisses the alert of
        // one that did.
        errorAlert = openAndSavePanels.lastErrorAlert

        // Only a succeeded attempt hands back a path to adopt. A cancelled panel and a failed
        // write both leave the document, its path, its workspace folder and its
        // unsaved-changes marker at their last valid values.
        guard let savedURL = outcome.adoptedURL else { return }

        documentURL = savedURL
        workspaceFolder = savedURL.deletingLastPathComponent()
        windowTitle = savedURL.lastPathComponent
        // The buffer is on disk at the chosen path, so the document is no longer dirty —
        // exactly the rule Cmd+S applies.
        hasUnsavedChanges = false
    }

    /// FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE: Cmd+F.
    ///
    /// The folder searched is the PARENT FOLDER of the note that is open (USER
    /// CLARIFICATION 2), held in memory only. With no note open there is no folder, and
    /// the search shows the documented empty state `Open a note to search its folder`.
    /// Cmd+F is an explicit action, so it re-reads the folder once; every keystroke after
    /// it searches that in-memory workspace.
    func focusSearch() async {
        isSearchPresented = true
        let outcome = await fuzzySearch.focusSearch(
            workspaceFolder: FuzzySearchAcrossTheOpenWorkspaceFeature.workspaceFolder(
                forOpenDocumentAt: documentURL
            )
        )
        applySearchOutcome(outcome)
    }

    /// Dismisses the search palette and hands keyboard focus back to the document.
    func dismissSearch() {
        isSearchPresented = false
        focusDocument()
    }

    /// Makes the document text view the window's first responder, so typing goes to the
    /// note rather than to whichever control last had focus.
    func focusDocument() {
        guard let textView = keystrokeRendering.documentTextView,
              let window = textView.window else { return }
        window.makeFirstResponder(textView)
    }

    // MARK: Status bar presentation

    /// The open note's file name, or "Untitled" before the note has a path.
    var documentDisplayName: String {
        documentURL?.lastPathComponent ?? "Untitled"
    }

    /// The name of the folder the open note lives in (the folder search covers).
    var workspaceDisplayName: String? {
        workspaceFolder?.lastPathComponent
    }

    /// Whether the empty-document hint is shown: no note is open and nothing is typed.
    var showsEmptyDocumentHint: Bool {
        documentURL == nil && documentText.isEmpty
    }

    /// The save state in words: an autosave in flight, unsaved edits, saved, or never saved.
    var saveStateDescription: String {
        if backgroundSaveState == .active || saveState == .active { return "Saving…" }
        if hasUnsavedChanges { return "Edited" }
        return documentURL == nil ? "Not saved" : "Saved"
    }

    /// The number of whitespace-separated words in the buffer.
    var wordCount: Int {
        var count = 0
        var inWord = false
        for scalar in documentText.unicodeScalars {
            if scalar.properties.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// The number of characters (grapheme clusters) in the buffer.
    var characterCount: Int { documentText.count }

    /// FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE: one keystroke in the search field.
    /// The results, the empty-state message, the operation state and the measured
    /// keystroke-to-results latency are published; the open document is never touched, so
    /// a query with no matches leaves the current note open and unchanged.
    func updateSearchQuery(_ query: String) async {
        searchQuery = query
        let outcome = await fuzzySearch.search(
            query: query,
            workspaceFolder: FuzzySearchAcrossTheOpenWorkspaceFeature.workspaceFolder(
                forOpenDocumentAt: documentURL
            )
        )
        applySearchOutcome(outcome)
    }

    /// FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE: selecting a result opens that note.
    ///
    /// The search owner hands back exactly the selected note's URL; the note is read
    /// through the shared note-file seam (off the main actor) and adopted as the open
    /// document. A note that cannot be read presents the modal `Could Not Open Note`
    /// alert and leaves the document that was open exactly as it was.
    func selectSearchResult(_ result: SearchResult) async {
        let outcome = await fuzzySearch.openSelectedNote(result)
        searchState = outcome.state

        guard outcome.state == .succeeded, let url = outcome.url, let text = outcome.text else {
            if let alert = outcome.errorAlert { errorAlert = alert }
            return
        }

        documentText = text
        documentURL = url
        workspaceFolder = url.deletingLastPathComponent()
        windowTitle = url.lastPathComponent
        hasUnsavedChanges = false
    }

    /// Publishes one search outcome: the results, the documented empty-state text, the
    /// operation state and the measured latency. Nothing else in the presentation state is
    /// touched, which is what keeps the open document open across a search.
    private func applySearchOutcome(
        _ outcome: FuzzySearchAcrossTheOpenWorkspaceFeature.SearchOutcome
    ) {
        searchState = outcome.state
        searchResults = outcome.results
        searchEmptyStateText = outcome.emptyStateText
        if outcome.state == .failed {
            statusMessage = StatusMessage(
                text: "Search could not read this folder. The results shown are the last valid ones; press Cmd+F to retry.",
                isFailure: true
            )
        }
    }

    /// FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS: one typography change,
    /// applied through the settings-window owner together with the current keybindings.
    func setTypography(_ typography: TypographySettings) async {
        applySettingsDraft(
            SettingsWindowForTypographyAndKeybindingsFeature.Draft(
                typography: typography,
                keybindings: keybindings
            )
        )
    }

    /// FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS: one keybinding change,
    /// applied through the settings-window owner together with the current typography.
    func setKeybindings(_ keybindings: KeybindingSettings) async {
        applySettingsDraft(
            SettingsWindowForTypographyAndKeybindingsFeature.Draft(
                typography: typography,
                keybindings: keybindings
            )
        )
    }

    /// Applies one settings draft through the settings-window owner and publishes its
    /// result: the validated typography and keybindings, plus the inline message (an
    /// unavailable font family, a refused write, or none at all). The font reaches the
    /// open document's text view from the owner; a draft that was not accepted leaves the
    /// last valid settings in place.
    private func applySettingsDraft(
        _ draft: SettingsWindowForTypographyAndKeybindingsFeature.Draft
    ) {
        do {
            let result = try settingsWindow.apply(
                draft,
                to: keystrokeRendering.documentTextView ?? coldLaunch.documentView
            )
            typography = result.typography
            keybindings = result.keybindings
            settingsMessage = result.inlineMessage
        } catch {
            // The store refused the change: nothing was written, the last valid settings
            // stand, and the reason is reported inline (never as a modal alert).
            typography = settingsWindow.typography
            keybindings = settingsWindow.keybindings
            settingsMessage = settingsWindow.inlineMessage
        }
    }

    /// FEAT-KEYSTROKE-RENDERING-UNDER-16MS: the measured keystroke path.
    ///
    /// The character is inserted into the live document text view through
    /// `keystrokeRendering`, which forces TextKit 2 layout and a drawing pass and
    /// reports whether the character reached the buffer. `documentText` follows the
    /// surface, so the buffer is updated immediately after the key event. A failed
    /// keystroke leaves both the surface and `documentText` unchanged. No file read or
    /// write is reachable from here: the keystroke path holds no I/O service.
    @discardableResult
    func handleKeystrokeInsert(_ character: String) -> Bool {
        guard let textView = keystrokeRendering.documentTextView ?? coldLaunch.documentView else {
            statusMessage = StatusMessage(
                text: "Keystroke insertion is unavailable: no document surface is open.",
                isFailure: true
            )
            return false
        }
        return handleKeystrokeInsert(character, in: textView)
    }

    /// The same keystroke path against an explicit document text view (the one the
    /// document surface hands over), so the surface on screen and the buffer stay the
    /// same document.
    @discardableResult
    func handleKeystrokeInsert(_ character: String, in textView: NSTextView) -> Bool {
        keystrokeRendering.attach(textView)
        let previousBuffer = documentText
        let measurement = keystrokeRendering.insert(character, into: textView)
        documentText = textView.string
        statusMessage = measurement.inserted ? nil : keystrokeRendering.lastStatusMessage
        // FEAT-NON-BLOCKING-BACKGROUND-SAVE: every edit resets the autosave interval to
        // exactly 30000 ms from the edit itself. Nothing about the measured keystroke
        // path changes here: the measurement above has already stopped.
        if measurement.inserted {
            backgroundSave.noteEdit(buffer: documentText, documentURL: documentURL)
            // FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE (ACC-01): a keystroke that CHANGES the
            // buffer marks the document as having unsaved changes; an insert that leaves
            // the buffer identical does not. The rule itself lives in the open-and-edit
            // owner (`markEdited(previous:new:)`); the composition root publishes its
            // result here so `hasUnsavedChanges` reflects real typing.
            openAndEdit.noteEdit(previous: previousBuffer, new: documentText)
            hasUnsavedChanges = openAndEdit.hasUnsavedChanges
        }
        return measurement.inserted
    }

    /// An edit AppKit applied to the surface itself: a deletion, a selection
    /// replacement, cut, paste over a selection, or undo/redo. The buffer, the unsaved
    /// marker, and the autosave interval follow it exactly as they follow a keystroke.
    func handleDirectEdit(in textView: NSTextView) {
        let previousBuffer = documentText
        let newBuffer = textView.string
        guard newBuffer != previousBuffer else { return }
        documentText = newBuffer
        statusMessage = nil
        backgroundSave.noteEdit(buffer: documentText, documentURL: documentURL)
        openAndEdit.noteEdit(previous: previousBuffer, new: documentText)
        hasUnsavedChanges = openAndEdit.hasUnsavedChanges
    }

    /// The last keystroke's outcome, owned by the keystroke-rendering feature.
    var keystrokeState: OperationState { keystrokeRendering.keystrokeState }

    // MARK: Termination

    /// Application termination (CON-LIFECYCLE-APPLICATION-TERMINATION +
    /// CON-PERMISSION-FILESYSTEM). Releases every filesystem access scope this session
    /// took, then stops the lifecycle coordinator, which cancels and awaits its
    /// registered tasks. Safe to repeat: the release is idempotent and a repeated
    /// termination reports 0.
    @discardableResult
    func terminate() async -> Int {
        permissions.releaseAllScopes()
        keystrokeRendering.releaseSurfaceResources()
        return await lifecycle.beginTermination()
    }

    /// Wires the termination contract to the frozen app entry.
    ///
    /// MonospaceNotesApp.swift is created once by OWN-FOUNDATION and never modified
    /// again (owner map + TASKS.md "Files to modify"), so it carries no termination
    /// hook. The composition root therefore installs one here: on
    /// `NSApplication.willTerminateNotification` the guaranteed half — releasing every
    /// filesystem access scope — runs synchronously on the main thread, and the
    /// cooperative half (cancelling and awaiting registered tasks) is requested at the
    /// same instant through the single `terminate()` entry point.
    private func installTerminationHook() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, so the main actor is the current actor here.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.permissions.releaseAllScopes()
                Task { _ = await self.lifecycle.beginTermination() }
            }
        }
    }

    // MARK: View factories
    //
    // Each owning feature supplies its surface here, so MonospaceNotesApp.swift
    // never needs editing after TASK-01.

    /// FEAT-KEYSTROKE-RENDERING-UNDER-16MS: the TextKit 2 document surface. The
    /// surface renders `documentText` with the configured font and the
    /// contrast-checked colours, hands its text view to `keystrokeRendering` so the
    /// keystroke path and the buffer are the same document, and routes typed
    /// characters through `handleKeystrokeInsert(_:in:)`.
    func documentSurface() -> AnyView {
        AnyView(TextKit2DocumentView(
            state: self,
            onDocumentTextViewReady: { [weak self] textView in
                guard let self else { return }
                self.completeLaunch(with: textView)
                self.keystrokeRendering.attach(textView)
                // Preparing the drawing buffer waits for the first frame, so it never
                // delays the window; the keystroke path creates it on demand anyway.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    _ = self.keystrokeRendering.prepareSurface(textView)
                    self.focusDocument()
                }
            }
        ))
    }

    /// FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE: the search field and results list. The
    /// surface searches the folder of the note that is currently open — resolved per
    /// keystroke, so a note opened in the meantime is followed — and a click on a result
    /// routes through `selectSearchResult(_:)`.
    func searchSurface() -> AnyView {
        AnyView(FuzzySearchView(
            feature: fuzzySearch,
            workspaceFolder: { [weak self] in
                guard let self else { return nil }
                return FuzzySearchAcrossTheOpenWorkspaceFeature.workspaceFolder(
                    forOpenDocumentAt: self.documentURL
                )
            },
            onSelect: { [weak self] result in
                guard let self else { return }
                Task {
                    await self.selectSearchResult(result)
                    if self.searchState == .succeeded { self.dismissSearch() }
                }
            },
            onDismiss: { [weak self] in self?.dismissSearch() }
        ))
    }

    /// FEAT-SETTINGS-WINDOW-FOR-TYPOGRAPHY-AND-KEYBINDINGS: the Settings window surface.
    /// It drives the settings-window owner against the open document's text view, and
    /// every result it hands back is mirrored into `typography`, `keybindings` and the
    /// inline `settingsMessage`.
    func settingsSurface() -> AnyView {
        AnyView(SettingsView(
            feature: settingsWindow,
            documentTextView: { [weak self] in
                guard let self else { return nil }
                return self.keystrokeRendering.documentTextView ?? self.coldLaunch.documentView
            },
            onApply: { [weak self] result in
                guard let self else { return }
                self.typography = result.typography
                self.keybindings = result.keybindings
                self.settingsMessage = result.inlineMessage
            }
        ))
    }
}
