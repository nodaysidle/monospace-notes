//
//  OpenAndSavePanelsForLocalFilesystemAccessFeature.swift
//  MonospaceNotes
//
//  TASK-12-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS — owner
//  OWN-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS.
//
//  Owns FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS: the PANEL-LEVEL contract
//  of the app — which path the standard macOS panels hand over, and what the app is
//  allowed to do with that path.
//
//    * CON-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-INTERFACE — "The app presents
//      the standard macOS open or save panel restricted to .txt files. The chosen path is
//      used for reading or writing the note. The app does not access paths outside the
//      user's selection. The write replaces the destination by renaming a temporary file
//      in the same directory." Failure behavior: "If the user cancels the panel, the app
//      leaves the current document and its path unchanged."
//
//      How each clause is honoured here:
//        - the panel is presented through the injected `PanelPresenting` (the production
//          `NativePanelPresenter`, restricted to plain text — asserted on the real panel
//          configuration by the focused suite, never by showing UI);
//        - `chooseOpenDestination()` reads EXACTLY the path the panel returned, through the
//          shared `NoteFileAccess` seam, and hands that path and that text back;
//        - `chooseSaveDestination(suggestedName:)` writes the in-memory buffer to EXACTLY
//          the path the save panel returned, through the SAME
//          `NoteFileAccess.writeAtomically(_:to:)` same-directory temporary-then-rename
//          writer Cmd+S uses (OWN-DATA-STORE owns that writer; this file never implements
//          one);
//        - a selection that is not a `.txt` note location is refused — the app reaches no
//          location the locked restriction forbids, and a presenter can never widen it;
//        - no path other than the panel's own selection is ever passed to the seam, which
//          is the only way this owner can touch the filesystem at all.
//
//    * CON-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS-RECOVERY — every attempt ends
//      in exactly one of idle / active / succeeded / failed / cancelled and preserves the
//      last valid user state; only an explicit retry follows a failure or a denial; and
//      every terminal path releases the access scope the attempt began and leaves no task,
//      file handle, stream or temporary resource behind. A cancelled panel adopts nothing:
//      the document this owner last read, the destination it last committed to and the
//      buffer it would commit are all left exactly as they were.
//
//  Boundaries (each neighbouring behaviour belongs to its own owner)
//  ---------------------------------------------------------------
//    * Cmd+O's document behaviour — the buffer, the window title, the in-memory workspace
//      folder, the "Could Not Open Note" read path of a normal open:
//      OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE.
//    * Cmd+S's document behaviour — OWN-EXPLICIT-SAVE-WITH-CMD-S. This owner owns Save As
//      (Cmd+Shift+S): the panel chooses the destination and the buffer is committed there
//      through the same shared writer, so both commands are the same atomic save.
//    * The `.txt` restriction, the security-scoped bookmarks, the panel configuration and
//      every scope release: OWN-PERMISSION-COORDINATOR (`PermissionCoordinator`,
//      `NativePanelPresenter`). This owner asks the coordinator for the selection's
//      user-selected proof and the scope it needs for the duration of one operation, and
//      releases it again on every terminal path.
//    * The atomic temporary-then-rename writer: OWN-DATA-STORE.
//
//  Invariants honoured here
//  ------------------------
//    * No network APIs and no third-party dependencies.
//    * No file I/O on the main actor: every read and write travels through the injected
//      `NoteFileAccess`, whose contract is to run its work off the main actor and to record
//      itself in the shared thread recorder. This file holds no reader, no writer, no rename
//      and no scratch location of its own — the focused suite asserts exactly that over this
//      very source.
//    * Nothing is persisted: this owner reads and writes no settings store and touches no
//      defaults. The buffer this owner commits, the path it last read and the destination
//      it last wrote are in-memory session state only (CON-DATA-OPEN-DOCUMENT-BUFFER,
//      CON-DATA-NOTE-FILE).
//    * Reporting values name the file and a short reason only — never note contents.
//
//  The exact user-facing strings this owner produces (locked by the packet so the UI and
//  the tests agree):
//
//    * the modal alert title of an open that could not read its file: "Could Not Open Note"
//    * the modal alert title of a Save As that could not write: "Could Not Save Note"
//

import Foundation

@MainActor
final class OpenAndSavePanelsForLocalFilesystemAccessFeature {

    // MARK: - Locked surface

    /// ACC-...-04 / the locked `.txt` restriction: the only file type either panel offers
    /// and the only type this owner accepts from a presenter.
    ///
    /// The same string the permission coordinator owns; the focused suite asserts that the
    /// two values and the real `NativePanelPresenter` configuration all agree, so the panel
    /// configuration and the acceptance rule cannot drift apart.
    nonisolated static let allowedFileExtension: String = "txt"

    /// The name suggested to the save panel for a document that has never been saved.
    nonisolated static let defaultSuggestedName: String = "Untitled.txt"

    /// The locked title of the modal alert for an open that could not read its file.
    nonisolated static let openFailureAlertTitle: String = "Could Not Open Note"

    /// The locked title of the modal alert for a Save As that could not write its file.
    nonisolated static let saveFailureAlertTitle: String = "Could Not Save Note"

    /// One panel attempt: what it ended in, the path it addressed, and whether the user
    /// cancelled the panel.
    ///
    /// Only a `succeeded` attempt has a path a caller may adopt (see `adoptedURL`): a
    /// cancelled panel established no path at all, and a failed attempt leaves the document
    /// on its last valid path. `cancelled` is derived from `state`, so it can never
    /// contradict the operation state it describes.
    struct PanelOutcome: Equatable, Sendable {
        /// The state the attempt ended in: `.succeeded`, `.failed` or `.cancelled`.
        /// (`idle` / `active` only ever describe this owner before and during an attempt; a
        /// returned attempt has reached a terminal state.)
        let state: OperationState
        /// The path this attempt addressed: the note that was read, or the destination that
        /// was written, on success; the path whose read or write failed on failure. `nil`
        /// for a cancelled panel, which established no path.
        let url: URL?
        /// `true` exactly when the user cancelled the panel — the documented denied path,
        /// which is not an error and produces no alert.
        var cancelled: Bool { state == .cancelled }
        /// The path a caller adopts into the open document, and only for a succeeded
        /// attempt. Derived from the reported values, so a caller can never adopt the path
        /// of an attempt that did not complete.
        var adoptedURL: URL? { state == .succeeded ? url : nil }
    }

    // MARK: - Injected services

    /// The panel seam: `NativePanelPresenter` in the app (restricted to `.txt`), a scripted
    /// double in tests. The default is the neutral placeholder, which can only ever report
    /// a cancel — an unconfigured owner therefore never presents a panel and never shows UI
    /// from a test.
    private let panels: any PanelPresenting

    /// The filesystem-permission owner (CON-PERMISSION-FILESYSTEM). Every location this
    /// owner reaches is first checked against the coordinator's locked `.txt` rule, and the
    /// access scope the operation needs is begun and released through the coordinator, so no
    /// scope outlives the operation that asked for it.
    private let permissions: PermissionCoordinator

    /// The shared note-file seam (CON-DATA-NOTE-FILE): `DataStore` in the app. Reads use
    /// `readUTF8(from:)`; the Save As write uses `writeAtomically(_:to:)`, the same
    /// same-directory temporary-then-rename writer Cmd+S uses. This owner performs no file
    /// I/O of its own.
    private let noteFiles: any NoteFileAccess

    /// - Parameters:
    ///   - panels: the panel seam (the `.txt`-restricted presenter).
    ///   - permissions: the permission coordinator that owns the `.txt` restriction and the
    ///     access scopes.
    ///   - noteFiles: the shared note-file seam. The locked two-argument form
    ///     `init(panels:permissions:)` stays valid, because this seam is appended with a
    ///     neutral default; the composition root always injects the real `DataStore`.
    init(panels: any PanelPresenting = UnconfiguredPanelPresenter(),
         permissions: PermissionCoordinator = PermissionCoordinator(),
         noteFiles: any NoteFileAccess = UnconfiguredNoteFileAccess()) {
        self.panels = panels
        self.permissions = permissions
        self.noteFiles = noteFiles
    }

    // MARK: - The buffer Save As commits (in memory only)

    /// CON-DATA-OPEN-DOCUMENT-BUFFER: the in-memory text of the currently open note, which
    /// `chooseSaveDestination(suggestedName:)` writes to the path the user chooses.
    ///
    /// The composition root sets it immediately before the command (AppState mirrors its
    /// own `documentText` here). It is session state: never persisted, never written to any
    /// store, and never included in any report. An empty buffer is a legitimate document, so
    /// an empty value is written as an empty file rather than refused.
    var documentText: String = ""

    // MARK: - Operation state (idle / active / succeeded / failed / cancelled)

    /// The state of the most recent open-panel attempt. `.idle` until the first one.
    private(set) var openState: OperationState = .idle

    /// The state of the most recent save-panel attempt. `.idle` until the first one.
    private(set) var saveState: OperationState = .idle

    /// The most recent open-panel attempt, whatever its outcome.
    private(set) var lastOpenOutcome: PanelOutcome?

    /// The most recent save-panel attempt, whatever its outcome.
    private(set) var lastSaveOutcome: PanelOutcome?

    /// The alert of the most recent attempt that failed, whichever panel it came through;
    /// `nil` when that attempt did not fail. Assigned on every terminal path, so an attempt
    /// that succeeds or is cancelled dismisses the alert of an earlier failure and an
    /// explicit retry starts clean.
    private(set) var lastErrorAlert: ErrorAlert?

    // MARK: - In-memory document state (never persisted)

    /// The note this owner last READ for the user, and its exact UTF-8 text. A failed or
    /// cancelled attempt never moves either, which is what keeps "the current document and
    /// its path are unchanged" true across a cancel.
    private(set) var lastReadURL: URL?
    private(set) var lastReadText: String?

    /// The destination Save As last committed the buffer to. A failed or cancelled attempt
    /// never moves it, so the document keeps its last valid path.
    private(set) var lastSavedURL: URL?

    // MARK: - Observations used by the focused suite

    /// How many open panels this owner has presented. A cancelled panel counts: it was
    /// presented. An attempt that never reached the panel (it was cancelled before entry)
    /// counts nothing.
    private(set) var openPanelPresentationCount: Int = 0

    /// How many save panels this owner has presented.
    private(set) var savePanelPresentationCount: Int = 0

    /// How many reads of a selected note this owner has started. A failed read counts: it
    /// was attempted. A cancelled panel never reaches a read.
    private(set) var readAttemptCount: Int = 0

    /// How many writes of the buffer this owner has attempted. A failed write counts: it was
    /// attempted. A cancelled panel never reaches a write.
    private(set) var writeAttemptCount: Int = 0

    // MARK: - The rules

    /// The name to suggest to the save panel: the open document's own file name, or
    /// `Untitled.txt` for a document that has never been saved. Pure and in memory only.
    nonisolated static func suggestedName(for documentURL: URL?) -> String {
        documentURL?.lastPathComponent ?? defaultSuggestedName
    }

    /// The short, content-free reason a read or write failed. The shared store's own failure
    /// vocabulary is preferred because it is already short and never carries a directory
    /// path; anything else is described as-is (`String(describing:)` reports an error's own
    /// `description` when it has one).
    nonisolated static func reason(for error: Error) -> String {
        if let operationError = error as? DataStore.OperationError {
            return operationError.failureReason
        }
        let described = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        return described.isEmpty ? "an unknown error" : described
    }

    // MARK: - The open panel

    /// File ▸ Open: presents the `.txt`-restricted open panel and reads EXACTLY the note the
    /// user chose (ACC-...-01).
    ///
    /// Terminal paths, in the vocabulary of the recovery contract:
    /// * an attempt that starts cancelled presents no panel and reads nothing;
    /// * a panel the user cancels publishes `.cancelled` with no path, reads nothing at all,
    ///   raises no alert (a cancel is not an error) and leaves the document this owner last
    ///   read, its text and its path exactly as they were;
    /// * a presenter that returns anything other than a `.txt` note location publishes
    ///   `.failed` with the refusal alert: nothing is read, the last valid state stands, and
    ///   an explicit retry is another selection;
    /// * a read that throws publishes `.failed` with `openFailureAlert(for:url:)` (title
    ///   exactly "Could Not Open Note", message naming the file and the reason) and adopts
    ///   nothing — `lastReadURL` and `lastReadText` keep their last valid values;
    /// * an interrupted read (`CancellationError`, which is how the shared reader reports a
    ///   cancelled operation) publishes `.cancelled` and raises no alert;
    /// * a read that returns publishes `.succeeded` with the path that was read and that
    ///   path's exact text in `lastReadText`.
    ///
    /// The access scope the attempt needs is begun through the permission coordinator and
    /// released on every terminal path above, so no scope outlives the attempt.
    @discardableResult
    func chooseOpenDestination() async -> PanelOutcome {
        openState = .active

        // An attempt that starts cancelled (the application is terminating, or a newer
        // command superseded this one) presents no panel and reads nothing.
        if Task.isCancelled {
            return publishOpen(.cancelled, url: nil, error: nil)
        }

        openPanelPresentationCount += 1
        guard let chosen = await panels.chooseExistingNote() else {
            // The denied path: the user closed the panel. No note was chosen, nothing was
            // read, and the document that is open keeps its last valid state.
            return publishOpen(.cancelled, url: nil, error: nil)
        }

        if Task.isCancelled {
            return publishOpen(.cancelled, url: nil, error: nil)
        }

        // ACC-...-04 enforced on the selection: the panel is restricted to `.txt`, so a
        // presenter that returns anything else violates the locked restriction. Nothing is
        // adopted and no location is reached.
        guard PermissionCoordinator.isAllowedNoteLocation(chosen) else {
            return publishOpen(.failed, url: nil, error: openRefusalAlert(for: chosen))
        }

        return await read(chosen)
    }

    // MARK: - The save panel (Save As)

    /// File ▸ Save As: presents the `.txt`-restricted save panel and writes the current
    /// buffer to EXACTLY the path the user chose (ACC-...-02), through the same shared
    /// same-directory temporary-then-rename writer Cmd+S uses.
    ///
    /// Terminal paths, mirroring the open panel:
    /// * an attempt that starts cancelled presents no panel and writes nothing;
    /// * a panel the user cancels publishes `.cancelled` with no path, writes nothing at all,
    ///   raises no alert, and leaves the document, its last saved path and the buffer
    ///   exactly as they were;
    /// * a selection outside `.txt` publishes `.failed` with the refusal alert and writes
    ///   nothing;
    /// * a write that throws publishes `.failed` with `saveFailureAlert(for:path:)` (title
    ///   exactly "Could Not Save Note", message naming the destination and the reason); the
    ///   shared writer has already left the destination bytes unchanged and removed its
    ///   temporary sibling, and `lastSavedURL` keeps its last valid value;
    /// * an interrupted write publishes `.cancelled` and raises no alert;
    /// * a write that returns publishes `.succeeded` with the exact destination written.
    ///
    /// The access scope is taken on the destination's OWN directory — the smallest location
    /// this save needs, because the shared writer places its temporary sibling there (see
    /// the permission owner's notes on the save destination) — and is released on every
    /// terminal path.
    @discardableResult
    func chooseSaveDestination(suggestedName: String) async -> PanelOutcome {
        saveState = .active

        if Task.isCancelled {
            return publishSave(.cancelled, url: nil, error: nil)
        }

        savePanelPresentationCount += 1
        guard let chosen = await panels.chooseNewNoteDestination(suggestedName: suggestedName) else {
            // Cancelled save panel: no destination was chosen, so nothing can have been
            // written and the document keeps its last valid path.
            return publishSave(.cancelled, url: nil, error: nil)
        }

        if Task.isCancelled {
            return publishSave(.cancelled, url: nil, error: nil)
        }

        guard PermissionCoordinator.isAllowedNoteLocation(chosen) else {
            return publishSave(.failed, url: nil, error: saveRefusalAlert(for: chosen))
        }

        let destinationDirectory = chosen.deletingLastPathComponent()
        // Exactly the scope this attempt adds is the scope it releases again: a location that
        // is already held stays held, and a location that carries no bookmark takes none.
        let scopesBefore = permissions.activeScopeCount
        _ = permissions.beginAccess(to: destinationDirectory)
        defer {
            if permissions.activeScopeCount > scopesBefore {
                permissions.endAccess(to: destinationDirectory)
            }
        }

        writeAttemptCount += 1
        do {
            // The SAME writer Cmd+S uses, addressed with exactly the chosen URL: the buffer
            // is written to a temporary sibling inside the destination's own directory and
            // renamed over the destination.
            try await noteFiles.writeAtomically(documentText, to: chosen)
        } catch is CancellationError {
            // Interrupted before the bytes moved: not a write failure, so no alert.
            return publishSave(.cancelled, url: chosen, error: nil)
        } catch {
            return publishSave(
                .failed,
                url: chosen,
                error: saveFailureAlert(for: error, path: chosen)
            )
        }

        lastSavedURL = chosen
        return publishSave(.succeeded, url: chosen, error: nil)
    }

    // MARK: - Reported failures

    /// The modal alert for an open that could not read its file: the locked title, the file
    /// it names, the short reason, and the two guarantees of the recovery contract — the
    /// document that is open is unchanged, and an explicit retry (another selection) is the
    /// only recovery path.
    ///
    /// The note's contents never reach this message.
    func openFailureAlert(for error: Error, url: URL) -> ErrorAlert {
        ErrorAlert(
            title: Self.openFailureAlertTitle,
            message: "The note at “\(url.path)” could not be read: \(Self.reason(for: error)). "
                + "The document that was open is unchanged, and you can choose the note again to retry."
        )
    }

    /// The modal alert for a Save As whose write failed: the locked title, the destination it
    /// names, the short reason, and the recovery contract's guarantees — the file on disk was
    /// left exactly as it was and the document keeps the path it already had, so an explicit
    /// retry (Cmd+Shift+S) is possible.
    ///
    /// The buffer's contents never reach this message.
    func saveFailureAlert(for error: Error, path: URL) -> ErrorAlert {
        ErrorAlert(
            title: Self.saveFailureAlertTitle,
            message: "The note at “\(path.path)” could not be saved: \(Self.reason(for: error)). "
                + "The file on disk was left exactly as it was, and you can retry Save As with Cmd+Shift+S."
        )
    }

    /// The modal alert for a presenter that returned a location the locked `.txt` restriction
    /// forbids: nothing was read, publishing that nothing was opened and that another
    /// explicit selection is the retry.
    func openRefusalAlert(for url: URL) -> ErrorAlert {
        ErrorAlert(
            title: Self.openFailureAlertTitle,
            message: "The panel returned “\(url.lastPathComponent)”, which is not a .txt note, so nothing was opened. "
                + "The document that was open is unchanged; choose a .txt note to retry."
        )
    }

    /// The modal alert for a save panel that returned a location the locked `.txt`
    /// restriction forbids: nothing was written and the document is unchanged.
    func saveRefusalAlert(for url: URL) -> ErrorAlert {
        ErrorAlert(
            title: Self.saveFailureAlertTitle,
            message: "The panel returned “\(url.lastPathComponent)”, which is not a .txt name, so nothing was written. "
                + "The document is unchanged; choose a .txt name to retry."
        )
    }

    // MARK: - Private

    /// Reads one selected note — exactly the path it is given — through the shared seam.
    ///
    /// The access scope of the user-selected location is held for the duration of the read
    /// and released on every terminal path.
    private func read(_ url: URL) async -> PanelOutcome {
        let scopesBefore = permissions.activeScopeCount
        _ = permissions.beginAccess(to: url)
        defer {
            if permissions.activeScopeCount > scopesBefore {
                permissions.endAccess(to: url)
            }
        }

        readAttemptCount += 1
        do {
            let text = try await noteFiles.readUTF8(from: url)

            if Task.isCancelled {
                return publishOpen(.cancelled, url: nil, error: nil)
            }

            // The adoption rule: only now — with the note's text in hand — does the document
            // this owner holds move.
            lastReadURL = url
            lastReadText = text
            return publishOpen(.succeeded, url: url, error: nil)
        } catch is CancellationError {
            // Interrupted: not a read failure, so no alert, and nothing is adopted.
            return publishOpen(.cancelled, url: nil, error: nil)
        } catch {
            return publishOpen(
                .failed,
                url: url,
                error: openFailureAlert(for: error, url: url)
            )
        }
    }

    /// Publishes one open outcome: its state, the path it addressed, and the alert to present
    /// (`nil` for every path that did not fail, which dismisses an earlier failure's alert).
    private func publishOpen(
        _ state: OperationState,
        url: URL?,
        error: ErrorAlert?
    ) -> PanelOutcome {
        let outcome = PanelOutcome(state: state, url: url)
        openState = state
        lastOpenOutcome = outcome
        lastErrorAlert = error
        return outcome
    }

    /// Publishes one save outcome, under the same rule.
    private func publishSave(
        _ state: OperationState,
        url: URL?,
        error: ErrorAlert?
    ) -> PanelOutcome {
        let outcome = PanelOutcome(state: state, url: url)
        saveState = state
        lastSaveOutcome = outcome
        lastErrorAlert = error
        return outcome
    }
}
