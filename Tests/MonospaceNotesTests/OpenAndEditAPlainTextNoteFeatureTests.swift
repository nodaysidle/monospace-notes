//
//  OpenAndEditAPlainTextNoteFeatureTests.swift
//  MonospaceNotesTests
//
//  TASK-11-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE focused suite — owner
//  OWN-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE.
//
//  Covers FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE with
//  CON-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-INTERFACE / -RECOVERY,
//  CON-DATA-OPEN-DOCUMENT-BUFFER, CON-DATA-WORKSPACE-FOLDER-REFERENCE,
//  CON-PERSISTENCE-WORKSPACE-FOLDER-REFERENCE and CON-DATA-TYPOGRAPHY-SETTINGS against
//  the real `OpenAndEditAPlainTextNoteFeature`:
//
//    * ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-01 — a keystroke that changes the buffer marks
//      the document as having unsaved changes; an identical buffer does NOT. The
//      keystroke is a REAL AppKit insertion into a REAL TextKit 2 text view built by the
//      document surface's own factory, and the buffer before/after it is what the rule is
//      applied to.
//    * ACC-...-02 — a readable `.txt` file's EXACT UTF-8 decoded contents reach the text
//      view. Three real files are written by the real atomic writer of the real
//      `DataStore` and read back through it: non-ASCII text (umlauts, Japanese, an em
//      dash, a tab), CRLF line endings, and an EMPTY file. Each case asserts the on-disk
//      bytes, the text handed over, the text view's own string, and the text view's UTF-8
//      bytes against the file's bytes — plus that every newline of the CRLF file is still
//      a CRLF pair (the text is handed over verbatim, never normalised).
//    * ACC-...-03 — an unreadable file presents the modal alert titled EXACTLY
//      "Could Not Open Note" naming the file and the read error, while the previously open
//      document remains displayed and unchanged. Four unreadable shapes are covered: a
//      missing path, a directory named like a note, a file that is not valid UTF-8, and a
//      transport failure from the seam itself. Each asserts the alert, that no text and no
//      title are handed over, that the document path / workspace folder / unsaved-changes
//      marker are untouched, that the real text view still shows the open document, and
//      that no file was touched. An explicit retry (another Cmd+O) then succeeds and
//      dismisses the alert.
//    * ACC-...-04 — the window title equals the selected file's LAST PATH COMPONENT (a
//      nested folder and a non-ASCII name), and never the whole path or the folder name.
//
//  Also covered: the cancelled-panel branch (the current document and its path unchanged,
//  nothing read, no alert); an attempt cancelled before entry and an interrupted read; the
//  workspace folder being the opened note's PARENT FOLDER, in memory only, following the
//  note that is opened; discarding the document; and structural proofs that this owner
//  reads only through the shared seam and writes or persists nothing.
//
//  No assertion here depends on a wall-clock window or on a timing budget: there is no
//  measured criterion in this task. Every file lives in a unique temporary directory, and
//  no UI is ever presented — the panel presenter is a fake, and the feature's own default
//  is the neutral placeholder that can only report a cancel.
//
//  Every double is file-private and prefixed `OpenNoteTest`, so it cannot collide with
//  another suite in this module.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import AppKit
import Foundation
import Testing

@testable import MonospaceNotes

// MARK: - File-scope fixtures (unique names: every test file compiles into one module)

private typealias OpenNoteTestFeature = OpenAndEditAPlainTextNoteFeature

/// A scripted read failure with a distinctive reason, used where the failure comes from
/// the seam rather than from a real unreadable file.
private struct OpenNoteTestReadFailure: Error, CustomStringConvertible {
    let reason: String

    var description: String { reason }
}

/// Observes this owner's operation state from inside a read, so "the attempt is `.active`
/// while it runs" is a real observation rather than an assumption about the code.
@MainActor
private final class OpenNoteTestStateProbe {
    weak var feature: OpenNoteTestFeature?
    private(set) var statesAtReadEntry: [OperationState] = []

    func recordReadEntry() {
        guard let feature else { return }
        statesAtReadEntry.append(feature.openState)
    }
}

/// The note-file seam as a double: scripted texts and failures, a read log, and an optional
/// probe. It never touches the filesystem, and a write is recorded as a failure of this
/// feature's own contract (it must never write).
private final class OpenNoteTestNoteFileAccess: NoteFileAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [URL: String]
    private var failures: [URL: Error]
    private var readURLs: [URL] = []
    private var writeCount = 0
    private let probe: OpenNoteTestStateProbe?

    init(
        texts: [URL: String] = [:],
        failures: [URL: Error] = [:],
        probe: OpenNoteTestStateProbe? = nil
    ) {
        self.texts = texts
        self.failures = failures
        self.probe = probe
    }

    func readUTF8(from url: URL) async throws -> String {
        recordRead(url)

        if let probe {
            await probe.recordReadEntry()
        }

        if let failure = failure(for: url) {
            throw failure
        }
        if let text = text(for: url) {
            return text
        }
        throw OpenNoteTestReadFailure(reason: "this double holds no note for that path")
    }

    func writeAtomically(_ contents: String, to url: URL) async throws {
        recordWrite()
        Issue.record(
            "Open and edit a plain-text note must never write: writeAtomically was called for \(url.lastPathComponent)"
        )
        throw OpenNoteTestReadFailure(reason: "the open-note double is read-only")
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return readURLs.count
    }

    var reads: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return readURLs
    }

    var writes: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeCount
    }

    private func recordRead(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        readURLs.append(url)
    }

    private func recordWrite() {
        lock.lock()
        defer { lock.unlock() }
        writeCount += 1
    }

    private func text(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return texts[url]
    }

    private func failure(for url: URL) -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return failures[url]
    }
}

/// The open panel as a double: it answers with the scripted URL (or a cancel) and counts
/// how often it was asked. It never presents UI.
private final class OpenNoteTestPanelPresenter: PanelPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var existing: URL?
    private var presentations = 0

    init(existing: URL? = nil) {
        self.existing = existing
    }

    /// Scripts the answer of the next `chooseExistingNote()`. `nil` means "the user
    /// cancelled the panel".
    func script(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        existing = url
    }

    func chooseExistingNote() async -> URL? {
        nextExistingNote()
    }

    func chooseNewNoteDestination(suggestedName: String) async -> URL? {
        Issue.record("Open and edit a plain-text note never asks for a save destination")
        return nil
    }

    /// The synchronous half: the lock is taken outside any asynchronous context.
    private func nextExistingNote() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        presentations += 1
        return existing
    }

    var presentationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return presentations
    }
}

// MARK: - Helpers

/// A real scratch directory under the system temporary location, unique per call.
private func openNoteTestScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("monospace-notes-open-note-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func openNoteTestTearDown(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

/// A dedicated, unique defaults suite so no test can see another one's state, and so "this
/// owner persists nothing" is observable.
private func openNoteTestDefaultsSuite() throws -> (name: String, defaults: UserDefaults) {
    let name = "com.monospace.notes.tests.opennote.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name), "A dedicated defaults suite is required")
    return (name, defaults)
}

private func openNoteTestDiscardSuite(_ name: String) {
    UserDefaults.standard.removePersistentDomain(forName: name)
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(name).plist")
        .path
    if FileManager.default.fileExists(atPath: path) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Writes one real `.txt` note and returns its URL.
@discardableResult
private func openNoteTestWriteNote(named name: String, text: String, in folder: URL) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
}

/// Every entry under a directory, recursively, as absolute paths — the fingerprint a test
/// uses to prove nothing was created behind its back.
private func openNoteTestTree(_ root: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
    ) else {
        return []
    }
    return enumerator.compactMap { ($0 as? URL)?.path }.sorted()
}

/// The feature's own source, for the structural proofs.
private func openNoteTestFeatureSource() throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot
        .appendingPathComponent("Sources/MonospaceNotes/Features/OpenAndEditAPlainTextNoteFeature.swift")
    return String(decoding: try Data(contentsOf: url), as: UTF8.self)
}

/// A real TextKit 2 document text view, built by the document surface's own factory — the
/// same code `makeNSView` and `updateNSView` run — so what this suite asserts about the
/// text view is a statement about the surface the app displays.
@MainActor
private func openNoteTestDocumentTextView(document: String) -> NSTextView {
    TextKit2DocumentView.makeDocumentTextView(
        text: document,
        font: openNoteTestFont(),
        textColor: .white,
        backgroundColor: .black,
        isEditable: true
    )
}

/// The configured monospace font (Menlo at 13 points by default).
@MainActor
private func openNoteTestFont() -> NSFont {
    NSFont(
        name: TypographySettings.default.fontFamily,
        size: CGFloat(TypographySettings.default.pointSize)
    ) ?? NSFont.monospacedSystemFont(ofSize: CGFloat(TypographySettings.default.pointSize), weight: .regular)
}

// MARK: - Suite

@Suite("FEAT-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE open and edit a plain text note")
@MainActor
struct OpenAndEditAPlainTextNoteFeatureTests {

    // MARK: - The vocabulary of an attempt

    @Test("An attempt is idle, then active while the note is read, then succeeded")
    func attemptStatesAreIdleActiveAndSucceeded() async throws {
        let directory = try openNoteTestScratchDirectory()
        defer { openNoteTestTearDown(directory) }

        let noteURL = try openNoteTestWriteNote(named: "first note.txt", text: "first revision\n", in: directory)
        let probe = OpenNoteTestStateProbe()
        let noteFiles = OpenNoteTestNoteFileAccess(texts: [noteURL: "first revision\n"], probe: probe)
        let feature = OpenNoteTestFeature(noteFiles: noteFiles, panels: OpenNoteTestPanelPresenter())

        // Nothing has been attempted yet.
        #expect(feature.openState == .idle)
        #expect(feature.lastOutcome == nil)
        #expect(feature.lastErrorAlert == nil)
        #expect(feature.lastOpenedURL == nil)
        #expect(feature.workspaceFolder == nil)
        #expect(feature.hasUnsavedChanges == false)
        #expect(feature.readAttemptCount == 0)
        #expect(feature.panelPresentationCount == 0)

        probe.feature = feature
        let outcome = await feature.open(url: noteURL)

        #expect(probe.statesAtReadEntry == [.active], "the attempt is active while the note is being read")
        #expect(outcome.state == .succeeded)
        #expect(outcome.opened)
        #expect(feature.openState == .succeeded)
        #expect(feature.lastOutcome == outcome)
        #expect(feature.lastErrorAlert == nil)
        #expect(feature.lastOpenedURL == noteURL)
        #expect(feature.workspaceFolder == directory)
        #expect(feature.hasUnsavedChanges == false, "a freshly opened note is not marked as having unsaved changes")
        #expect(feature.readAttemptCount == 1)
        #expect(feature.panelPresentationCount == 0, "a direct open presents no panel")
        #expect(noteFiles.reads == [noteURL], "exactly the path it was given was read")
        #expect(noteFiles.writes == 0, "opening a note writes nothing")
    }

    // MARK: - ACC-02: the exact UTF-8 contents reach the text view

    @Test("ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-02: the text view contains exactly the file's UTF-8 contents")
    func readableNoteReachesTheTextViewExactly() async throws {
        let directory = try openNoteTestScratchDirectory()
        let (suiteName, defaults) = try openNoteTestDefaultsSuite()
        defer {
            openNoteTestTearDown(directory)
            openNoteTestDiscardSuite(suiteName)
        }

        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let feature = OpenNoteTestFeature(noteFiles: store, panels: OpenNoteTestPanelPresenter())

        // Three real notes: non-ASCII text, CRLF line endings, and an empty file.
        let cases: [(name: String, text: String)] = [
            (
                "Grüße aus Ljubljana — 日本語 ✓.txt",
                "Grüße, café, Здравствуй — 日本語 ✓\nzweite Zeile\tTab\nletzte Zeile ohne Zeilenende"
            ),
            ("crlf note.txt", "first line\r\nsecond line\r\n\r\nfourth line\r\n"),
            ("empty note.txt", ""),
        ]

        var fixtures: [(name: String, text: String, url: URL, bytes: Data)] = []
        for testCase in cases {
            let url = directory.appendingPathComponent(testCase.name)
            // A real file, written by the real atomic writer of the real DataStore.
            try await store.writeAtomically(testCase.text, to: url)
            let bytes = try Data(contentsOf: url)
            #expect(
                bytes == Data(testCase.text.utf8),
                "the file on disk holds exactly the UTF-8 bytes of \(testCase.name)"
            )
            fixtures.append((testCase.name, testCase.text, url, bytes))
        }

        // Nothing this suite does from here on may create anything.
        let treeAfterWritingTheFixtures = openNoteTestTree(directory)
        #expect(treeAfterWritingTheFixtures.count == cases.count, "exactly the three fixtures exist")

        for fixture in fixtures {
            let outcome = await feature.open(url: fixture.url)
            #expect(outcome.state == .succeeded, "\(fixture.name) is readable and must open")
            #expect(outcome.opened)
            #expect(
                outcome.text == fixture.text,
                "the note's exact UTF-8 decoded contents are what the feature hands over"
            )

            // The document surface's own text view, built by the surface's own factory.
            let textView = openNoteTestDocumentTextView(document: "")
            #expect(textView.textLayoutManager != nil, "the document surface is a TextKit 2 text view")

            #expect(
                feature.adoptOpenedDocument(outcome, into: textView),
                "the opened note's text is adopted into the document surface"
            )
            #expect(
                textView.string == fixture.text,
                "the text view contains EXACTLY the file's UTF-8 decoded contents (\(fixture.name))"
            )
            #expect(
                Data(textView.string.utf8) == fixture.bytes,
                "the text view holds the file's bytes, byte for byte (\(fixture.name))"
            )

            // The surface's own update path renders the same text.
            let surfaceTextView = openNoteTestDocumentTextView(document: "")
            TextKit2DocumentView.apply(
                text: outcome.text ?? "",
                font: openNoteTestFont(),
                textColor: .white,
                backgroundColor: .black,
                isEditable: true,
                to: surfaceTextView
            )
            #expect(
                surfaceTextView.string == fixture.text,
                "the surface's own renderer shows exactly the file's contents (\(fixture.name))"
            )

            #expect(outcome.windowTitle == fixture.name, "the window title is the file's name")
            #expect(feature.workspaceFolder == directory, "the workspace folder is the note's parent folder")
        }

        // The CRLF file kept its carriage returns: the text is handed over verbatim and
        // never normalised to Unix line endings.
        let crlf = fixtures[1]
        let crlfTextView = openNoteTestDocumentTextView(document: "")
        let crlfOutcome = await feature.open(url: crlf.url)
        #expect(feature.adoptOpenedDocument(crlfOutcome, into: crlfTextView))
        #expect(crlfTextView.string.contains("\r\n"), "the CRLF pairs survived the read and the adoption")
        #expect(
            crlfTextView.string.replacingOccurrences(of: "\r\n", with: "").contains("\n") == false,
            "every newline of the CRLF note is still a CRLF pair — no bare LF was introduced"
        )
        #expect(Data(crlfTextView.string.utf8) == crlf.bytes)

        // The empty file stays empty rather than showing anything invented.
        let empty = fixtures[2]
        let emptyTextView = openNoteTestDocumentTextView(document: "leftover text")
        let emptyOutcome = await feature.open(url: empty.url)
        #expect(emptyOutcome.text == "")
        #expect(empty.bytes.isEmpty)
        #expect(feature.adoptOpenedDocument(emptyOutcome, into: emptyTextView))
        #expect(emptyTextView.string == "", "an empty note shows an empty document")

        // Every read went through the shared seam, off the main actor.
        #expect(recorder.totalOperations >= cases.count * 2, "the reads and writes were recorded by the store")
        #expect(recorder.mainThreadViolations == 0, "no note read ran on the main thread")

        // Nothing was created or persisted by opening and displaying notes.
        #expect(
            openNoteTestTree(directory) == treeAfterWritingTheFixtures,
            "no temporary file, cache or lock file was left behind"
        )
        #expect(
            (defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty,
            "opening a note persists nothing: the settings suite holds no key at all"
        )
    }

    // MARK: - ACC-04: the window title

    @Test("ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-04: the window title is the selected file's last path component")
    func windowTitleIsTheLastPathComponent() async throws {
        let directory = try openNoteTestScratchDirectory()
        defer { openNoteTestTearDown(directory) }

        let nested = directory
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent("Archive", isDirectory: true)
        let noteURL = try openNoteTestWriteNote(named: "Zapiski ✓.txt", text: "vsebina\n", in: nested)

        let presenter = OpenNoteTestPanelPresenter(existing: noteURL)
        let feature = OpenNoteTestFeature(
            noteFiles: OpenNoteTestNoteFileAccess(texts: [noteURL: "vsebina\n"]),
            panels: presenter
        )

        let outcome = await feature.openViaPanel()
        #expect(outcome.state == .succeeded)
        #expect(outcome.windowTitle == noteURL.lastPathComponent, "the title is the file's last path component")
        #expect(outcome.windowTitle == "Zapiski ✓.txt")
        #expect(outcome.windowTitle != noteURL.path, "the title is not the whole path")
        #expect(outcome.windowTitle != nested.lastPathComponent, "the title is not the parent folder's name")
        #expect(
            OpenNoteTestFeature.windowTitle(for: noteURL) == noteURL.lastPathComponent,
            "the one title rule is the file's last path component"
        )
        #expect(
            OpenNoteTestFeature.noDocumentWindowTitle == LockedIdentity.bundleName,
            "with no note open the title is the app name"
        )

        // A failed open hands over no title at all, so the title of the open document is
        // never moved by one.
        let failed = await feature.open(url: nested.appendingPathComponent("gone.txt"))
        #expect(failed.state == .failed)
        #expect(failed.windowTitle == nil)
        #expect(feature.lastOpenedURL == noteURL, "the open document's path is unchanged")

        // A cancelled panel hands over no title either.
        presenter.script(nil)
        let cancelled = await feature.openViaPanel()
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.windowTitle == nil)
        #expect(feature.lastOpenedURL == noteURL)
    }

    // MARK: - ACC-03: an unreadable file

    @Test("ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-03: an unreadable file presents the locked alert and keeps the document")
    func unreadableNotePresentsTheLockedAlertAndKeepsTheDocument() async throws {
        let directory = try openNoteTestScratchDirectory()
        let (suiteName, defaults) = try openNoteTestDefaultsSuite()
        defer {
            openNoteTestTearDown(directory)
            openNoteTestDiscardSuite(suiteName)
        }

        let sentinelBody = "SECRET-NOTE-BODY-MUST-NEVER-BE-REPORTED"

        // The document that is open before every failure: a real note in a real folder,
        // read through the real store.
        let openFolder = directory.appendingPathComponent("Open", isDirectory: true)
        let openNoteURL = try openNoteTestWriteNote(named: "open note.txt", text: "the document that is open\n", in: openFolder)
        let recorder = FileIOThreadRecorder()
        let store = DataStore(defaults: defaults, recorder: recorder)
        let presenter = OpenNoteTestPanelPresenter()
        let feature = OpenNoteTestFeature(noteFiles: store, panels: presenter)

        let opened = await feature.open(url: openNoteURL)
        #expect(opened.state == .succeeded)
        let textView = openNoteTestDocumentTextView(document: "")
        #expect(feature.adoptOpenedDocument(opened, into: textView))
        #expect(textView.string == "the document that is open\n")

        // The user has typed since: the marker is set, so the failure below also proves the
        // marker is not silently cleared.
        #expect(feature.noteEdit(previous: "", new: "the document that is open\n"))
        #expect(feature.hasUnsavedChanges)

        let previousURL = feature.lastOpenedURL
        let previousFolder = feature.workspaceFolder

        // Four shapes of "this note cannot be read". The first three are real filesystem
        // states read by the real store; the fourth is the seam's own transport failure.
        let missing = directory.appendingPathComponent("missing note.txt")
        let directoryNamedLikeANote = directory.appendingPathComponent("folder.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryNamedLikeANote, withIntermediateDirectories: true)
        let invalidUTF8 = directory.appendingPathComponent("invalid utf8.txt")
        try Data(Data("\(sentinelBody)\n".utf8) + Data([0xC3, 0x28, 0x0A])).write(to: invalidUTF8)

        let unreadable: [(url: URL, expectedReason: String?)] = [
            (missing, "the file does not exist"),
            (directoryNamedLikeANote, nil),
            (invalidUTF8, "the file is not valid UTF-8 text"),
        ]

        for target in unreadable {
            let treeBefore = openNoteTestTree(directory)
            let readsBefore = feature.readAttemptCount

            let outcome = await feature.open(url: target.url)

            #expect(outcome.state == .failed, "\(target.url.lastPathComponent) cannot be read")
            #expect(feature.openState == .failed)
            #expect(outcome.opened == false)
            #expect(outcome.text == nil, "a failed read hands over no text")
            #expect(outcome.windowTitle == nil, "a failed read hands over no title")
            #expect(outcome.url == target.url, "the failed outcome names the file it addressed")
            #expect(feature.readAttemptCount == readsBefore + 1, "exactly one read was attempted")

            let alert = try #require(outcome.errorAlert, "a failed read presents an alert")
            #expect(alert.title == "Could Not Open Note", "the alert title is the locked string, exactly")
            #expect(alert.message.contains(target.url.lastPathComponent), "the alert names the file")
            #expect(alert.message.contains(target.url.path), "the alert names the file by its path")
            #expect(alert.message.isEmpty == false)
            #expect(alert.message.contains(sentinelBody) == false, "the alert never carries note contents")
            if let expectedReason = target.expectedReason {
                #expect(alert.message.contains(expectedReason), "the alert names the read error")
            }
            #expect(alert.message.contains("unchanged"), "the alert states that the open document is unchanged")
            #expect(feature.lastErrorAlert == alert)

            // The previously open document remains displayed and unchanged.
            #expect(feature.lastOpenedURL == previousURL, "the document path is unchanged")
            #expect(feature.workspaceFolder == previousFolder, "the workspace folder is unchanged")
            #expect(feature.hasUnsavedChanges, "the unsaved-changes marker is untouched")
            #expect(
                feature.adoptOpenedDocument(outcome, into: textView) == false,
                "a failed outcome adopts nothing"
            )
            #expect(
                textView.string == "the document that is open\n",
                "the text view still shows the document that was open"
            )
            #expect(openNoteTestTree(directory) == treeBefore, "the failed open touched no file")
        }

        // The seam's own failure: the alert names the file and the read error.
        let transportURL = directory.appendingPathComponent("unplugged.txt")
        let failingAccess = OpenNoteTestNoteFileAccess(
            failures: [transportURL: OpenNoteTestReadFailure(reason: "the volume was unplugged")]
        )
        let failingFeature = OpenNoteTestFeature(noteFiles: failingAccess, panels: presenter)
        let transportOutcome = await failingFeature.open(url: transportURL)
        #expect(transportOutcome.state == .failed)
        let transportAlert = try #require(transportOutcome.errorAlert)
        #expect(transportAlert.title == "Could Not Open Note")
        #expect(transportAlert.message.contains("unplugged.txt"))
        #expect(transportAlert.message.contains("the volume was unplugged"), "the alert names the read error")
        #expect(failingAccess.writes == 0, "a failed open writes nothing")

        // The reads of the real store stayed off the main thread.
        #expect(recorder.mainThreadViolations == 0)
        #expect(recorder.totalOperations > 0)
    }

    @Test("An explicit retry after a failed open succeeds and dismisses the alert")
    func explicitRetryAfterFailureSucceeds() async throws {
        let directory = try openNoteTestScratchDirectory()
        let (suiteName, defaults) = try openNoteTestDefaultsSuite()
        defer {
            openNoteTestTearDown(directory)
            openNoteTestDiscardSuite(suiteName)
        }

        let good = try openNoteTestWriteNote(named: "note.txt", text: "second attempt\n", in: directory)
        let presenter = OpenNoteTestPanelPresenter(existing: directory.appendingPathComponent("missing.txt"))
        let feature = OpenNoteTestFeature(
            noteFiles: DataStore(defaults: defaults, recorder: FileIOThreadRecorder()),
            panels: presenter
        )

        let first = await feature.openViaPanel()
        #expect(first.state == .failed)
        #expect(first.errorAlert?.title == "Could Not Open Note")
        #expect(feature.lastErrorAlert != nil)
        #expect(feature.lastOpenedURL == nil, "a failed open adopts nothing")

        // The explicit retry: Cmd+O again, with a note that can be read.
        presenter.script(good)
        let second = await feature.openViaPanel()
        #expect(second.state == .succeeded)
        #expect(second.text == "second attempt\n")
        #expect(second.errorAlert == nil, "a successful attempt produces no alert")
        #expect(feature.lastErrorAlert == nil, "so the alert of the failed attempt is dismissed")
        #expect(feature.openState == .succeeded)
        #expect(feature.panelPresentationCount == 2, "the retry presented the panel again")
        #expect(feature.lastOpenedURL == good)
        #expect(feature.hasUnsavedChanges == false)
    }

    // MARK: - ACC-01: a keystroke marks the document as having unsaved changes

    @Test("ACC-OPEN-AND-EDIT-A-PLAIN-TEXT-NOTE-01: a changed buffer is marked as having unsaved changes, an identical one is not")
    func keystrokeMarksUnsavedChangesAndAnIdenticalBufferDoesNot() async throws {
        let directory = try openNoteTestScratchDirectory()
        let (suiteName, defaults) = try openNoteTestDefaultsSuite()
        defer {
            openNoteTestTearDown(directory)
            openNoteTestDiscardSuite(suiteName)
        }

        let noteURL = try openNoteTestWriteNote(named: "edit me.txt", text: "hello", in: directory)
        let feature = OpenNoteTestFeature(
            noteFiles: DataStore(defaults: defaults, recorder: FileIOThreadRecorder()),
            panels: OpenNoteTestPanelPresenter()
        )

        let outcome = await feature.open(url: noteURL)
        #expect(outcome.state == .succeeded)
        let textView = openNoteTestDocumentTextView(document: "")
        #expect(feature.adoptOpenedDocument(outcome, into: textView))
        #expect(textView.string == "hello")
        #expect(feature.hasUnsavedChanges == false, "a note that was just opened has no unsaved changes")

        // A real keystroke, typed into the real document surface.
        let before = textView.string
        textView.insertText("!", replacementRange: NSRange(location: (before as NSString).length, length: 0))
        let after = textView.string
        #expect(after == "hello!", "the keystroke really changed the buffer")

        #expect(feature.markEdited(previous: before, new: after), "a changed buffer must be marked")
        #expect(feature.noteEdit(previous: before, new: after), "and the document is marked as having unsaved changes")
        #expect(feature.hasUnsavedChanges, "the open document is marked as having unsaved changes")

        // A keystroke that produced an identical buffer is NOT marked.
        #expect(feature.markEdited(previous: after, new: after) == false)
        #expect(feature.noteEdit(previous: after, new: after) == false)
        #expect(feature.hasUnsavedChanges, "an identical buffer must not clear an edit that was already made")

        // After a save the marker is clear, and it stays clear for identical buffers only.
        feature.markSaved()
        #expect(feature.hasUnsavedChanges == false)
        #expect(feature.noteEdit(previous: after, new: after) == false)
        #expect(feature.hasUnsavedChanges == false, "an identical buffer never marks the document")

        // A deletion changes the buffer too.
        textView.insertText("", replacementRange: NSRange(location: 5, length: 1))
        #expect(textView.string == "hello", "the deletion really changed the buffer back")
        #expect(feature.noteEdit(previous: after, new: textView.string), "a deletion is a change")
        #expect(feature.hasUnsavedChanges)

        // The surface and the buffer are the same document throughout.
        #expect(textView.string == "hello")
    }

    // MARK: - The cancelled panel

    @Test("A cancelled open panel leaves the current document and its path unchanged and reads nothing")
    func cancelledPanelChangesNothing() async throws {
        let directory = try openNoteTestScratchDirectory()
        let (suiteName, defaults) = try openNoteTestDefaultsSuite()
        defer {
            openNoteTestTearDown(directory)
            openNoteTestDiscardSuite(suiteName)
        }

        let noteURL = try openNoteTestWriteNote(named: "open me.txt", text: "the open document\n", in: directory)
        let presenter = OpenNoteTestPanelPresenter(existing: noteURL)
        let feature = OpenNoteTestFeature(
            noteFiles: DataStore(defaults: defaults, recorder: FileIOThreadRecorder()),
            panels: presenter
        )

        let opened = await feature.openViaPanel()
        #expect(opened.state == .succeeded)
        #expect(feature.panelPresentationCount == 1)
        let readsAfterOpening = feature.readAttemptCount
        let textView = openNoteTestDocumentTextView(document: "")
        #expect(feature.adoptOpenedDocument(opened, into: textView))
        let treeAfterOpening = openNoteTestTree(directory)

        // The user cancels the panel.
        presenter.script(nil)
        let cancelled = await feature.openViaPanel()

        #expect(cancelled.state == .cancelled)
        #expect(feature.openState == .cancelled, "a cancelled panel is a cancelled attempt")
        #expect(cancelled.url == nil, "a cancelled panel established no note")
        #expect(cancelled.text == nil)
        #expect(cancelled.windowTitle == nil)
        #expect(cancelled.errorAlert == nil, "a cancelled panel is not an error")
        #expect(feature.lastErrorAlert == nil)

        // The current document and its path are unchanged, and nothing was read.
        #expect(feature.panelPresentationCount == 2, "the panel was presented")
        #expect(feature.readAttemptCount == readsAfterOpening, "a cancelled panel reads nothing")
        #expect(feature.lastOpenedURL == noteURL, "the document path is unchanged")
        #expect(feature.workspaceFolder == directory, "the workspace folder is unchanged")
        #expect(feature.hasUnsavedChanges == false, "the unsaved-changes marker is unchanged")
        #expect(feature.adoptOpenedDocument(cancelled, into: textView) == false)
        #expect(textView.string == "the open document\n", "the text view still shows the open document")
        #expect(openNoteTestTree(directory) == treeAfterOpening, "the cancelled panel touched no file")

        // A cancelled panel after a failed open dismisses that alert: the alert surface is
        // assigned on every terminal path.
        _ = await feature.open(url: directory.appendingPathComponent("gone.txt"))
        #expect(feature.lastErrorAlert != nil)
        presenter.script(nil)
        let cancelledRetry = await feature.openViaPanel()
        #expect(cancelledRetry.state == .cancelled)
        #expect(feature.lastErrorAlert == nil, "the retry that was cancelled dismisses the alert")
        #expect(feature.lastOpenedURL == noteURL, "and still leaves the document open")
        #expect(textView.string == "the open document\n")
    }

    // MARK: - Cancellation

    @Test("An attempt cancelled before entry, and an interrupted read, publish cancelled and adopt nothing")
    func cancellationBranchesAdoptNothing() async throws {
        let directory = try openNoteTestScratchDirectory()
        defer { openNoteTestTearDown(directory) }

        let noteURL = try openNoteTestWriteNote(named: "note.txt", text: "a note\n", in: directory)

        // 1. Cancelled before entry: no panel is presented and nothing is read.
        let presenter = OpenNoteTestPanelPresenter(existing: noteURL)
        let noteFiles = OpenNoteTestNoteFileAccess(texts: [noteURL: "a note\n"])
        let feature = OpenNoteTestFeature(noteFiles: noteFiles, panels: presenter)

        let task = Task { await feature.openViaPanel() }
        task.cancel()
        let preCancelled = await task.value

        #expect(preCancelled.state == .cancelled)
        #expect(feature.openState == .cancelled)
        #expect(presenter.presentationCount == 0, "a cancelled attempt presents no panel")
        #expect(noteFiles.readCount == 0, "a cancelled attempt reads nothing")
        #expect(preCancelled.errorAlert == nil, "a cancellation is not an error")
        #expect(preCancelled.text == nil)
        #expect(feature.lastOpenedURL == nil)
        #expect(feature.workspaceFolder == nil)

        // 2. The read is interrupted: the shared reader reports a cancelled operation with
        //    CancellationError, which is not a read failure.
        let cancelledURL = directory.appendingPathComponent("cancelled.txt")
        let cancellingAccess = OpenNoteTestNoteFileAccess(failures: [cancelledURL: CancellationError()])
        let cancellingFeature = OpenNoteTestFeature(noteFiles: cancellingAccess, panels: presenter)

        let interrupted = await cancellingFeature.open(url: cancelledURL)
        #expect(interrupted.state == .cancelled)
        #expect(cancellingFeature.openState == .cancelled)
        #expect(interrupted.errorAlert == nil, "an interruption is not a read failure, so there is no alert")
        #expect(interrupted.text == nil)
        #expect(interrupted.windowTitle == nil)
        #expect(cancellingFeature.lastErrorAlert == nil)
        #expect(cancellingFeature.lastOpenedURL == nil, "nothing was adopted")
        #expect(cancellingFeature.workspaceFolder == nil)
        #expect(cancellingFeature.hasUnsavedChanges == false)
    }

    // MARK: - The workspace folder

    @Test("The workspace folder is the opened note's parent folder, in memory only")
    func workspaceFolderIsTheOpenedNotesParentFolder() async throws {
        let directory = try openNoteTestScratchDirectory()
        let (suiteName, defaults) = try openNoteTestDefaultsSuite()
        defer {
            openNoteTestTearDown(directory)
            openNoteTestDiscardSuite(suiteName)
        }

        let firstFolder = directory.appendingPathComponent("Notes", isDirectory: true)
        let secondFolder = firstFolder.appendingPathComponent("Archive", isDirectory: true)
        let firstNote = try openNoteTestWriteNote(named: "first.txt", text: "one\n", in: firstFolder)
        let secondNote = try openNoteTestWriteNote(named: "second.txt", text: "two\n", in: secondFolder)

        let recorder = FileIOThreadRecorder()
        let feature = OpenNoteTestFeature(
            noteFiles: DataStore(defaults: defaults, recorder: recorder),
            panels: OpenNoteTestPanelPresenter()
        )

        #expect(feature.workspaceFolder == nil, "no note is open, so there is no folder")

        // Opening a note is what establishes the folder reference.
        let first = await feature.open(url: firstNote)
        #expect(first.state == .succeeded)
        #expect(feature.workspaceFolder == firstFolder, "the parent folder of the open note")
        #expect(feature.workspaceFolder == firstNote.deletingLastPathComponent())
        #expect(feature.workspaceFolder != directory, "not the folder that contains the folder")
        #expect(OpenNoteTestFeature.workspaceFolder(forNoteAt: firstNote) == firstFolder)
        #expect(OpenNoteTestFeature.workspaceFolder(forNoteAt: nil) == nil)

        // Opening another note is what moves it.
        let second = await feature.open(url: secondNote)
        #expect(second.state == .succeeded)
        #expect(feature.workspaceFolder == secondFolder)

        let treeAfterOpening = openNoteTestTree(directory)

        // A failed open does not move it, and neither does a cancelled panel.
        _ = await feature.open(url: directory.appendingPathComponent("gone.txt"))
        #expect(feature.workspaceFolder == secondFolder, "a failed open leaves the folder reference alone")
        #expect(feature.lastOpenedURL == secondNote)

        // In memory only: nothing about the folder or the document is persisted, and no file
        // is created anywhere by opening or editing a note.
        #expect(
            (defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty,
            "the workspace folder and the document buffer are never persisted"
        )
        #expect(
            openNoteTestTree(directory) == treeAfterOpening,
            "opening notes created no file — not even a temporary one"
        )
        #expect(recorder.mainThreadViolations == 0)
    }

    @Test("Closing the document drops the in-memory references and persists nothing")
    func discardingTheDocumentDropsInMemoryState() async throws {
        let directory = try openNoteTestScratchDirectory()
        let (suiteName, defaults) = try openNoteTestDefaultsSuite()
        defer {
            openNoteTestTearDown(directory)
            openNoteTestDiscardSuite(suiteName)
        }

        let noteURL = try openNoteTestWriteNote(named: "closing.txt", text: "closing time\n", in: directory)
        let feature = OpenNoteTestFeature(
            noteFiles: DataStore(defaults: defaults, recorder: FileIOThreadRecorder()),
            panels: OpenNoteTestPanelPresenter()
        )

        let opened = await feature.open(url: noteURL)
        #expect(opened.state == .succeeded)
        #expect(feature.noteEdit(previous: "", new: "closing time\n"))
        #expect(feature.hasUnsavedChanges)
        let treeAfterOpening = openNoteTestTree(directory)

        feature.discardOpenDocument()

        #expect(feature.lastOpenedURL == nil, "the document path reference is dropped")
        #expect(feature.workspaceFolder == nil, "the workspace folder reference is dropped")
        #expect(feature.hasUnsavedChanges == false)
        #expect(feature.lastOutcome == nil)
        #expect(feature.lastErrorAlert == nil)
        #expect(feature.openState == .idle)

        #expect(
            (defaults.persistentDomain(forName: suiteName) ?? [:]).isEmpty,
            "closing a document persists nothing — there is nothing to persist"
        )
        #expect(openNoteTestTree(directory) == treeAfterOpening, "closing a document touched no file")
    }

    // MARK: - Structural proofs

    @Test("The note is read through the shared seam and this owner writes and persists nothing")
    func structuralProofs() throws {
        let source = try openNoteTestFeatureSource()

        // The read is the shared seam's, off the main actor by its own contract.
        #expect(source.contains("noteFiles.readUTF8(from: url)"), "reads travel through the shared seam")

        // Nothing here can write, rename, remove, or persist anything, and no network API
        // is reachable from this file.
        let forbidden = [
            "writeAtomically",
            "FileManager",
            "Data(contentsOf",
            "write(to:",
            "FileHandle",
            "NSTemporaryDirectory",
            "temporaryDirectory",
            "posixRename",
            "moveItem",
            "replaceItemAt",
            "removeItem(at:",
            "rename(",
            "UserDefaults",
            "URLSession",
            "NSURLConnection",
            "NSURLRequest",
            "CFNetwork",
            "import Network",
            "AppState",
        ]
        for token in forbidden {
            #expect(source.contains(token) == false, "OpenAndEditAPlainTextNoteFeature.swift must not contain \(token)")
        }

        // The locked surface this task owns.
        #expect(source.contains("func open(url: URL) async -> OpenOutcome"))
        #expect(source.contains("func openViaPanel() async -> OpenOutcome"))
        #expect(source.contains("func markEdited(previous: String, new: String) -> Bool"))
        #expect(source.contains("\"Could Not Open Note\""), "the locked alert title is declared")
        #expect(source.contains("init(noteFiles: any NoteFileAccess"), "the seam is injected, never constructed per call")
    }
}
