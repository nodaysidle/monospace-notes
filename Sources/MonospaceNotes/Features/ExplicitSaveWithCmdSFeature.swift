//
//  ExplicitSaveWithCmdSFeature.swift
//  MonospaceNotes
//
//  TASK-08-EXPLICIT-SAVE-WITH-CMD-S — owner OWN-EXPLICIT-SAVE-WITH-CMD-S.
//
//  Owns FEAT-EXPLICIT-SAVE-WITH-CMD-S, i.e. the Cmd+S command:
//
//    * CON-EXPLICIT-SAVE-WITH-CMD-S-INTERFACE — the current buffer is written to
//      the document's file path as UTF-8 text. A document that has no path gets a
//      save panel first, and the chosen path is the one written and adopted. On
//      success the unsaved-changes marker is cleared. The destination is replaced
//      by the shared same-directory temporary-then-rename writer
//      (`NoteFileAccess.writeAtomically`, owned by OWN-DATA-STORE): this feature
//      calls that writer and never implements one of its own.
//    * CON-EXPLICIT-SAVE-WITH-CMD-S-RECOVERY — every attempt ends in exactly one
//      of idle / active / succeeded / failed / cancelled, and the last valid user
//      state is preserved on every path. A failed write presents the modal alert
//      titled "Could Not Save Note" naming the path and the write error, leaves
//      the destination bytes exactly as they were (the shared writer removes its
//      temporary sibling and never touches the destination), and leaves the
//      document marked as having unsaved changes. A cancelled save panel writes
//      nothing at all. The only recovery path is an explicit retry: another Cmd+S,
//      which is a new attempt and clears the previous failure alert.
//
//  Where a failure is reported
//  ---------------------------
//  USER CLARIFICATION 1: Cmd+S reports a failed save as a MODAL ERROR ALERT, and
//  never through the non-modal status area — that area belongs to the background
//  autosave of FEAT-NON-BLOCKING-BACKGROUND-SAVE. This file therefore produces an
//  `ErrorAlert` and no non-modal status value at all.
//
//  Invariants honoured here
//  ------------------------
//    * No network APIs and no third-party dependencies.
//    * No file I/O on the main actor: every read and write travels through the
//      injected `NoteFileAccess`, whose contract is to run its work off the main
//      actor.
//    * The buffer is written to exactly one destination — the document's own path,
//      or the path the user chose in the save panel — and this feature persists no
//      state of its own, on disk or in `UserDefaults`.
//    * Cleanup of the temporary sibling belongs to the shared writer and runs on
//      every terminal path of that writer; this feature additionally proves, by
//      test, that a failed save leaves no sibling and no changed destination bytes.
//    * The failure alert carries the destination path and the write error, which
//      the interface contract requires it to name, and never the note's contents.

import Foundation

@MainActor
final class ExplicitSaveWithCmdSFeature {

    // MARK: - Locked surface

    /// The locked user-facing alert title for a failed save (TRD.md "Exact
    /// user-facing strings": `Could Not Save Note`).
    static let failureAlertTitle: String = "Could Not Save Note"

    /// One Cmd+S attempt.
    struct SaveOutcome: Equatable, Sendable {
        /// The state the attempt ended in: `.succeeded`, `.failed` or `.cancelled`.
        /// (`idle` / `active` only ever describe the feature before and during an
        /// attempt; an attempt that returns has reached a terminal state.)
        let state: OperationState
        /// The destination this attempt addressed; `nil` only when no destination was
        /// ever established (a cancelled save panel). A caller adopts this path into
        /// the open document only when `state == .succeeded`: a failed save leaves the
        /// document on its last valid path.
        let url: URL?
        /// The modal alert to present, or `nil`. Only a failed write produces one.
        let errorAlert: ErrorAlert?
        /// `true` exactly when the attempt succeeded — the buffer is on disk, so the
        /// unsaved-changes marker must be cleared. Derived from `state`, so it can
        /// never claim a cleared marker for an attempt that did not succeed.
        let clearedUnsavedMarker: Bool
    }

    // MARK: - Injected services

    /// The shared note-file seam. Saves use `writeAtomically(_:to:)`: the
    /// same-directory temporary file plus rename that
    /// FEAT-NON-BLOCKING-BACKGROUND-SAVE and FEAT-OPEN-AND-SAVE-PANELS-FOR-LOCAL-FILESYSTEM-ACCESS
    /// use as well. This feature never writes, renames or removes anything itself.
    private let noteFiles: any NoteFileAccess

    /// The save panel a document without a path needs: the .txt-restricted panel
    /// owned by the permission coordinator.
    private let panels: any PanelPresenting

    // MARK: - Operation state (idle / active / succeeded / failed / cancelled)

    /// The state of the most recent attempt. `.idle` until the first Cmd+S.
    private(set) var saveState: OperationState = .idle

    /// The most recent attempt, whatever its outcome.
    private(set) var lastOutcome: SaveOutcome?

    /// The path the most recent *successful* save committed to; `nil` until then.
    private(set) var lastSavedURL: URL?

    /// The alert of the most recent failed save. Cleared again by the next attempt
    /// that does not fail, so an explicit retry dismisses the alert.
    private(set) var lastErrorAlert: ErrorAlert?

    /// How many save panels this feature has presented. A document that already has
    /// a path never presents one.
    private(set) var panelPresentationCount: Int = 0

    /// How many writes have been attempted. A failed write counts: it was attempted.
    /// A cancelled panel never reaches zero-to-one here, because nothing was written.
    private(set) var writeAttemptCount: Int = 0

    /// - Parameters:
    ///   - noteFiles: the shared note-file seam (the real `DataStore` in the app).
    ///   - panels: the panel presenter used only when the document has no path.
    init(noteFiles: any NoteFileAccess, panels: any PanelPresenting) {
        self.noteFiles = noteFiles
        self.panels = panels
    }

    // MARK: - The Cmd+S attempt

    /// Commits `text` to the document's path — or, when the document has no path, to
    /// the path the user chooses in the save panel, which is presented BEFORE any
    /// write is attempted.
    ///
    /// Outcome handling, in the vocabulary of the recovery contract:
    /// * the attempt is `.active` while it runs;
    /// * a write the shared writer accepted publishes `.succeeded` and reports
    ///   `clearedUnsavedMarker == true`;
    /// * a write that threw publishes `.failed` with the modal
    ///   `failureAlert(for:path:)`, and never reports a cleared marker;
    /// * a save panel the user cancelled publishes `.cancelled`, addressed no
    ///   destination and wrote nothing at all — it is not an error, so there is no
    ///   alert;
    /// * an attempt interrupted before it wrote publishes `.cancelled` as well,
    ///   because an interruption is not a write failure.
    ///
    /// Nothing in this method mutates the document: the caller applies the outcome
    /// (clear the marker and adopt the path on success; keep the last valid state
    /// otherwise). Every terminal path leaves `.idle`-free state behind — the feature
    /// holds no task, handle, stream or temporary resource of its own.
    @discardableResult
    func save(text: String, documentURL: URL?, suggestedName: String) async -> SaveOutcome {
        saveState = .active

        // An attempt that starts cancelled (the application is terminating, or a newer
        // command superseded this one) asks for no panel and performs no I/O.
        if Task.isCancelled {
            return publish(.cancelled, url: documentURL, error: nil)
        }

        let destination: URL
        if let documentURL {
            destination = documentURL
        } else {
            panelPresentationCount += 1
            guard let chosen = await panels.chooseNewNoteDestination(suggestedName: suggestedName)
            else {
                // Cancelled save panel: no path was chosen and nothing was written, so
                // the document keeps its last valid state and stays unsaved.
                return publish(.cancelled, url: nil, error: nil)
            }
            if Task.isCancelled {
                return publish(.cancelled, url: chosen, error: nil)
            }
            destination = chosen
        }

        writeAttemptCount += 1
        do {
            try await noteFiles.writeAtomically(text, to: destination)
        } catch is CancellationError {
            // Interrupted before any bytes moved. A cancellation is not a write
            // failure, so no alert is produced and the destination is left alone by
            // the shared writer.
            return publish(.cancelled, url: destination, error: nil)
        } catch {
            return publish(
                .failed,
                url: destination,
                error: failureAlert(for: error, path: destination)
            )
        }

        lastSavedURL = destination
        return publish(.succeeded, url: destination, error: nil)
    }

    // MARK: - Reporting

    /// The modal alert the application presents when a save fails. The title is the
    /// locked user-facing string; the message names the destination path and the
    /// write error, and states the two things the recovery contract guarantees: the
    /// file on disk was left exactly as it was, and the document is still marked as
    /// having unsaved changes so an explicit retry (another Cmd+S) is possible.
    ///
    /// The note's contents never reach this message.
    func failureAlert(for error: Error, path: URL) -> ErrorAlert {
        ErrorAlert(
            title: Self.failureAlertTitle,
            message: "The note at “\(path.path)” could not be saved: \(Self.reason(for: error)). "
                + "The file on disk was left exactly as it was, and the document is still "
                + "marked as having unsaved changes, so you can retry with Cmd+S."
        )
    }

    /// The short, content-free reason a write failed. The shared writer's own failure
    /// vocabulary is preferred because it is already short and never carries a
    /// directory path; anything else is described as-is (`String(describing:)` reports
    /// an error's own `description` when it has one).
    static func reason(for error: Error) -> String {
        if let operationError = error as? DataStore.OperationError {
            return operationError.failureReason
        }
        let described = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        return described.isEmpty ? "an unknown error" : described
    }

    // MARK: - Private

    /// Publishes one terminal outcome: its state, its alert, and the exact rule the
    /// caller applies to the unsaved-changes marker.
    private func publish(_ state: OperationState, url: URL?, error: ErrorAlert?) -> SaveOutcome {
        let outcome = SaveOutcome(
            state: state,
            url: url,
            errorAlert: error,
            clearedUnsavedMarker: state == .succeeded
        )
        saveState = state
        lastOutcome = outcome
        lastErrorAlert = error
        return outcome
    }
}
