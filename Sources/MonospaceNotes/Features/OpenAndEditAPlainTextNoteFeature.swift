//
//  OpenAndEditAPlainTextNoteFeature.swift
//  MonospaceNotes
//
//  TASK-11-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE — owner
//  OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE.
//
//  Owns FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE:
//
//    * CON-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-INTERFACE — "the app reads the selected .txt
//      file as UTF-8 text and displays it in a TextKit 2 text view with the configured
//      monospace font and point size. The window title shows the file name. Editing
//      modifies the in-memory text buffer and marks the document as having unsaved
//      changes." Failure behavior: "if the file cannot be read, the app shows an error
//      alert naming the file and the read error, and leaves the current document
//      unchanged."
//    * CON-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-RECOVERY — every attempt is exactly one of
//      idle / active / succeeded / failed / cancelled; a failed read, a cancelled panel
//      and an interruption each preserve the last valid user state (the open document,
//      its path, and its edit marker); the only retry is an explicit one (Cmd+O again, or
//      another selection in the panel); and every terminal path leaves this owner holding
//      no task, handle, stream or temporary resource of its own.
//    * CON-DATA-OPEN-DOCUMENT-BUFFER — the text this owner hands over is the in-memory
//      buffer of the open note. It is never written to disk by this owner, and a failed
//      update leaves the last in-memory value valid.
//    * CON-DATA-WORKSPACE-FOLDER-REFERENCE / CON-PERSISTENCE-WORKSPACE-FOLDER-REFERENCE,
//      with USER CLARIFICATION 2 — opening a note establishes the workspace folder as
//      that note's PARENT FOLDER; the reference is held in memory for the session only
//      and is never persisted.
//    * CON-DATA-TYPOGRAPHY-SETTINGS — the surface that renders the buffer is the
//      document surface, which draws the configured monospace family and point size.
//      This owner never touches typography and never restyles the surface, so a font or
//      size chosen in Settings stays in effect across an open.
//
//  The exact user-facing string this owner must produce (fixed, so the UI and the tests
//  agree):
//
//    * the modal alert title of an open that could not read its file:
//          "Could Not Open Note"
//      and the message names the file and the read error, never the note's contents.
//
//  How the acceptance criteria map onto this surface
//  ------------------------------------------------
//    * ACC-...-01 "after a keystroke that changes the buffer, the document is marked as
//      having unsaved changes" — `markEdited(previous:new:)` is the rule (false when the
//      buffer is identical, true when it changed) and `noteEdit(previous:new:)` applies
//      it to the in-memory marker this owner keeps for the open document.
//      `hasUnsavedChanges` is cleared when a note is opened and by `markSaved()` after a
//      successful save; it is discarded when the document is closed.
//    * ACC-...-02 "after selecting a readable .txt file, the text view contains exactly
//      the file's UTF-8 decoded contents" — `open(url:)` reads the file through the
//      shared seam and hands the exact string back in `OpenOutcome.text`; the composition
//      root adopts it into the buffer and into the document surface, and
//      `adoptOpenedDocument(_:into:)` writes it onto the live text view so the surface
//      shows exactly those characters (CRLF and an empty file included: the string is
//      handed over verbatim, never normalised).
//    * ACC-...-03 "if the file is unreadable, an error alert is presented and the
//      previously open document remains displayed" — a failed read publishes `.failed`
//      with `failureAlert(for:url:)` (title exactly "Could Not Open Note", message naming
//      the file and the read error) and carries NO text and NO title to adopt, so nothing
//      of the open document moves; `adoptOpenedDocument(_:into:)` refuses a non-succeeded
//      outcome and leaves the surface as it was.
//    * ACC-...-04 "the window title equals the selected file's last path component" —
//      `windowTitle(for:)` is the one rule, and `OpenOutcome.windowTitle` carries it for
//      the note the user selected (and only for a successful open).
//
//  Invariants honoured here
//  ------------------------
//    * No network APIs and no third-party dependencies.
//    * No file I/O on the main actor: every read travels through the injected
//      `NoteFileAccess` seam, whose contract is to run off the main actor and to record
//      itself in the shared thread recorder. This owner never reads a path itself, never
//      writes, renames or removes anything, and holds no file handle.
//    * Nothing is persisted here: no stored settings, no temporary file, no reference
//      written anywhere. The document path, the workspace folder reference and the
//      unsaved-changes marker are in-memory session state only.
//    * Reporting values name the file and a short reason only — never note contents.
//

import AppKit
import Foundation

@MainActor
final class OpenAndEditAPlainTextNoteFeature {

    // MARK: - Locked user-facing strings

    /// CON-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-INTERFACE failure behavior: the title of the
    /// modal alert a note that cannot be read is reported with. Locked exactly.
    nonisolated static let openFailureAlertTitle: String = "Could Not Open Note"

    /// The only note type this app opens and edits: a plain-text `.txt` note. The .txt
    /// restriction itself belongs to the panel presenter (OWN-PERMISSION-COORDINATOR);
    /// this owner is handed one exact path and reads exactly that path.
    nonisolated static let noteFileExtension: String = "txt"

    /// The window title of a document that is not open: the app name.
    nonisolated static let noDocumentWindowTitle: String = LockedIdentity.bundleName

    // MARK: - The outcome of one open

    /// One open: what it ended in, the note it addressed, the text it read, the window
    /// title of that note, and the modal alert of a failed read.
    ///
    /// The adoption rule for the caller (the composition root) is the same one
    /// FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE uses for a selected result: adopt
    /// `url`, `text` and `windowTitle` ONLY when `state == .succeeded` (see `opened`).
    /// A failed outcome still reports the path it addressed — so the alert and any
    /// diagnostic can name it — but it never carries text or a title, which is what keeps
    /// "the previously open document remains displayed and unchanged" true by
    /// construction. A cancelled outcome carries nothing at all.
    struct OpenOutcome: Equatable, Sendable {
        /// The state the attempt ended in: `.succeeded`, `.failed` or `.cancelled`.
        /// (`idle` / `active` only ever describe this owner before and during an attempt;
        /// a returned attempt has reached a terminal state.)
        let state: OperationState
        /// The note this attempt addressed: the selected note on success, and the path
        /// whose read failed on failure. `nil` for a cancelled panel, which established no
        /// note at all.
        let url: URL?
        /// The note's exact UTF-8 decoded text, and only for a successful read.
        let text: String?
        /// The window title of the opened note — ACC-...-04: the note's LAST PATH
        /// COMPONENT. `nil` unless the attempt succeeded, so a failed or cancelled open
        /// never moves the title off the document that is open.
        let windowTitle: String?
        /// The modal alert to present, or `nil`. Only a failed read produces one.
        let errorAlert: ErrorAlert?

        /// Whether this outcome hands the caller a note to adopt. Derived from the
        /// reported values, so it can never claim a text or a title an attempt did not
        /// produce.
        var opened: Bool { state == .succeeded && url != nil && text != nil }
    }

    // MARK: - Injected services

    /// The shared note-file seam (CON-DATA-NOTE-FILE): `DataStore` in the app. Every note
    /// read goes through `readUTF8(from:)`, whose contract is to run off the main actor.
    /// This owner never writes through it and never reads a path itself.
    private let noteFiles: any NoteFileAccess

    /// The open panel, restricted to `.txt` by the permission coordinator in the app.
    /// `openViaPanel()` asks it for the note to read; a presenter that reports a cancel
    /// leaves everything as it was.
    private let panels: any PanelPresenting

    /// - Parameters:
    ///   - noteFiles: the shared note-file seam (the real `DataStore` in the app).
    ///   - panels: the open panel. The neutral placeholder is the default so an
    ///     unconfigured owner can only ever report a cancel — it can never present a real
    ///     panel, and therefore never shows UI from a test. The composition root always
    ///     injects the permission coordinator's presenter.
    init(noteFiles: any NoteFileAccess = DataStore(),
         panels: any PanelPresenting = UnconfiguredPanelPresenter()) {
        self.noteFiles = noteFiles
        self.panels = panels
    }

    // MARK: - Operation state (idle / active / succeeded / failed / cancelled)

    /// The state of the most recent open. `.idle` until the first one, and again after the
    /// open document is discarded.
    private(set) var openState: OperationState = .idle

    /// The most recent attempt, whatever its outcome.
    private(set) var lastOutcome: OpenOutcome?

    /// The alert of the most recent failed open. Cleared again by the next attempt that
    /// does not fail, so an explicit retry dismisses the alert.
    private(set) var lastErrorAlert: ErrorAlert?

    // MARK: - In-memory document state (never persisted)

    /// The note this owner last handed over as the open document — the in-memory document
    /// path reference. A failed or cancelled attempt never moves it, which is how "the
    /// previously open document remains displayed" holds for the caller that adopted it.
    private(set) var lastOpenedURL: URL?

    /// USER CLARIFICATION 2: the workspace folder — the PARENT FOLDER of the note that is
    /// currently open. Opening a note is what establishes it. Held in memory only for the
    /// session; never written to disk, never stored in any settings store, and discarded
    /// when the document is closed.
    private(set) var workspaceFolder: URL?

    /// ACC-...-01: whether the open document has changes that are not on disk. Set by
    /// `noteEdit(previous:new:)` when a keystroke really changed the buffer, cleared when a
    /// note is opened and by `markSaved()`.
    private(set) var hasUnsavedChanges: Bool = false

    // MARK: - Observations used by the surface and by the focused suite

    /// How many open panels this owner has presented. A cancelled panel counts: it was
    /// presented. A read that never happened is visible here next to `readAttemptCount`.
    private(set) var panelPresentationCount: Int = 0

    /// How many reads of a note this owner has started. A failed read counts: it was
    /// attempted. A cancelled panel never reaches a read, so it counts nothing.
    private(set) var readAttemptCount: Int = 0

    // MARK: - The rules

    /// ACC-...-04: the window title of a note is its LAST PATH COMPONENT — "note.txt" for
    /// any folder it lives in. This is the single rule the composition root applies to
    /// `windowTitle`.
    nonisolated static func windowTitle(for noteURL: URL) -> String {
        noteURL.lastPathComponent
    }

    /// USER CLARIFICATION 2: the folder an open note establishes as the workspace is its
    /// PARENT FOLDER. No note open means no folder. Pure and in memory only — nothing is
    /// written anywhere.
    nonisolated static func workspaceFolder(forNoteAt noteURL: URL?) -> URL? {
        noteURL?.deletingLastPathComponent()
    }

    /// ACC-...-01: whether a keystroke that produced `new` from `previous` changed the
    /// buffer — and therefore whether the document must be marked as having unsaved
    /// changes. `false` for an identical buffer (a keystroke that changed nothing does not
    /// make the document dirty), `true` for any real change. Pure: it decides, it does not
    /// mutate.
    func markEdited(previous: String, new: String) -> Bool {
        previous != new
    }

    /// Applies the ACC-...-01 rule to the in-memory marker of the open document: a keystroke
    /// that changed the buffer marks the document as having unsaved changes. A keystroke that
    /// changed nothing leaves the marker exactly as it was — it never silently clears an
    /// edit the user has already made. Returns whether the keystroke changed the buffer.
    @discardableResult
    func noteEdit(previous: String, new: String) -> Bool {
        let edited = markEdited(previous: previous, new: new)
        if edited {
            hasUnsavedChanges = true
        }
        return edited
    }

    /// The explicit-save owner's success signal: the buffer is on disk, so the document is
    /// no longer marked as having unsaved changes.
    func markSaved() {
        hasUnsavedChanges = false
    }

    // MARK: - Opening

    /// Cmd+O: presents the open panel, then reads the note the user selected.
    ///
    /// * a panel the user cancelled publishes `.cancelled`, presents no alert, reads
    ///   nothing at all, and leaves the open document, its path and the workspace folder
    ///   exactly as they were — the user retries with Cmd+O;
    /// * a selected note is read by `open(url:)`, which is where the read, the success, the
    ///   failure alert and the adoption rule live.
    @discardableResult
    func openViaPanel() async -> OpenOutcome {
        openState = .active

        // An attempt that starts cancelled (the application is terminating, or a newer
        // command superseded this one) presents no panel and reads nothing.
        if Task.isCancelled {
            return publish(.cancelled, url: nil, text: nil, windowTitle: nil, error: nil)
        }

        panelPresentationCount += 1
        guard let chosen = await panels.chooseExistingNote() else {
            // Cancelled open panel: no note was chosen, nothing was read, no alert is an
            // error here, and the document that is open keeps its last valid state.
            return publish(.cancelled, url: nil, text: nil, windowTitle: nil, error: nil)
        }

        if Task.isCancelled {
            return publish(.cancelled, url: nil, text: nil, windowTitle: nil, error: nil)
        }

        return await open(url: chosen)
    }

    /// Reads one note — exactly the path it is given — as UTF-8 text through the shared
    /// seam, and hands back what to display.
    ///
    /// Terminal paths, in the vocabulary of the recovery contract:
    /// * an attempt that starts cancelled, or whose read is interrupted (`CancellationError`,
    ///   which is how the shared reader reports a cancelled operation), publishes
    ///   `.cancelled`: nothing is adopted, no alert is produced for a cancellation, and the
    ///   last valid document state stands;
    /// * a read that throws publishes `.failed` with `failureAlert(for:url:)` — the title is
    ///   exactly "Could Not Open Note" and the message names the file and the read error —
    ///   and adopts nothing, so the previously open document stays displayed and unchanged;
    /// * a read that returns publishes `.succeeded` with the note's exact text, its last-path
    ///   component as the window title, the note as the document path and its parent folder
    ///   as the in-memory workspace folder; the fresh document is not dirty.
    ///
    /// Every terminal path leaves this owner with nothing in flight: it holds no task, no
    /// file handle, no stream and no temporary resource.
    @discardableResult
    func open(url: URL) async -> OpenOutcome {
        openState = .active

        if Task.isCancelled {
            return publish(.cancelled, url: nil, text: nil, windowTitle: nil, error: nil)
        }

        readAttemptCount += 1
        do {
            let text = try await noteFiles.readUTF8(from: url)

            if Task.isCancelled {
                return publish(.cancelled, url: nil, text: nil, windowTitle: nil, error: nil)
            }

            // The adoption rule: only now — with the note's text in hand — does the open
            // document, its path, its workspace folder and its title move, and a freshly
            // opened note is not marked as having unsaved changes.
            lastOpenedURL = url
            workspaceFolder = Self.workspaceFolder(forNoteAt: url)
            hasUnsavedChanges = false

            return publish(
                .succeeded,
                url: url,
                text: text,
                windowTitle: Self.windowTitle(for: url),
                error: nil
            )
        } catch is CancellationError {
            // Interrupted: not a read failure, so no alert, and nothing is adopted.
            return publish(.cancelled, url: nil, text: nil, windowTitle: nil, error: nil)
        } catch {
            // The read failed. The outcome names the note and the reason, carries no text
            // and no title, and does not touch `lastOpenedURL`, `workspaceFolder` or the
            // unsaved-changes marker.
            return publish(
                .failed,
                url: url,
                text: nil,
                windowTitle: nil,
                error: failureAlert(for: error, url: url)
            )
        }
    }

    // MARK: - Adoption into the document surface

    /// Writes an opened note's text onto the document surface's text view, so the surface
    /// the user types into shows exactly the characters that were read (ACC-...-02).
    ///
    /// Only a successful outcome is adopted: a failed or cancelled outcome returns `false`
    /// and does not touch the text view at all, which is what leaves the previously open
    /// document displayed and unchanged (ACC-...-03). The returned value is the
    /// post-condition itself — whether the surface now holds exactly the note's text — so a
    /// caller never has to trust that the write happened.
    ///
    /// The font and the colours of the surface are deliberately NOT touched: the document
    /// surface owns them and renders the configured monospace family, point size and
    /// contrast-checked colours (CON-DATA-TYPOGRAPHY-SETTINGS), so a typography choice made
    /// in Settings survives an open.
    @discardableResult
    func adoptOpenedDocument(_ outcome: OpenOutcome, into textView: NSTextView?) -> Bool {
        guard outcome.opened, let text = outcome.text, let textView else { return false }

        if textView.string != text {
            textView.string = text
            // A newly opened document is shown from its beginning.
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        textView.needsDisplay = true
        return textView.string == text
    }

    // MARK: - Closing

    /// Discards the in-memory session state of the open document: the document path
    /// reference, the workspace folder reference and the unsaved-changes marker
    /// (CON-DATA-OPEN-DOCUMENT-BUFFER retention: held only for the lifetime of the open
    /// document, discarded when it is closed or the app exits). Nothing on disk and nothing
    /// in any settings store is touched — there is nothing to touch, because this owner
    /// persists nothing.
    func discardOpenDocument() {
        lastOpenedURL = nil
        workspaceFolder = nil
        hasUnsavedChanges = false
        lastOutcome = nil
        lastErrorAlert = nil
        openState = .idle
    }

    // MARK: - Reporting

    /// The modal alert the application presents when a note cannot be read
    /// (CON-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-INTERFACE failure behavior). The title is the
    /// locked user-facing string; the message names the file and the read error, and states
    /// the two things the recovery contract guarantees: the document that was open is
    /// unchanged, and an explicit retry is another open.
    ///
    /// The note's contents never reach this message.
    func failureAlert(for error: Error, url: URL) -> ErrorAlert {
        ErrorAlert(
            title: Self.openFailureAlertTitle,
            message: "The note at “\(url.path)” could not be read: \(Self.reason(for: error)). "
                + "The document that was open is unchanged, and you can open the note again to retry."
        )
    }

    /// The short, content-free reason a read failed. The shared reader's own failure
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

    // MARK: - Private

    /// Publishes one terminal outcome: its state, the note it addressed, the text and title
    /// to adopt, and the alert to present. The alert surface is assigned on every path, so
    /// an attempt that does not fail dismisses the alert of one that did.
    private func publish(
        _ state: OperationState,
        url: URL?,
        text: String?,
        windowTitle: String?,
        error: ErrorAlert?
    ) -> OpenOutcome {
        let outcome = OpenOutcome(
            state: state,
            url: url,
            text: text,
            windowTitle: windowTitle,
            errorAlert: error
        )
        openState = state
        lastOutcome = outcome
        lastErrorAlert = error
        return outcome
    }
}
