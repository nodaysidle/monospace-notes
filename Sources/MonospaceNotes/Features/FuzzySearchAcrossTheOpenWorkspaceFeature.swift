//
//  FuzzySearchAcrossTheOpenWorkspaceFeature.swift
//  MonospaceNotes
//
//  TASK-09-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE — owner
//  OWN-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE.
//
//  Owns FEAT-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE:
//
//    * CON-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-INTERFACE — "the app matches the query
//      against note file names and note contents in the currently open workspace folder
//      using a fuzzy subsequence match, and lists matching notes ordered by match score.
//      Selecting a result opens that note." Failure behavior: "if no note matches, the
//      results list shows an empty-state message and the current document remains open."
//    * CON-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-RECOVERY — every attempt is exactly one
//      of idle / active / succeeded / failed / cancelled; a failed read, a release and a
//      cancellation all preserve the last valid user state; the only retry is an explicit
//      one (the next keystroke, or Cmd+F again), and every terminal path cleans up after
//      itself — this owner holds no task, handle, stream or temporary resource once a
//      search has returned.
//    * CON-DATA-WORKSPACE-FOLDER-REFERENCE / CON-PERSISTENCE-WORKSPACE-FOLDER-REFERENCE —
//      the workspace folder is the PARENT FOLDER of the currently open note (USER
//      CLARIFICATION 2), is held in memory for the session only, is never written to
//      disk, and is discarded when the session ends.
//
//  Exact user-facing strings (locked, so the UI and the tests agree)
//  ---------------------------------------------------------------
//    * no note open, so no folder to search:  "Open a note to search its folder"
//    * a searched folder with no matching note: "No matching notes"
//
//  Which of them the search surface shows, by the state it is really in (the four rows)
//  ------------------------------------------------------------------------------------
//    * no note open (no folder)                    -> "Open a note to search its folder",
//      whatever has been typed, INCLUDING nothing: the folder decides this row, not the
//      last search, so the surface shows the message from its first render — in the
//      launch state, before the first keystroke, when it used to show nothing at all;
//    * a note open, nothing typed yet              -> nothing (no empty state at all:
//      nothing is claimed about matches before a query exists);
//    * a note open, a query typed, nothing matches -> "No matching notes";
//    * a note open, the query matches              -> the results list, nothing.
//
//  The surface derives its empty state from the state above at render time, from the
//  folder closure the composition root hands in, so a test can assert the launch state
//  without a window (see `FuzzySearchView.emptyStateText(of:hasWorkspace:)`).
//
//  The fuzzy match
//  ---------------
//  A query matches a candidate when the query is a SUBSEQUENCE of the candidate: every
//  query character appears in the candidate, in order, but not necessarily side by side.
//  `fuzzyScore(query:candidate:)` returns that match's score, or `nil` when there is no
//  match. The score is a documented, integer, deterministic function of the match's own
//  geometry — see `ScoreWeights` — so a result's rank is explainable and a test can
//  reproduce it:
//
//      score = 1000
//            + 40  × longest run of consecutive matched characters
//            + 25  × matched characters that begin a word
//            + 120 when the match starts at the candidate's first character
//            - 1   × index of the first matched character
//            - 3   × number of gaps (forward jumps between matched characters)
//            - 1   × (candidate length - query length), capped at 200
//
//  File names and note contents are scored the same way, but a file-name match is placed
//  on a separate, always-higher band (`ScoreWeights.fileNameBonus`), so every file-name
//  match outranks every content match. A note is reported once: a file-name match wins
//  the band, and its contents are then not scanned at all.
//
//  Results are ordered by score descending. Equal scores are ordered by file name and
//  then by full path, so the list is total and deterministic — running the same query
//  twice returns exactly the same order.
//
//  Where the folder content comes from, and why the keystroke path is fast
//  ---------------------------------------------------------------------
//  The folder is listed (off the main actor) and every `.txt` note in it is read through
//  the injected `NoteFileAccess` seam — the same UTF-8/atomic writer seam OWN-DATA-STORE
//  owns, whose contract is to run off the main actor. The folded text and a small
//  character-presence mask per note are the in-memory workspace snapshot. The snapshot is
//  built when the search surface is opened (Cmd+F, i.e. `focusSearch`) and whenever the
//  workspace folder changes; each keystroke then searches the snapshot in memory
//  (`search`), which is what keeps the keystroke path inside the 50 ms budget of
//  USER CLARIFICATION 4. `refreshWorkspace()` marks the snapshot stale so the next
//  explicit action re-reads the folder.
//
//  Invariants honoured here
//  ------------------------
//    * No network APIs and no third-party dependencies.
//    * No file I/O on the main actor: the folder listing runs in a detached task and
//      every note read travels through the async `NoteFileAccess` seam.
//    * This owner persists NOTHING. It is given no settings store, writes no file, and
//      holds the workspace folder in memory only; the open document buffer and the
//      workspace folder reference are never written to disk by this file or by any call
//      it makes.
//    * This owner cannot reach the open document: no API here takes or returns document
//      text, a document path or a window title, so "the current document remains open"
//      holds by construction. Reporting values name notes and reasons only — never note
//      contents.
//    * A single note that cannot be read is skipped and counted (`unreadableNoteCount`);
//      only a folder that cannot be listed at all, or a folder in which no note could be
//      read, is reported as `.failed` — and even then the last valid results stand and
//      nothing crashes.
//

import Darwin
import Foundation
import SwiftUI

@MainActor
final class FuzzySearchAcrossTheOpenWorkspaceFeature {

    // MARK: - Locked surface

    /// USER CLARIFICATION 4: a query returns its results within 50 ms of the last
    /// keystroke, for a workspace of 500 notes totalling 5 MB.
    nonisolated static let searchBudget: Duration = .milliseconds(50)

    /// The same budget in milliseconds, so a measurement can be compared against it.
    nonisolated static let searchBudgetMilliseconds: Double = 50

    /// USER CLARIFICATION 2: no note is open, so there is no folder to search.
    nonisolated static let noWorkspaceEmptyState: String = "Open a note to search its folder"

    /// CON-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-INTERFACE failure behavior: nothing in
    /// the searched folder matched the query.
    nonisolated static let noMatchEmptyState: String = "No matching notes"

    /// The measured workspace of USER CLARIFICATION 4: 500 notes, 5 MB in total.
    nonisolated static let performanceWorkspaceNoteCount: Int = 500
    nonisolated static let performanceWorkspaceTotalBytes: Int = 5_000_000

    /// The locked open-failure alert title, reused when a selected note cannot be read.
    nonisolated static let openFailureAlertTitle: String = "Could Not Open Note"

    /// The only files a workspace is made of: the app is a plain-text note app.
    nonisolated static let noteFileExtension: String = "txt"

    /// How many notes are read concurrently while the snapshot is built. Bounded so a
    /// huge folder cannot open an unbounded number of files at once.
    nonisolated static let workspaceReadConcurrency: Int = 16

    // MARK: - Outcomes

    /// One search: what it ended in, what it found, and the measured latency from the
    /// keystroke that started it. It carries no document state at all — a search cannot
    /// return, and cannot be given, the open document.
    struct SearchOutcome: Equatable, Sendable {
        /// `.succeeded`, `.failed` or `.cancelled`. (`idle` / `active` only describe this
        /// owner before and during a search; a returned attempt has reached a terminal
        /// state.)
        let state: OperationState
        /// The matching notes, ordered by score descending. A failed or cancelled search
        /// reports the last valid results.
        let results: [SearchResult]
        /// The message the results list shows when it has nothing to list: the no-note
        /// empty state, the no-match empty state, or `nil` while there is something to
        /// show (including "nothing typed yet").
        let emptyStateText: String?
        /// The measured latency of this search, in milliseconds, from the keystroke (the
        /// entry point) to the results — `ContinuousClock`, so it is a real elapsed time.
        let milliseconds: Double

        /// Whether this search met the locked budget.
        var metBudget: Bool { milliseconds < FuzzySearchAcrossTheOpenWorkspaceFeature.searchBudgetMilliseconds }
    }

    /// One selection: the note the user chose from the results list and, when the caller
    /// asked for it, that note's text read back through the shared note-file seam.
    struct SelectionOutcome: Equatable, Sendable {
        /// `.succeeded`, `.failed` or `.cancelled`.
        let state: OperationState
        /// The URL to open: exactly the URL of the selected result. `nil` only when the
        /// selection was cancelled or refused.
        let url: URL?
        /// The note's text, read through the shared seam, when the caller opened it.
        let text: String?
        /// The modal alert of a selection whose note could not be read, or `nil`.
        let errorAlert: ErrorAlert?

        /// Whether this selection hands the caller a note to open.
        var opensNote: Bool { state == .succeeded && url != nil }
    }

    // MARK: - Score weights

    /// The documented weights of the lazy-desugared fuzzy score above. One table, so a
    /// rank can be explained and a test can recompute any score exactly.
    enum ScoreWeights {
        static let matchBase: Int = 1_000
        static let consecutiveRun: Int = 40
        static let wordBoundary: Int = 25
        static let startsAtCandidateStart: Int = 120
        static let firstIndexPenalty: Int = 1
        static let gapPenalty: Int = 3
        static let lengthPenalty: Int = 1
        static let maximumLengthPenalty: Int = 200
        /// The band a file-name match is placed on, so every file-name match outranks
        /// every content match regardless of match geometry.
        static let fileNameBonus: Int = 100_000
        /// The band content matches are placed on.
        static let contentBase: Int = 500
    }

    // MARK: - Injected services

    /// The shared note-file seam (CON-DATA-NOTE-FILE). `DataStore` in the app. Every note
    /// read goes through it, so reads run off the main actor and are recorded by the
    /// store's own thread recorder. This owner never writes anything.
    private let noteFiles: any NoteFileAccess

    /// - Parameter noteFiles: the shared note-file seam used to read the workspace.
    init(noteFiles: any NoteFileAccess = DataStore()) {
        self.noteFiles = noteFiles
    }

    // MARK: - Published search state

    /// The operation state of the most recent search. `.idle` until the first one.
    private(set) var searchState: OperationState = .idle

    /// The query in effect: exactly what the search field holds.
    private(set) var query: String = ""

    /// The results of the last successful search, ordered by score descending.
    private(set) var results: [SearchResult] = []

    /// The empty-state message in effect, or `nil` when there are results or nothing has
    /// been typed yet.
    private(set) var emptyStateText: String?

    /// The most recent search, whatever its outcome.
    private(set) var lastOutcome: SearchOutcome?

    /// USER CLARIFICATION 2: the folder being searched — the parent folder of the open
    /// note. Held in memory only; never written to disk. A failed update leaves the last
    /// in-memory value valid.
    private(set) var workspaceFolder: URL?

    /// The measured latency of the most recent search, in milliseconds.
    private(set) var lastSearchMilliseconds: Double = 0

    /// How many notes of the workspace could not be read. A note that cannot be read is
    /// skipped; the search still succeeds and never crashes.
    private(set) var unreadableNoteCount: Int = 0

    /// The short, path-free reason the most recent search failed, or `nil`.
    private(set) var lastFailureReason: String?

    /// How many notes the in-memory workspace snapshot holds, or 0 before it is built.
    var workspaceNoteCount: Int { snapshot?.notes.count ?? 0 }

    /// Whether a search is in flight.
    private(set) var isSearching: Bool = false

    /// The note the user last selected. In memory only, like every other reference here.
    private(set) var lastSelectedURL: URL?

    /// The in-memory workspace snapshot and whether the next search must re-read it.
    private var snapshot: WorkspaceSnapshot?
    private var snapshotIsStale: Bool = false

    /// Set by `cancelSearch()`; observed at every suspension point of an in-flight search.
    private var cancellationRequested: Bool = false

    // MARK: - The workspace folder

    /// USER CLARIFICATION 2: the folder a search covers is the PARENT FOLDER of the note
    /// that is currently open. No note open means no folder — and no in-memory reference.
    static func workspaceFolder(forOpenDocumentAt documentURL: URL?) -> URL? {
        documentURL?.deletingLastPathComponent()
    }

    /// Whether a URL is a note this owner may list: a `.txt` file directly inside the
    /// workspace folder. Case-insensitively, because macOS file names usually are.
    static func isNoteFile(_ url: URL, in workspaceFolder: URL?) -> Bool {
        guard let workspaceFolder else { return false }
        guard url.pathExtension.lowercased() == noteFileExtension else { return false }
        return url.deletingLastPathComponent().standardizedFileURL
            == workspaceFolder.standardizedFileURL
    }

    // MARK: - Entry points

    /// Cmd+F: opens the search surface. The workspace folder is read once here (the cold
    /// path, off the main actor) so that every keystroke after it searches the in-memory
    /// snapshot. With no folder — no note open — nothing is read and the documented empty
    /// state is published.
    @discardableResult
    func focusSearch(workspaceFolder: URL?) async -> SearchOutcome {
        // Cmd+F is an explicit action: it re-reads the folder, so a note added since the
        // last search is found. A folder that cannot be read now leaves the last valid
        // results and the last valid folder reference standing.
        snapshotIsStale = true
        return await search(query: query, workspaceFolder: workspaceFolder)
    }

    /// One query as typed. Returns the measured outcome and publishes it: the results
    /// list, the empty-state message, the operation state and the latency.
    ///
    /// Terminal paths:
    /// * an interrupted search publishes nothing new and reports `.cancelled`;
    /// * no workspace folder reports `.succeeded` with the documented no-note empty state;
    /// * a folder that cannot be listed (or in which no note could be read) reports
    ///   `.failed` with the last valid results, and never fabricates a result;
    /// * a folder with no matching note reports `.succeeded` with the no-match empty state;
    /// * matches report `.succeeded` with the results ordered by score descending.
    ///
    /// The measured interval starts here — at the keystroke — and stops when the outcome
    /// is published.
    @discardableResult
    func search(query: String, workspaceFolder: URL?) async -> SearchOutcome {
        let clock = ContinuousClock()
        let start = clock.now

        isSearching = true
        cancellationRequested = false
        searchState = .active
        self.query = query
        defer {
            // Every terminal path leaves this owner with no work in flight.
            isSearching = false
            cancellationRequested = false
        }

        // An interrupted search is not a failure and publishes nothing new: the last
        // valid results and empty state stand.
        if Task.isCancelled { return publishCancelled(since: start, clock: clock) }

        // USER CLARIFICATION 2: no open note, no folder, no read, no results.
        guard let workspaceFolder else {
            snapshot = nil
            snapshotIsStale = false
            self.workspaceFolder = nil
            unreadableNoteCount = 0
            lastFailureReason = nil
            return publish(
                .succeeded,
                results: [],
                emptyStateText: Self.noWorkspaceEmptyState,
                since: start,
                clock: clock
            )
        }

        // The workspace snapshot: Cmd+F and a changed folder re-read it; the keystrokes in
        // between reuse the in-memory copy, which is what keeps them inside the budget.
        let searchableSnapshot: WorkspaceSnapshot
        if let cached = snapshot, cached.folder == workspaceFolder, snapshotIsStale == false {
            searchableSnapshot = cached
        } else {
            let load = await Self.readWorkspace(folder: workspaceFolder, noteFiles: noteFiles)

            if Task.isCancelled || cancellationRequested {
                return publishCancelled(since: start, clock: clock)
            }

            if let reason = load.failureReason {
                // The folder could not be read at all. Nothing is fabricated: the last
                // valid results and the last valid folder reference stand, and the
                // failure is reported so an explicit retry (Cmd+F) is possible.
                lastFailureReason = reason
                return publish(.failed, results: results, emptyStateText: emptyStateText, since: start, clock: clock)
            }

            let loaded = WorkspaceSnapshot(
                folder: workspaceFolder,
                notes: load.notes,
                unreadableNoteCount: load.unreadableNoteCount
            )
            snapshot = loaded
            snapshotIsStale = false
            searchableSnapshot = loaded
            lastFailureReason = nil
        }

        // The folder reference is in memory for the session only (CON-PERSISTENCE-
        // WORKSPACE-FOLDER-REFERENCE): it is assigned here and written nowhere.
        self.workspaceFolder = searchableSnapshot.folder
        unreadableNoteCount = searchableSnapshot.unreadableNoteCount

        // Nothing typed yet: no results and no message — nothing is claimed about matches.
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty == false else {
            return publish(.succeeded, results: [], emptyStateText: nil, since: start, clock: clock)
        }

        // The measured region: the fuzzy match over the in-memory snapshot, off the main
        // actor so a large workspace can never block the interface.
        let matches = await Task.detached(priority: .userInitiated) {
            Self.match(query: typed, in: searchableSnapshot)
        }.value

        if Task.isCancelled || cancellationRequested {
            return publishCancelled(since: start, clock: clock)
        }

        return publish(
            .succeeded,
            results: matches,
            emptyStateText: matches.isEmpty ? Self.noMatchEmptyState : nil,
            since: start,
            clock: clock
        )
    }

    /// Interrupts an in-flight search, e.g. because the search surface closed, the query
    /// was replaced, or the application is terminating. The search publishes `.cancelled`
    /// and leaves the last valid results in place. Safe to call with nothing in flight.
    func cancelSearch() {
        guard isSearching else { return }
        cancellationRequested = true
        searchState = .cancelled
    }

    /// Marks the in-memory workspace snapshot stale, so the next explicit action (Cmd+F,
    /// or the next query) re-reads the folder. Nothing on disk is touched.
    func refreshWorkspace() {
        snapshotIsStale = true
    }

    /// Drops the in-memory workspace reference — including the folder reference, which is
    /// in memory only and is discarded when the session ends.
    func discardWorkspaceReference() {
        snapshot = nil
        snapshotIsStale = false
        workspaceFolder = nil
        unreadableNoteCount = 0
    }

    // MARK: - Selecting a result

    /// The note a selection points at: exactly the URL the selected result carries, and
    /// only while that note belongs to the workspace being searched. Nothing is read.
    func selectionOutcome(for result: SearchResult) -> SelectionOutcome {
        guard !Task.isCancelled else {
            return SelectionOutcome(state: .cancelled, url: nil, text: nil, errorAlert: nil)
        }

        guard Self.isNoteFile(result.url, in: workspaceFolder) else {
            // Recovery: the note is not part of the workspace in effect (the folder
            // changed, or the result is stale), so nothing is opened; the user retries by
            // searching again.
            return SelectionOutcome(
                state: .failed,
                url: nil,
                text: nil,
                errorAlert: ErrorAlert(
                    title: Self.openFailureAlertTitle,
                    message: "“\(result.displayName)” is not part of the folder being searched, "
                        + "so it was not opened. Search again to choose a note from this folder."
                )
            )
        }

        lastSelectedURL = result.url
        return SelectionOutcome(state: .succeeded, url: result.url, text: nil, errorAlert: nil)
    }

    /// Opens the note a selection points at: the selection's own URL is read through the
    /// shared seam and handed back with its text, so the composition root adopts exactly
    /// the note the user selected. A note that cannot be read leaves the last valid state
    /// (the open document) untouched and reports the failure the same way an Open does.
    func openSelectedNote(_ result: SearchResult) async -> SelectionOutcome {
        let selection = selectionOutcome(for: result)
        guard selection.state == .succeeded, let url = selection.url else { return selection }

        do {
            let text = try await noteFiles.readUTF8(from: url)
            return SelectionOutcome(state: .succeeded, url: url, text: text, errorAlert: nil)
        } catch is CancellationError {
            return SelectionOutcome(state: .cancelled, url: url, text: nil, errorAlert: nil)
        } catch {
            return SelectionOutcome(
                state: .failed,
                url: url,
                text: nil,
                errorAlert: ErrorAlert(
                    title: Self.openFailureAlertTitle,
                    message: "The note “\(url.lastPathComponent)” could not be read: "
                        + "\(Self.reason(for: error)). The document that was open is unchanged, "
                        + "and you can select the result again to retry."
                )
            )
        }
    }

    // MARK: - Scoring (pure, off the main actor)

    /// The fuzzy score of a query against a candidate, or `nil` when the query is not a
    /// subsequence of the candidate.
    ///
    /// The match is case-insensitive and order-preserving: `"ard"` matches
    /// `"annual-report-draft.txt"` (a from *a*nnual, r from *r*eport, d from *d*raft)
    /// even though it is neither a prefix nor a substring of it.
    nonisolated static func fuzzyScore(query: String, candidate: String) -> Int? {
        let foldedQuery = FoldedText(query)
        let foldedCandidate = FoldedText(candidate)
        guard foldedQuery.scalarCount > 0 else { return nil }
        guard let geometry = matchGeometry(query: foldedQuery, candidate: foldedCandidate) else {
            return nil
        }
        return ScoreWeights.matchBase
            + scoreTerms(queryLength: foldedQuery.scalarCount, geometry: geometry)
            - lengthPenalty(
                candidateLength: foldedCandidate.scalarCount,
                queryLength: foldedQuery.scalarCount
            )
    }

    /// Whether the query is a subsequence of the candidate.
    nonisolated static func isSubsequence(_ query: String, ofCandidate candidate: String) -> Bool {
        let foldedQuery = FoldedText(query)
        guard foldedQuery.scalarCount > 0 else { return false }
        return matchGeometry(query: foldedQuery, candidate: FoldedText(candidate)) != nil
    }

    /// The geometry terms of the documented score, without the length penalty.
    nonisolated static func scoreTerms(queryLength: Int, geometry: MatchGeometry) -> Int {
        var score = 0
        score += ScoreWeights.consecutiveRun * geometry.longestRun
        score += ScoreWeights.wordBoundary * geometry.boundaryCount
        if geometry.firstIndex == 0 { score += ScoreWeights.startsAtCandidateStart }
        score -= ScoreWeights.firstIndexPenalty * geometry.firstIndex
        score -= ScoreWeights.gapPenalty * geometry.gapCount
        return score
    }

    /// The documented length penalty, capped so a long candidate cannot be pushed below
    /// the content band.
    nonisolated static func lengthPenalty(candidateLength: Int, queryLength: Int) -> Int {
        let extra = max(candidateLength - queryLength, 0)
        return ScoreWeights.lengthPenalty * min(extra, ScoreWeights.maximumLengthPenalty)
    }

    /// The score of a content match: the same match-quality terms, on the content band.
    /// The position and length terms are deliberately omitted — how deep a phrase sits in
    /// a note and how long that note is must not decide between two content matches.
    nonisolated static func contentScore(geometry: MatchGeometry) -> Int {
        var score = ScoreWeights.contentBase + ScoreWeights.matchBase
        score += ScoreWeights.consecutiveRun * geometry.longestRun
        score += ScoreWeights.wordBoundary * geometry.boundaryCount
        if geometry.firstIndex == 0 { score += ScoreWeights.startsAtCandidateStart }
        score -= ScoreWeights.gapPenalty * geometry.gapCount
        return score
    }

    /// The score band of a result, for the documented "file names outrank contents" rule.
    nonisolated static func score(of match: SearchResult) -> Int { match.score }

    // MARK: - The match itself

    /// The geometry of one subsequence match.
    struct MatchGeometry: Equatable, Sendable {
        /// The index of the first matched character.
        let firstIndex: Int
        /// The index of the last matched character.
        let lastIndex: Int
        /// The longest run of consecutive matched characters.
        let longestRun: Int
        /// How many times the match jumped forward (excluding the first match).
        let gapCount: Int
        /// How many matched characters begin a word.
        let boundaryCount: Int
    }

    /// The whole match: every matching note, ordered by score descending, then by file
    /// name and path so the order is total and deterministic. Pure and nonisolated, so
    /// the caller can run it off the main actor.
    nonisolated static func match(query: String, in snapshot: WorkspaceSnapshot) -> [SearchResult] {
        let foldedQuery = FoldedText(query)
        guard foldedQuery.scalarCount > 0 else { return [] }

        let queryMask = CharacterMask(foldedBytes: foldedQuery.bytes)
        let queryLength = foldedQuery.scalarCount
        var results: [SearchResult] = []
        results.reserveCapacity(32)

        for note in snapshot.notes {
            // The file name is the strongest signal, and checking it is cheap: a note
            // whose name matches is reported once and its contents are not scanned.
            if note.nameMask.covers(queryMask),
               let geometry = matchGeometry(query: foldedQuery, candidate: note.foldedName) {
                results.append(
                    SearchResult(
                        url: note.url,
                        score: ScoreWeights.fileNameBonus
                            + ScoreWeights.matchBase
                            + scoreTerms(queryLength: queryLength, geometry: geometry)
                            - lengthPenalty(
                                candidateLength: note.foldedName.scalarCount,
                                queryLength: queryLength
                            ),
                        matchedField: .fileName
                    )
                )
                continue
            }

            // The contents. The character-presence mask rejects a note that cannot
            // possibly match without scanning a single extra byte.
            guard note.contentMask.covers(queryMask),
                  let geometry = matchGeometry(query: foldedQuery, candidate: note.foldedContent) else {
                continue
            }
            results.append(
                SearchResult(
                    url: note.url,
                    score: contentScore(geometry: geometry),
                    matchedField: .contents
                )
            )
        }

        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let leftName = lhs.displayName
            let rightName = rhs.displayName
            if leftName != rightName { return leftName < rightName }
            return lhs.url.path < rhs.url.path
        }
        return results
    }

    // MARK: - Publishing

    /// Publishes one terminal outcome: its state, its results, its empty state and its
    /// measured latency.
    private func publish(
        _ state: OperationState,
        results: [SearchResult],
        emptyStateText: String?,
        since start: ContinuousClock.Instant,
        clock: ContinuousClock
    ) -> SearchOutcome {
        let outcome = SearchOutcome(
            state: state,
            results: results,
            emptyStateText: emptyStateText,
            milliseconds: Self.milliseconds(of: start.duration(to: clock.now))
        )
        searchState = state
        self.results = results
        self.emptyStateText = emptyStateText
        lastOutcome = outcome
        lastSearchMilliseconds = outcome.milliseconds
        return outcome
    }

    /// A cancelled search publishes no new results: the last valid results and empty
    /// state stand, and the operation is reported as cancelled.
    private func publishCancelled(since start: ContinuousClock.Instant, clock: ContinuousClock) -> SearchOutcome {
        let outcome = SearchOutcome(
            state: .cancelled,
            results: results,
            emptyStateText: emptyStateText,
            milliseconds: Self.milliseconds(of: start.duration(to: clock.now))
        )
        searchState = .cancelled
        lastOutcome = outcome
        lastSearchMilliseconds = outcome.milliseconds
        return outcome
    }

    /// The number of milliseconds a `Duration` spans.
    nonisolated static func milliseconds(of duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// A short, content-free reason for a failed read.
    nonisolated static func reason(for error: Error) -> String {
        if let operationError = error as? DataStore.OperationError {
            return operationError.failureReason
        }
        let described = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        return described.isEmpty ? "an unknown error" : described
    }

    // MARK: - Reading the workspace

    /// One loaded workspace: the notes the next query searches.
    struct WorkspaceSnapshot: Equatable, Sendable {
        let folder: URL
        let notes: [WorkspaceNote]
        let unreadableNoteCount: Int
    }

    /// One note in a loaded workspace. Its contents are kept folded (lower-cased) and as
    /// UTF-8 bytes: the match never needs the original text, and a folded copy is what
    /// makes case-insensitive matching a byte comparison.
    struct WorkspaceNote: Equatable, Sendable {
        let url: URL
        let foldedName: FoldedText
        let foldedContent: FoldedText
        let nameMask: CharacterMask
        let contentMask: CharacterMask
    }

    /// The result of reading a folder: the notes that could be read, how many could not,
    /// and why the folder itself could not be read when that is what happened.
    struct WorkspaceLoad: Equatable, Sendable {
        let notes: [WorkspaceNote]
        let unreadableNoteCount: Int
        let failureReason: String?
    }

    /// Reads a workspace folder: lists its `.txt` notes (off the main actor) and reads
    /// each of them through the shared seam (off the main actor). A note that cannot be
    /// read is skipped and counted; a folder that cannot be listed, or a folder in which
    /// no note could be read, reports a failure reason instead of fabricating notes.
    nonisolated static func readWorkspace(folder: URL, noteFiles: any NoteFileAccess) async -> WorkspaceLoad {
        let listingTask = Task.detached(priority: .userInitiated) {
            noteFileURLs(in: folder)
        }
        let listing = await listingTask.value

        if let reason = listing.failureReason {
            return WorkspaceLoad(notes: [], unreadableNoteCount: 0, failureReason: reason)
        }
        let urls = listing.urls

        guard urls.isEmpty == false else {
            return WorkspaceLoad(notes: [], unreadableNoteCount: 0, failureReason: nil)
        }

        var notes: [WorkspaceNote] = []
        notes.reserveCapacity(urls.count)
        var unreadable = 0

        var index = 0
        while index < urls.count {
            let batch = Array(urls[index..<min(index + workspaceReadConcurrency, urls.count)])
            index += batch.count

            let reads = await withTaskGroup(of: (URL, String?).self, returning: [(URL, String?)].self) { group in
                for url in batch {
                    group.addTask {
                        do {
                            return (url, try await noteFiles.readUTF8(from: url))
                        } catch {
                            // A note that cannot be read is skipped, never fabricated and
                            // never fatal: the rest of the workspace is still searched.
                            return (url, nil)
                        }
                    }
                }
                var collected: [(URL, String?)] = []
                collected.reserveCapacity(batch.count)
                for await read in group { collected.append(read) }
                return collected
            }

            for (url, text) in reads.sorted(by: { $0.0.path < $1.0.path }) {
                guard let text else {
                    unreadable += 1
                    continue
                }
                let foldedName = FoldedText(url.lastPathComponent)
                let foldedContent = FoldedText(text)
                notes.append(
                    WorkspaceNote(
                        url: url,
                        foldedName: foldedName,
                        foldedContent: foldedContent,
                        nameMask: CharacterMask(foldedBytes: foldedName.bytes),
                        contentMask: CharacterMask(foldedBytes: foldedContent.bytes)
                    )
                )
            }
        }

        notes.sort { $0.url.path < $1.url.path }

        if notes.isEmpty {
            return WorkspaceLoad(
                notes: [],
                unreadableNoteCount: unreadable,
                failureReason: "none of the \(unreadable) notes in this folder could be read"
            )
        }
        return WorkspaceLoad(notes: notes, unreadableNoteCount: unreadable, failureReason: nil)
    }

    /// One folder listing: the `.txt` files it holds, or a short path-free reason the
    /// folder could not be listed at all.
    struct NoteFileListing: Equatable, Sendable {
        let urls: [URL]
        let failureReason: String?
    }

    /// The `.txt` files directly inside a folder, sorted by path. Blocking file work: it
    /// is only ever called from a detached task, so no listing ever runs on the main
    /// actor. A folder that cannot be listed reports a short, path-free reason.
    nonisolated static func noteFileURLs(in folder: URL) -> NoteFileListing {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return NoteFileListing(urls: [], failureReason: "the folder could not be listed")
        }

        var urls: [URL] = []
        for entry in entries where entry.pathExtension.lowercased() == noteFileExtension {
            let isRegular = (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            if isRegular { urls.append(entry.standardizedFileURL) }
        }
        urls.sort { $0.path < $1.path }
        return NoteFileListing(urls: urls, failureReason: nil)
    }

    // MARK: - Folded text and the presence mask

    /// Lower-cased text, kept ready for a case-insensitive byte comparison. Positions and
    /// lengths in a match are UNICODE SCALAR indices; for ASCII text a scalar is one byte,
    /// which is the case the fast byte path covers.
    struct FoldedText: Equatable, Sendable {
        /// The lower-cased text.
        let text: String
        /// Its UTF-8 bytes.
        let bytes: [UInt8]

        /// Whether every scalar of the text is one byte, i.e. the text is pure ASCII.
        var isASCII: Bool { bytes.count == scalarCount }

        /// The text's length in Unicode scalars.
        var scalarCount: Int { text.unicodeScalars.count }

        init(_ text: String) {
            let folded = text.lowercased()
            self.text = folded
            self.bytes = Array(folded.utf8)
        }
    }

    /// Which characters a text contains at all: a 36-bit mask for `a`–`z` and `0`–`9`
    /// plus a flag for every other character. A query can only be a subsequence of a
    /// candidate if the candidate contains every character of the query, so this rejects
    /// a note without scanning its text. It is a necessary condition and never a match
    /// decision: `covers(_:)` returning true still needs the real subsequence match.
    struct CharacterMask: Equatable, Sendable {
        private var bits: UInt64
        private var hasOther: Bool

        init(foldedBytes: [UInt8]) {
            var mask: UInt64 = 0
            var other = false
            foldedBytes.withUnsafeBufferPointer { buffer in
                for byte in buffer {
                    switch byte {
                    case 97...122:
                        mask |= UInt64(1) << UInt64(byte - 97)
                    case 48...57:
                        mask |= UInt64(1) << UInt64(26 + byte - 48)
                    default:
                        other = true
                    }
                }
            }
            self.bits = mask
            self.hasOther = other
        }

        /// Whether this text could contain the query's characters.
        func covers(_ query: CharacterMask) -> Bool {
            if query.bits & ~bits != 0 { return false }
            if query.hasOther && hasOther == false { return false }
            return true
        }
    }

    // MARK: - Match geometry

    /// The geometry of a subsequence match of `query` in `candidate`, or `nil` when the
    /// query is not a subsequence.
    ///
    /// An ASCII query is matched on bytes: every byte of an ASCII query is a complete
    /// UTF-8 scalar, and no byte below 0x80 can ever be a continuation byte, so a byte
    /// match is exactly a scalar match. `memchr` finds each query byte from the previous
    /// match onwards, so a character that is absent — or absent after the previous match
    /// — is rejected at libc speed instead of byte by byte. A non-ASCII query is matched
    /// on scalars, which is exact but slower and therefore only used when it is needed.
    nonisolated static func matchGeometry(query: FoldedText, candidate: FoldedText) -> MatchGeometry? {
        if query.scalarCount == 0 || candidate.bytes.count < query.bytes.count {
            return nil
        }
        if query.isASCII {
            return matchGeometryBytes(query.bytes, candidate.bytes)
        }
        return matchGeometryScalars(
            Array(query.text.unicodeScalars),
            Array(candidate.text.unicodeScalars)
        )
    }

    /// The byte path: see `matchGeometry(query:candidate:)`.
    nonisolated static func matchGeometryBytes(_ query: [UInt8], _ candidate: [UInt8]) -> MatchGeometry? {
        let queryCount = query.count
        let candidateCount = candidate.count
        guard queryCount > 0, candidateCount >= queryCount else { return nil }

        return query.withUnsafeBufferPointer { queryBuffer in
            candidate.withUnsafeBufferPointer { candidateBuffer in
                guard let candidateBase = candidateBuffer.baseAddress else { return nil }

                var matched = 0
                var searchStart = 0
                var firstIndex = -1
                var previousIndex = -1
                var run = 0
                var longestRun = 0
                var gapCount = 0
                var boundaryCount = 0

                while matched < queryCount {
                    guard searchStart < candidateCount else { return nil }
                    guard let found = Darwin.memchr(
                        candidateBase + searchStart,
                        Int32(queryBuffer[matched]),
                        candidateCount - searchStart
                    ) else { return nil }

                    // `found` is an absolute pointer into the candidate, so its distance from
                    // the buffer's base IS the matched position.
                    let position = UnsafeRawPointer(found) - UnsafeRawPointer(candidateBase)

                    if matched == 0 {
                        firstIndex = position
                        run = 1
                    } else if position == previousIndex + 1 {
                        run += 1
                    } else {
                        run = 1
                        gapCount += 1
                    }
                    if position == 0 || isWordByte(candidateBuffer[position - 1]) == false {
                        boundaryCount += 1
                    }
                    if run > longestRun { longestRun = run }

                    previousIndex = position
                    matched += 1
                    searchStart = position + 1
                }

                return MatchGeometry(
                    firstIndex: firstIndex,
                    lastIndex: previousIndex,
                    longestRun: longestRun,
                    gapCount: gapCount,
                    boundaryCount: boundaryCount
                )
            }
        }
    }

    /// The scalar path, used for a query that contains a non-ASCII character.
    nonisolated static func matchGeometryScalars(
        _ query: [Unicode.Scalar],
        _ candidate: [Unicode.Scalar]
    ) -> MatchGeometry? {
        let queryCount = query.count
        let candidateCount = candidate.count
        guard queryCount > 0, candidateCount >= queryCount else { return nil }

        var matched = 0
        var index = 0
        var firstIndex = -1
        var previousIndex = -1
        var run = 0
        var longestRun = 0
        var gapCount = 0
        var boundaryCount = 0

        while index < candidateCount && matched < queryCount {
            if candidate[index] == query[matched] {
                if matched == 0 {
                    firstIndex = index
                    run = 1
                } else if index == previousIndex + 1 {
                    run += 1
                } else {
                    run = 1
                    gapCount += 1
                }
                if index == 0 || isWordScalar(candidate[index - 1]) == false {
                    boundaryCount += 1
                }
                if run > longestRun { longestRun = run }
                previousIndex = index
                matched += 1
            }
            index += 1
        }

        guard matched == queryCount else { return nil }
        return MatchGeometry(
            firstIndex: firstIndex,
            lastIndex: previousIndex,
            longestRun: longestRun,
            gapCount: gapCount,
            boundaryCount: boundaryCount
        )
    }

    /// Whether a byte can continue a word: a folded letter, a digit, or any byte of a
    /// non-ASCII scalar (word characters in most text).
    nonisolated static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte >= 128
    }

    /// Whether a scalar can continue a word: a letter, a digit, or a non-ASCII scalar.
    nonisolated static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 128 {
            return (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
        }
        return true
    }
}

// MARK: - The search surface

/// The search surface (CON-FUZZY-SEARCH-ACROSS-THE-OPEN-WORKSPACE-INTERFACE): a search
/// field that searches the folder of the open note on every keystroke, the results list
/// ordered by match score, the empty-state message when there is nothing to list, and a
/// selection that opens the chosen note.
///
/// The field drives the feature directly, so what the list shows is exactly what the
/// feature published, and the folder it searches is the one the composition root hands in
/// — the parent folder of the open note, resolved per keystroke so a note opened in the
/// meantime is followed.
struct FuzzySearchView: View {

    private let feature: FuzzySearchAcrossTheOpenWorkspaceFeature
    private let workspaceFolder: () -> URL?
    private let onSelect: (SearchResult) -> Void
    private let onDismiss: () -> Void

    @State private var query: String
    @State private var outcome: FuzzySearchAcrossTheOpenWorkspaceFeature.SearchOutcome?
    @State private var highlightedIndex: Int = 0
    @FocusState private var isSearchFieldFocused: Bool

    /// The stable strings and identifiers of the surface, so the UI and any test agree.
    static let title: String = "Search"
    static let searchFieldLabel: String = "Search Notes"
    static let searchFieldPrompt: String = "Type to search this folder"
    static let resultsListLabel: String = "Search Results"
    static let searchFieldIdentifier: String = "search.field"
    static let resultsIdentifier: String = "search.results"
    static let emptyStateIdentifier: String = "search.emptyState"
    static let resultIdentifierPrefix: String = "search.result."

    /// The stable accessibility identifier of one result row.
    static func resultIdentifier(for result: SearchResult) -> String {
        resultIdentifierPrefix + result.displayName
    }

    /// The empty-state message an outcome carries, or `nil` when it carries none — either
    /// because the search found notes to list or because nothing had been typed yet. This
    /// reads ONE search, so it only answers for a folder that was searched.
    static func emptyStateText(of outcome: FuzzySearchAcrossTheOpenWorkspaceFeature.SearchOutcome?) -> String? {
        outcome?.emptyStateText
    }

    /// The empty state the surface shows, derived from the state the surface is really in:
    /// the outcome of the last search (`nil` before the first one) and whether a note is
    /// open — that is, whether there is a folder to search at all.
    ///
    /// The four rows of the locked behaviour table (USER CLARIFICATION 2, ACC-02):
    ///
    /// | a note is open | a query is typed | anything matched | what is shown             |
    /// |----------------|------------------|------------------|---------------------------|
    /// | no             | anything         | anything         | `noWorkspaceEmptyState`   |
    /// | yes            | no               | —                | nothing                   |
    /// | yes            | yes              | no               | `noMatchEmptyState`       |
    /// | yes            | yes              | yes              | the results list, nothing |
    ///
    /// Row 1 is decided by the folder the surface is given, never by the last search: with
    /// no note open there is no folder, so the message is on screen from the first render —
    /// in the LAUNCH state, before any keystroke, which is exactly where the surface used
    /// to show nothing at all.
    static func emptyStateText(
        of outcome: FuzzySearchAcrossTheOpenWorkspaceFeature.SearchOutcome?,
        hasWorkspace: Bool
    ) -> String? {
        // ROW 1 — no note open, so there is nothing to search: the locked message, whether
        // or not any search has run yet and whatever has been typed (including nothing).
        guard hasWorkspace else {
            return FuzzySearchAcrossTheOpenWorkspaceFeature.noWorkspaceEmptyState
        }

        // ROWS 2-4 — a note is open and there is a folder, so the last search's own message
        // is the answer: it is `nil` when nothing has been typed yet (row 2) and when the
        // query matched (row 4), and the locked no-match message when a typed query matched
        // nothing (row 3).
        //
        // A message a search published while there was NO folder to search belongs to that
        // other state, not to this one: with a note open now, row 2 shows nothing until a
        // query is typed in this folder, rather than repeating the no-workspace message
        // over a note that is open.
        guard let outcome,
              outcome.emptyStateText != FuzzySearchAcrossTheOpenWorkspaceFeature.noWorkspaceEmptyState
        else {
            return nil
        }
        return outcome.emptyStateText
    }

    @MainActor
    init(
        feature: FuzzySearchAcrossTheOpenWorkspaceFeature,
        workspaceFolder: @escaping () -> URL? = { nil },
        onSelect: @escaping (SearchResult) -> Void = { _ in },
        onDismiss: @escaping () -> Void = {}
    ) {
        self.feature = feature
        self.workspaceFolder = workspaceFolder
        self.onSelect = onSelect
        self.onDismiss = onDismiss
        _query = State(initialValue: feature.query)
        _outcome = State(initialValue: feature.lastOutcome)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Rectangle()
                .fill(Color(nsColor: Self.textColor).opacity(0.12))
                .frame(height: 1)

            if let message = emptyStateMessage {
                Text(message)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(nsColor: Self.textColor).opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 22)
                    .accessibilityIdentifier(Self.emptyStateIdentifier)
            } else if results.isEmpty {
                Text(scopeDescription)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color(nsColor: Self.textColor).opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 22)
            } else {
                resultsList
            }

            footer
        }
        .frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)
        .foregroundStyle(Color(nsColor: Self.textColor))
        .background(Color(nsColor: Self.backgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Self.title))
        .onExitCommand(perform: onDismiss)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(nsColor: Self.textColor).opacity(0.7))
                .accessibilityHidden(true)

            TextField(Self.searchFieldPrompt, text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .monospaced))
                .focused($isSearchFieldFocused)
                .onAppear { isSearchFieldFocused = true }
                .onChange(of: query) { _, newQuery in
                    Task {
                        outcome = await feature.search(query: newQuery, workspaceFolder: workspaceFolder())
                        highlightedIndex = 0
                    }
                }
                .onSubmit(openHighlighted)
                .onKeyPress(.downArrow) { moveHighlight(by: 1) }
                .onKeyPress(.upArrow) { moveHighlight(by: -1) }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .accessibilityLabel(Text(Self.searchFieldLabel))
                .accessibilityIdentifier(Self.searchFieldIdentifier)

            Self.keycap("esc")
        }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                        Button {
                            onSelect(result)
                        } label: {
                            resultRow(result, isHighlighted: index == highlightedIndex)
                        }
                        .buttonStyle(.plain)
                        .id(result.id)
                        .onHover { hovering in
                            if hovering { highlightedIndex = index }
                        }
                        .accessibilityLabel(Text(result.displayName))
                        .accessibilityValue(Text(Self.matchFieldDescription(result.matchedField)))
                        .accessibilityAddTraits(index == highlightedIndex ? .isSelected : [])
                        .accessibilityIdentifier(Self.resultIdentifier(for: result))
                    }
                }
                .padding(6)
            }
            .frame(maxWidth: .infinity, maxHeight: 300, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlightedIndex) { _, index in
                guard results.indices.contains(index) else { return }
                proxy.scrollTo(results[index].id)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(Self.resultsListLabel))
            .accessibilityIdentifier(Self.resultsIdentifier)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let folder = workspaceFolder() {
                Label(folder.lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if emptyStateMessage == nil && !results.isEmpty {
                Text("↑↓ select")
                Text("↩ open")
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Color(nsColor: Self.textColor).opacity(0.6))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: Self.textColor).opacity(0.04))
    }

    /// What the palette searches, shown before anything is typed in a folder.
    private var scopeDescription: String {
        guard let folder = workspaceFolder() else { return Self.searchFieldPrompt }
        return "Type to search the notes in \(folder.lastPathComponent)"
    }

    private func moveHighlight(by offset: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .ignored }
        highlightedIndex = min(max(highlightedIndex + offset, 0), results.count - 1)
        return .handled
    }

    private func openHighlighted() {
        guard results.indices.contains(highlightedIndex) else { return }
        onSelect(results[highlightedIndex])
    }

    /// A small key-cap label, e.g. the `esc` hint beside the search field.
    static func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(nsColor: textColor).opacity(0.7))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(nsColor: textColor).opacity(0.25), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }

    /// The message the surface shows right now — or `nil` when it lists results instead.
    ///
    /// Derived at render time from the two things that decide it: the outcome of the last
    /// search and the folder the composition root's closure reports for the note that is
    /// open. With no note open that folder is `nil`, so the surface shows the locked
    /// no-workspace message from its first render — the launch state included, before any
    /// keystroke. It is `internal`, not private, so a test can assert that launch state on
    /// a real view without a window or a keystroke.
    var emptyStateMessage: String? {
        Self.emptyStateText(of: outcome, hasWorkspace: workspaceFolder() != nil)
    }

    private var results: [SearchResult] { outcome?.results ?? [] }

    @ViewBuilder
    private func resultRow(_ result: SearchResult, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Self.textColor).opacity(0.6))
                .accessibilityHidden(true)
            Text(result.displayName)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(Self.matchFieldDescription(result.matchedField))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(nsColor: Self.textColor).opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(Color(nsColor: Self.textColor).opacity(0.08))
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: Self.textColor).opacity(isHighlighted ? 0.12 : 0))
        )
        .contentShape(Rectangle())
    }

    /// The spoken description of what a result matched.
    static func matchFieldDescription(_ field: SearchMatchField) -> String {
        switch field {
        case .fileName: return "name"
        case .contents: return "contents"
        }
    }

    /// The locked window background (#000000) and the contrast-checked text colour,
    /// reused from the appearance owner so the search surface matches the document.
    static var backgroundColor: NSColor {
        DarkMonochromaticWindowAppearanceFeature.backgroundColor.nsColor
    }

    static var textColor: NSColor {
        DarkMonochromaticWindowAppearanceFeature.foregroundColor(preferred: .white).nsColor
    }
}
