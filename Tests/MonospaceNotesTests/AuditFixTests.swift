//
//  AuditFixTests.swift
//  MonospaceNotesTests
//
//  Focused regression tests for the fixes made after the code audit:
//
//    * `AppState.selectSearchResult(_:)` adopts the selected note's text onto the live
//      document surface (not only into `documentText`).
//    * A successful background autosave clears the dirty marker only when the buffer
//      that reached disk is still the current buffer.
//    * `AppState.terminate()` cancels and awaits the pending autosave timer.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import AppKit
import Foundation
import Testing

@testable import MonospaceNotes

// MARK: - File-scope doubles (unique names: every test file compiles into one module)

private struct AuditFixStubError: Error, Equatable, Sendable, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

/// A note-file seam with in-memory texts and a recorded write log. It never touches the
/// filesystem; the folder listing a search performs still sees the real files a test wrote.
private final class AuditFixStubFileAccess: NoteFileAccess, @unchecked Sendable {
    private var texts: [URL: String]
    private let writeError: Error?
    private(set) var written: [(contents: String, url: URL)] = []

    init(texts: [URL: String] = [:], writeError: Error? = nil) {
        self.texts = texts
        self.writeError = writeError
    }

    func readUTF8(from url: URL) async throws -> String {
        if let text = texts[url] { return text }
        throw AuditFixStubError(reason: "the double holds no text for that note")
    }

    func writeAtomically(_ contents: String, to url: URL) async throws {
        if let writeError { throw writeError }
        written.append((contents: contents, url: url))
    }
}

/// A panel seam that returns a fixed selection without ever presenting UI.
private final class AuditFixStubPanel: PanelPresenting, @unchecked Sendable {
    private let openURL: URL?
    private let saveURL: URL?

    init(openURL: URL? = nil, saveURL: URL? = nil) {
        self.openURL = openURL
        self.saveURL = saveURL
    }

    func chooseExistingNote() async -> URL? { openURL }

    func chooseNewNoteDestination(suggestedName: String) async -> URL? { saveURL }
}

private func auditFixScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("monospace-notes-audit-fix-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Tests

@Suite("Audit fixes: search adoption, autosave marker, termination")
@MainActor
struct AuditFixTests {

    @Test("Selecting a search result writes the note onto the live document surface")
    func searchSelectionAdoptsIntoTheDocumentSurface() async throws {
        let root = try auditFixScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("selected.txt")
        let body = "selected note body\n"
        try Data(body.utf8).write(to: note)

        let reader = AuditFixStubFileAccess(texts: [note: body])
        let state = AppState(
            noteFiles: reader,
            panels: AuditFixStubPanel(openURL: note),
            settings: UnconfiguredSettingsStore(),
            ioRecorder: FileIOThreadRecorder()
        )
        let textView = TextKit2DocumentView.makeDocumentTextView(
            text: "",
            font: state.documentFont,
            textColor: .white,
            backgroundColor: .black,
            isEditable: true
        )
        // Attach the surface to the keystroke path, as the real document view does.
        _ = state.handleKeystrokeInsert("x", in: textView)

        // Open the note so the workspace folder is established, then search it.
        await state.openDocument()
        #expect(state.documentText == body)

        // Change the surface, then select a result: the adoption must rewrite the surface.
        textView.string = "stale buffer"
        await state.focusSearch()
        await state.selectSearchResult(
            SearchResult(url: note, score: 1, matchedField: .fileName)
        )

        #expect(state.documentText == body)
        #expect(textView.string == body, "the selected note is written onto the live surface")
    }

    @Test("An autosave clears the dirty marker only for the buffer that reached disk")
    func autosaveClearsTheMarkerOnlyForTheCurrentBuffer() async throws {
        let root = try auditFixScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")
        try Data("body".utf8).write(to: note)

        let writer = AuditFixStubFileAccess(texts: [note: "body"])
        let state = AppState(
            noteFiles: writer,
            panels: AuditFixStubPanel(openURL: note),
            settings: UnconfiguredSettingsStore(),
            ioRecorder: FileIOThreadRecorder()
        )
        let textView = TextKit2DocumentView.makeDocumentTextView(
            text: "",
            font: state.documentFont,
            textColor: .white,
            backgroundColor: .black,
            isEditable: true
        )
        _ = state.handleKeystrokeInsert("hello", in: textView)
        #expect(state.hasUnsavedChanges)

        // Autosave the current buffer: the document is on disk, so the marker clears.
        await state.backgroundSave.saveNow(text: state.documentText, documentURL: note)
        #expect(state.hasUnsavedChanges == false, "an autosave of the current buffer clears the marker")

        // Edit again, then autosave an OLDER buffer: the marker must stay set.
        _ = state.handleKeystrokeInsert("!", in: textView)
        #expect(state.hasUnsavedChanges)
        await state.backgroundSave.saveNow(text: "an older buffer", documentURL: note)
        #expect(state.hasUnsavedChanges, "an autosave that did not save the current buffer keeps the marker")
    }

    @Test("Terminating cancels and awaits the pending autosave timer")
    func terminationCancelsTheAutosaveTimer() async {
        let state = AppState(
            noteFiles: AuditFixStubFileAccess(),
            panels: AuditFixStubPanel(),
            settings: UnconfiguredSettingsStore(),
            ioRecorder: FileIOThreadRecorder()
        )
        state.backgroundSave.startAutosave(
            buffer: "pending",
            documentURL: URL(fileURLWithPath: "/tmp/audit-fix-note.txt")
        )
        #expect(state.backgroundSave.pendingAutosaveCount == 1)

        _ = await state.terminate()

        #expect(state.backgroundSave.pendingAutosaveCount == 0, "the timer is cancelled")
        #expect(state.backgroundSave.runningOperationCount == 0, "nothing is left running")
    }
}
