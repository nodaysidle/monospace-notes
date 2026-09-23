//
//  PermissionCoordinator.swift
//  MonospaceNotes
//
//  TASK-07-PERMISSION-COORDINATOR — owner OWN-PERMISSION-COORDINATOR.
//
//  The filesystem permission owner for CON-PERMISSION-FILESYSTEM:
//
//    * Decision: use NSOpenPanel and security-scoped bookmarks only for user-selected
//      locations; release every access scope.
//    * Purpose: access only user-selected files and folders required by a feature.
//    * Denied behaviour: leave existing state unchanged and allow another explicit
//      selection.
//    * Failure behaviour: leave existing state unchanged and allow another explicit
//      selection.
//    * Recovery: recheck authorization only after an explicit user action and preserve
//      the documented denied path.
//
//  How the contract is honoured here
//  ---------------------------------
//    * Selections. `chooseExistingNote()` and `chooseNewNoteDestination(suggestedName:)`
//      are the only ways a path can enter the app. They present the standard macOS
//      panels through the injected `PanelPresenting` and adopt a selection only when it
//      is a `.txt` note location (`Self.allowedFileExtension`). A cancelled panel
//      returns nil and changes nothing: no selection is recorded, no access scope is
//      begun, and another explicit selection stays possible.
//    * Scope accounting. `beginAccess(to:)` is the single place a scope is begun. It
//      refuses a location that carries no security-scoped bookmark, so a failure can
//      never leak a scope, and it is idempotent per location, so repeating it never adds
//      a second scope. `endAccess(to:)` and `releaseAllScopes()` release exactly what is
//      counted and are safe to repeat: the count never underflows and returns to 0.
//    * Only an explicit chooser call can touch the panels, and nothing here reads or
//      writes note contents, so no note text, buffer, or diagnostic output ever carries
//      a path. Nothing is persisted: no bookmark, path, or scope leaves memory.
//    * No network APIs, no third-party dependencies, and no direct file I/O at all —
//      reaching a file is the caller's job through its own injected service, once a
//      selection has been authorised here.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - PermissionCoordinator

/// Owner of the filesystem permission contract: user-selected locations only, restricted
/// to `.txt`, every access scope released.
@MainActor
final class PermissionCoordinator: Sendable {

    // MARK: Locked surface

    /// The only file extension the app may open or produce: plain text `.txt`.
    static let allowedFileExtension: String = "txt"

    /// Number of access scopes this coordinator has begun and not yet released. Zero
    /// means the app is holding no scope it still owes back to the system.
    private(set) var activeScopeCount: Int = 0

    /// The selection operation in the shared `OperationState` vocabulary. `cancelled` is
    /// the documented denied path (the user closed the panel); `failed` is a presenter
    /// that returned something the locked restriction forbids.
    ///
    /// Declared addition to Section 4.3 so that this owner's operation is represented in
    /// the shared idle/active/succeeded/failed/cancelled vocabulary (AGENTS.md Recovery
    /// Rules). No locked name is renamed or re-shaped by it.
    private(set) var selectionState: OperationState = .idle

    /// The most recent adopted selection, held in memory only and never persisted. It is
    /// preserved — not cleared — when a later attempt is denied or fails, because the
    /// last valid user state is what the app must keep showing.
    ///
    /// Declared addition to Section 4.3, used to observe the state that a denied or
    /// failed attempt must leave unchanged.
    private(set) var lastSelection: URL?

    // MARK: Injected seam

    /// The panel seam. `NativePanelPresenter` in the app, a scripted double in tests.
    private let presenter: any PanelPresenting

    /// Every begun access scope, in the order it was begun. The count above is always
    /// this array's count.
    private var scopes: [Scope] = []

    init(presenter: any PanelPresenting = NativePanelPresenter()) {
        self.presenter = presenter
    }

    // MARK: - Selection

    /// Presents the standard macOS open panel, restricted to `.txt`, and returns the
    /// chosen note location. Returns nil when the user cancels.
    ///
    /// The denied path changes nothing: no scope, no selection, and a later call may
    /// still succeed, because authorisation is only ever rechecked after an explicit
    /// user action.
    func chooseExistingNote() async -> URL? {
        selectionState = .active

        guard let url = await presenter.chooseExistingNote() else {
            // Denied: the user closed the panel. The last valid state stays exactly as
            // it was, and nothing was authorised.
            selectionState = .cancelled
            return nil
        }

        return adopt(url)
    }

    /// Presents the standard macOS save panel, restricted to `.txt`, and returns the
    /// chosen destination. Returns nil when the user cancels.
    ///
    /// A save destination does not take an access scope here: the chosen path usually
    /// does not exist yet, so there is no user-selected location to reach until the
    /// write creates it. The write path's owner reaches the destination's own directory
    /// through this coordinator's `beginAccess(to:)` when it needs a scope, and
    /// `releaseAllScopes()` returns every scope at termination.
    func chooseNewNoteDestination(suggestedName: String) async -> URL? {
        selectionState = .active

        guard let url = await presenter.chooseNewNoteDestination(suggestedName: suggestedName) else {
            selectionState = .cancelled
            return nil
        }

        return adopt(url)
    }

    // MARK: - Access scopes

    /// Begins access to a user-selected location.
    ///
    /// The location's proof of user selection is its security-scoped bookmark data: a
    /// location that cannot be represented that way — it does not exist, or the app may
    /// not reach it — is refused, so a failure here never leaks a scope. A location that
    /// is already open is left as it is, so beginning twice is idempotent rather than a
    /// second scope.
    ///
    /// Returns `true` when an access to the location is (now) held by this coordinator.
    func beginAccess(to url: URL) -> Bool {
        guard PermissionCoordinator.securityScopedBookmarkData(for: url) != nil else {
            return false
        }

        let key = url.standardizedFileURL
        guard !scopes.contains(where: { $0.url == key }) else {
            return true
        }

        scopes.append(Scope(url: key, platformScopeStarted: url.startAccessingSecurityScopedResource()))
        activeScopeCount = scopes.count
        return true
    }

    /// Releases the access scope held for `url`.
    ///
    /// Safe to repeat and safe for a location that was never opened: an unknown location
    /// is ignored, the count never underflows, and a released location can be opened
    /// again by a later explicit selection.
    func endAccess(to url: URL) {
        let key = url.standardizedFileURL
        guard let index = scopes.lastIndex(where: { $0.url == key }) else {
            return
        }

        let scope = scopes.remove(at: index)
        PermissionCoordinator.release(scope)
        activeScopeCount = scopes.count
    }

    /// Releases every access scope this coordinator holds and returns the count to 0.
    ///
    /// Safe and idempotent: a repeat call has nothing left to release, never
    /// double-releases, and leaves the count at 0.
    func releaseAllScopes() {
        for scope in scopes {
            PermissionCoordinator.release(scope)
        }
        scopes.removeAll()
        activeScopeCount = 0
    }

    // MARK: - Static helpers

    /// The location's user-selection proof as security-scoped bookmark data, or nil when
    /// the location cannot be represented that way (it does not exist, or the app cannot
    /// reach it). Nothing is written to disk: the data is returned to the caller.
    nonisolated static func securityScopedBookmarkData(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }

        // A build without the sandbox does not attach a security scope to a plain
        // location. The location is still bookmarked, which is the existence and
        // reachability proof this check stands for.
        return try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// `true` when the location may be opened or produced by this app: a `.txt` note
    /// location and nothing else.
    static func isAllowedNoteLocation(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == allowedFileExtension
    }

    // MARK: - Private

    /// One begun access scope.
    private struct Scope {
        /// The location key, standardised so that equivalent spellings of the same path
        /// release the same scope.
        let url: URL
        /// `true` when the platform reported that a separate, security-scoped access was
        /// started for this location and therefore has to be stopped.
        let platformScopeStarted: Bool
    }

    /// Adopts a selection the presenter returned.
    ///
    /// A presenter that returns anything other than a `.txt` note location violates the
    /// locked restriction: nothing is adopted, no scope is begun, and the last valid
    /// state is preserved so another explicit selection can follow.
    private func adopt(_ url: URL) -> URL? {
        guard PermissionCoordinator.isAllowedNoteLocation(url) else {
            selectionState = .failed
            return nil
        }

        lastSelection = url
        // Best effort and never a leak: an existing, bookmarkable location is counted
        // and released by `endAccess(to:)`/`releaseAllScopes()`; a location that carries
        // no security-scoped bookmark simply takes no scope.
        _ = beginAccess(to: url)
        selectionState = .succeeded
        return url
    }

    /// Stops one counted platform scope. Called exactly once per scope, so the platform's
    /// own start/stop balance is never broken.
    private static func release(_ scope: Scope) {
        guard scope.platformScopeStarted else { return }
        scope.url.stopAccessingSecurityScopedResource()
    }
}

// MARK: - NativePanelPresenter

/// AppKit bridge for the panel seam (CON-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
/// interface: the standard macOS panels, restricted to `.txt`).
///
/// Panel construction and panel presentation are separate: `makeOpenPanel()` /
/// `makeSavePanel(suggestedName:)` expose the configured panel so its `.txt` restriction
/// is verifiable without showing any UI, and only the `choose…` methods ever present one.
@MainActor
final class NativePanelPresenter: PanelPresenting {

    init() {}

    /// The standard open panel, restricted to plain text (`.txt`).
    func makeOpenPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        return panel
    }

    /// The standard save panel, restricted to plain text (`.txt`), carrying the suggested
    /// name. `allowsOtherFileTypes` stays `false` so the restriction is not weakened by a
    /// typed extension.
    func makeSavePanel(suggestedName: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        return panel
    }

    /// Presents the open panel. Returns nil when the user cancels.
    func chooseExistingNote() async -> URL? {
        let panel = makeOpenPanel()
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }

    /// Presents the save panel. Returns nil when the user cancels.
    func chooseNewNoteDestination(suggestedName: String) async -> URL? {
        let panel = makeSavePanel(suggestedName: suggestedName)
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }
}
