//
//  PermissionCoordinatorTests.swift
//  MonospaceNotesTests
//
//  TASK-07-PERMISSION-COORDINATOR focused suite — owner OWN-PERMISSION-COORDINATOR.
//
//  Covers CON-PERMISSION-FILESYSTEM against the real `PermissionCoordinator` and the real
//  `NativePanelPresenter`:
//
//    * the standard panels this app presents are restricted to plain text `.txt` — the
//      assertion is made on the real `NSOpenPanel`/`NSSavePanel` configuration objects,
//      which are never shown, so the suite runs headless and cannot hang;
//    * the denied path (the user closes the panel) returns nil and leaves the existing
//      state exactly as it was, and another explicit selection still succeeds;
//    * access scopes balance: `beginAccess`/`endAccess` return `activeScopeCount` to 0,
//      `releaseAllScopes()` is safe and idempotent, and a location that carries no
//      security-scoped bookmark leaks no scope on failure.
//
//  No test path ever calls `runModal()` or `begin()`: only `makeOpenPanel()` and
//  `makeSavePanel(suggestedName:)` are exercised, and every chooser test drives an
//  injected scripted `PanelPresenting` instead of AppKit.
//
//  Scheduling notes (measured on this machine, not assumed)
//  -------------------------------------------------------
//    * Building an AppKit panel is a synchronous main-actor cost: ~450 ms for the first
//      panel of the process and ~155 ms for each one after that. The lifecycle suite
//      asserts on 300–600 ms sleep windows while it owns the main actor, so several
//      panel constructions scattered through a parallel run starve it. The panels under
//      test are therefore built once, after a deliberate quiet-window wait, and the
//      suite is serialized so its own tests never flood the main actor.
//      The wait decides only *when* the panels are built; every assertion below is still
//      made on real, freshly configured panel objects.
//    * No assertion in this file depends on wall-clock timing.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import MonospaceNotes

// MARK: - File-scope fixtures (unique names: every test file compiles together)

/// Scripted `PanelPresenting` double. It shows nothing: it records what it was asked and
/// answers from a queue, so a cancel, a non-`.txt` selection, and a successful selection
/// can all be driven deterministically from a test.
private final class PermissionFakePanelPresenter: PanelPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var openAnswers: [URL?]
    private var saveAnswers: [URL?]
    private var openCallCount = 0
    private var saveCallCount = 0
    private var suggestedNames: [String] = []

    /// An empty queue answers `nil`, i.e. "the user cancelled the panel".
    init(openAnswers: [URL?] = [], saveAnswers: [URL?] = []) {
        self.openAnswers = openAnswers
        self.saveAnswers = saveAnswers
    }

    func chooseExistingNote() async -> URL? {
        locked {
            openCallCount += 1
            return openAnswers.isEmpty ? nil : openAnswers.removeFirst()
        }
    }

    func chooseNewNoteDestination(suggestedName: String) async -> URL? {
        locked {
            saveCallCount += 1
            suggestedNames.append(suggestedName)
            return saveAnswers.isEmpty ? nil : saveAnswers.removeFirst()
        }
    }

    var recordedOpenCallCount: Int { locked { openCallCount } }
    var recordedSaveCallCount: Int { locked { saveCallCount } }
    var recordedSuggestedNames: [String] { locked { suggestedNames } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The real panels under test, built once per test run by the production
/// `NativePanelPresenter` and never shown.
@MainActor
private enum PermissionPanelFixture {

    /// Waits long enough for the timing-sensitive windows of the other suites (300–600 ms
    /// sleeps) to clear before paying the one-off AppKit panel cost.
    static let quietWindowMilliseconds = 2_000

    private static var built: (firstOpen: NSOpenPanel, secondOpen: NSOpenPanel, save: NSSavePanel)?
    private static var didWaitForQuietWindow = false

    static func panels() async -> (firstOpen: NSOpenPanel, secondOpen: NSOpenPanel, save: NSSavePanel) {
        if let built { return built }

        if !didWaitForQuietWindow {
            didWaitForQuietWindow = true
            try? await Task.sleep(for: .milliseconds(quietWindowMilliseconds))
        }

        let presenter = NativePanelPresenter()
        let firstOpen = presenter.makeOpenPanel()
        // Between constructions, let anything queued run before this suite takes the main
        // actor again: each construction blocks the main actor synchronously.
        await Task.yield()
        let secondOpen = presenter.makeOpenPanel()
        await Task.yield()
        let save = presenter.makeSavePanel(suggestedName: "Draft.txt")

        built = (firstOpen, secondOpen, save)
        return (firstOpen, secondOpen, save)
    }
}

/// A real note on disk inside its own unique scratch directory.
private struct PermissionTestNote {
    let directory: URL
    let file: URL
}

private func permissionTestMakeNote(
    named name: String = "note.txt",
    contents: String = "hello\n"
) throws -> PermissionTestNote {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mn-permission-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: file)
    return PermissionTestNote(directory: directory, file: file)
}

private func permissionTestRemove(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

// MARK: - Suite

/// Serialized on purpose: this suite's AppKit fixture blocks the main actor, so its tests
/// run one at a time instead of flooding the main actor of a parallel test run. No
/// assertion depends on serialization.
@Suite("Permission coordinator", .serialized)
struct PermissionCoordinatorTests {

    // MARK: - The standard panels are restricted to .txt (verified on the real objects)

    @Test("The open panel is restricted to plain-text .txt and is never shown by this suite")
    @MainActor
    func openPanelIsRestrictedToPlainText() async {
        let panel = await PermissionPanelFixture.panels().firstOpen

        #expect(PermissionCoordinator.allowedFileExtension == "txt")
        #expect(panel.allowedContentTypes.count == 1, "One content type only: plain text")
        #expect(panel.allowedContentTypes.first?.identifier == UTType.plainText.identifier,
                "The open panel must target the plain-text type")
        #expect(panel.allowedContentTypes == [.plainText])
        #expect(panel.allowedContentTypes.first?.preferredFilenameExtension == PermissionCoordinator.allowedFileExtension,
                "Plain text maps to the .txt extension, so only .txt notes are selectable")
        #expect(UTType(filenameExtension: PermissionCoordinator.allowedFileExtension)?.conforms(to: .plainText) == true)
        #expect(panel.allowsMultipleSelection == false, "One note at a time")
        #expect(panel.canChooseFiles == true)
        #expect(panel.canChooseDirectories == false, "A folder is not a note location")
        #expect(panel.canCreateDirectories == false)
        #expect(panel.isVisible == false, "Configuring the panel must not present any UI")
    }

    @Test("The save panel is restricted to .txt and carries the suggested name")
    @MainActor
    func savePanelCarriesTheSuggestedName() async {
        let panel = await PermissionPanelFixture.panels().save

        #expect(panel.allowedContentTypes == [.plainText])
        #expect(panel.allowedContentTypes.first?.identifier == UTType.plainText.identifier)
        #expect(panel.allowedContentTypes.first?.preferredFilenameExtension == PermissionCoordinator.allowedFileExtension)
        #expect(panel.nameFieldStringValue == "Draft.txt", "The suggested name is carried verbatim")
        #expect(panel.allowsOtherFileTypes == false, "A typed extension must not widen the .txt restriction")
        #expect(panel.isExtensionHidden == false)
        #expect(panel.isVisible == false, "Configuring the panel must not present any UI")
    }

    @Test("Each call builds a fresh, equally restricted panel instead of reusing one")
    @MainActor
    func eachCallBuildsAFreshPanel() async {
        let panels = await PermissionPanelFixture.panels()

        #expect(panels.firstOpen !== panels.secondOpen,
                "A reused panel could carry the previous selection")
        #expect(panels.secondOpen.allowedContentTypes == panels.firstOpen.allowedContentTypes)
        #expect(panels.secondOpen.allowedContentTypes == [.plainText],
                "Every panel is restricted, not just the first")
        #expect(panels.secondOpen.isVisible == false)
        #expect(panels.save.isVisible == false)
    }

    // MARK: - The denied path (the user closes the panel)

    @Test("A cancelled open panel returns nil and leaves the state unchanged")
    @MainActor
    func cancelledOpenPanelLeavesStateUnchanged() async {
        let presenter = PermissionFakePanelPresenter()
        let coordinator = PermissionCoordinator(presenter: presenter)

        #expect(coordinator.activeScopeCount == 0)
        #expect(coordinator.lastSelection == nil)
        #expect(coordinator.selectionState == .idle)

        let selection = await coordinator.chooseExistingNote()

        #expect(selection == nil, "A cancelled panel authorises no location")
        #expect(coordinator.selectionState == .cancelled, "Denied is reported as cancelled")
        #expect(coordinator.activeScopeCount == 0, "A denial must not begin an access scope")
        #expect(coordinator.lastSelection == nil)
        #expect(presenter.recordedOpenCallCount == 1)
        coordinator.releaseAllScopes()
        #expect(coordinator.activeScopeCount == 0)
    }

    @Test("A cancelled save panel returns nil and leaves the state unchanged")
    @MainActor
    func cancelledSavePanelLeavesStateUnchanged() async {
        let presenter = PermissionFakePanelPresenter()
        let coordinator = PermissionCoordinator(presenter: presenter)

        let selection = await coordinator.chooseNewNoteDestination(suggestedName: "Untitled.txt")

        #expect(selection == nil)
        #expect(coordinator.selectionState == .cancelled)
        #expect(coordinator.activeScopeCount == 0)
        #expect(coordinator.lastSelection == nil)
        #expect(presenter.recordedSaveCallCount == 1)
        #expect(presenter.recordedSuggestedNames == ["Untitled.txt"],
                "The suggested name reaches the panel seam even when the user cancels")
    }

    @Test("After a denied attempt another explicit selection still succeeds")
    @MainActor
    func anotherExplicitSelectionFollowsADenial() async throws {
        let note = try permissionTestMakeNote()
        defer { permissionTestRemove(note.directory) }

        let presenter = PermissionFakePanelPresenter(openAnswers: [nil, note.file])
        let coordinator = PermissionCoordinator(presenter: presenter)

        let denied = await coordinator.chooseExistingNote()
        #expect(denied == nil)
        #expect(coordinator.selectionState == .cancelled)
        #expect(coordinator.activeScopeCount == 0)

        let accepted = await coordinator.chooseExistingNote()

        #expect(accepted == note.file, "Authorisation is rechecked only after an explicit user action")
        #expect(coordinator.selectionState == .succeeded)
        #expect(coordinator.lastSelection == note.file)
        #expect(coordinator.activeScopeCount == 1, "The user-selected note is held under one scope")
        #expect(presenter.recordedOpenCallCount == 2)

        coordinator.releaseAllScopes()
        #expect(coordinator.activeScopeCount == 0)
    }

    @Test("A denial preserves the last valid selection and its scope")
    @MainActor
    func aDenialPreservesTheLastValidSelection() async throws {
        let note = try permissionTestMakeNote(named: "kept.txt")
        defer { permissionTestRemove(note.directory) }

        let presenter = PermissionFakePanelPresenter(openAnswers: [note.file, nil])
        let coordinator = PermissionCoordinator(presenter: presenter)

        let first = await coordinator.chooseExistingNote()
        #expect(first == note.file)
        #expect(coordinator.lastSelection == note.file)
        #expect(coordinator.activeScopeCount == 1)

        let second = await coordinator.chooseExistingNote()

        #expect(second == nil)
        #expect(coordinator.selectionState == .cancelled)
        #expect(coordinator.lastSelection == note.file, "The last valid selection is preserved")
        #expect(coordinator.activeScopeCount == 1, "The scope of the open note is not released by a denial")

        coordinator.releaseAllScopes()
        #expect(coordinator.activeScopeCount == 0)
    }

    // MARK: - The .txt restriction is enforced on whatever a presenter returns

    @Test("An open selection outside .txt is refused and leaks no scope")
    @MainActor
    func openSelectionOutsideTxtIsRefused() async throws {
        let note = try permissionTestMakeNote(named: "essay.md")
        defer { permissionTestRemove(note.directory) }

        let presenter = PermissionFakePanelPresenter(openAnswers: [note.file])
        let coordinator = PermissionCoordinator(presenter: presenter)

        let selection = await coordinator.chooseExistingNote()

        #expect(selection == nil, "Only .txt note locations may be reached")
        #expect(coordinator.selectionState == .failed)
        #expect(coordinator.lastSelection == nil)
        #expect(coordinator.activeScopeCount == 0, "A refused location takes no scope")
    }

    @Test("A save destination is adopted exactly as the panel returned it")
    @MainActor
    func saveDestinationIsAdoptedExactly() async throws {
        let note = try permissionTestMakeNote(named: "anchor.txt")
        defer { permissionTestRemove(note.directory) }

        let destination = note.directory.appendingPathComponent("Saved.txt")
        let presenter = PermissionFakePanelPresenter(saveAnswers: [destination])
        let coordinator = PermissionCoordinator(presenter: presenter)

        let selection = await coordinator.chooseNewNoteDestination(suggestedName: "Saved.txt")

        #expect(selection == destination, "The chosen path is used exactly, with no rewriting")
        #expect(coordinator.selectionState == .succeeded)
        #expect(coordinator.lastSelection == destination)
        #expect(presenter.recordedSuggestedNames == ["Saved.txt"])
        #expect(coordinator.activeScopeCount == 0,
                "A destination that does not exist yet has no location to hold open, so nothing leaks")
        coordinator.releaseAllScopes()
    }

    @Test("A save destination outside .txt is refused and leaves the state unchanged")
    @MainActor
    func saveDestinationOutsideTxtIsRefused() async throws {
        let note = try permissionTestMakeNote(named: "anchor.txt")
        defer { permissionTestRemove(note.directory) }

        let presenter = PermissionFakePanelPresenter(saveAnswers: [note.directory.appendingPathComponent("Saved.md")])
        let coordinator = PermissionCoordinator(presenter: presenter)

        let selection = await coordinator.chooseNewNoteDestination(suggestedName: "Saved.md")

        #expect(selection == nil)
        #expect(coordinator.selectionState == .failed)
        #expect(coordinator.lastSelection == nil)
        #expect(coordinator.activeScopeCount == 0)
    }

    @Test("A selected location without a security-scoped bookmark is adopted without a scope")
    @MainActor
    func selectionWithoutBookmarkLeaksNoScope() async throws {
        let note = try permissionTestMakeNote(named: "anchor.txt")
        defer { permissionTestRemove(note.directory) }

        let absent = note.directory.appendingPathComponent("not-created.txt")
        let presenter = PermissionFakePanelPresenter(openAnswers: [absent])
        let coordinator = PermissionCoordinator(presenter: presenter)

        let selection = await coordinator.chooseExistingNote()

        #expect(selection == absent, "The panel's selection is the authority for the path")
        #expect(coordinator.selectionState == .succeeded)
        #expect(coordinator.activeScopeCount == 0, "No bookmark means no scope, so nothing can leak")
        coordinator.releaseAllScopes()
        #expect(coordinator.activeScopeCount == 0)
    }

    // MARK: - Scope accounting

    @Test("beginAccess and endAccess balance the scope count for a real note")
    @MainActor
    func beginAndEndAccessBalance() async throws {
        let note = try permissionTestMakeNote()
        defer { permissionTestRemove(note.directory) }

        let coordinator = PermissionCoordinator(presenter: PermissionFakePanelPresenter())
        #expect(coordinator.activeScopeCount == 0)

        #expect(coordinator.beginAccess(to: note.file) == true)
        #expect(coordinator.activeScopeCount == 1)

        #expect(coordinator.beginAccess(to: note.file) == true, "Reopening the same location still holds access")
        #expect(coordinator.activeScopeCount == 1, "Beginning twice must not add a second scope")

        coordinator.endAccess(to: note.file)
        #expect(coordinator.activeScopeCount == 0)

        coordinator.endAccess(to: note.file)
        #expect(coordinator.activeScopeCount == 0, "Releasing twice never underflows the count")

        #expect(coordinator.beginAccess(to: note.file) == true, "A released location can be reopened")
        #expect(coordinator.activeScopeCount == 1)
        coordinator.releaseAllScopes()
        #expect(coordinator.activeScopeCount == 0)
    }

    @Test("Equivalent spellings of one location release the same scope")
    @MainActor
    func equivalentSpellingsReleaseTheSameScope() async throws {
        let note = try permissionTestMakeNote()
        defer { permissionTestRemove(note.directory) }

        let spelledDifferently = URL(fileURLWithPath: note.directory.path + "/./note.txt")
        let coordinator = PermissionCoordinator(presenter: PermissionFakePanelPresenter())

        #expect(coordinator.beginAccess(to: note.file) == true)
        #expect(coordinator.activeScopeCount == 1)

        #expect(coordinator.beginAccess(to: spelledDifferently) == true)
        #expect(coordinator.activeScopeCount == 1, "The same location must not be scoped twice")

        coordinator.endAccess(to: spelledDifferently)
        #expect(coordinator.activeScopeCount == 0, "Either spelling releases the one scope")
    }

    @Test("A URL with no security-scoped bookmark does not leak a scope on failure")
    @MainActor
    func missingBookmarkLeaksNoScope() async throws {
        let note = try permissionTestMakeNote()
        defer { permissionTestRemove(note.directory) }

        let absent = note.directory.appendingPathComponent("gone.txt")
        let coordinator = PermissionCoordinator(presenter: PermissionFakePanelPresenter())

        // The proof is measured, not assumed: a real note is bookmarkable, an absent
        // location is not.
        #expect(PermissionCoordinator.securityScopedBookmarkData(for: note.file) != nil)
        #expect(PermissionCoordinator.securityScopedBookmarkData(for: absent) == nil)

        #expect(coordinator.beginAccess(to: absent) == false, "A location the app cannot prove is refused")
        #expect(coordinator.activeScopeCount == 0, "A refused location must not leak a scope")

        #expect(coordinator.beginAccess(to: note.file) == true, "A later valid location still opens")
        #expect(coordinator.activeScopeCount == 1)

        coordinator.endAccess(to: absent)
        #expect(coordinator.activeScopeCount == 1, "Releasing a location that was never opened changes nothing")

        coordinator.releaseAllScopes()
        #expect(coordinator.activeScopeCount == 0)
    }

    @Test("releaseAllScopes releases every scope and is safe and idempotent")
    @MainActor
    func releaseAllScopesIsSafeAndIdempotent() async throws {
        let first = try permissionTestMakeNote(named: "first.txt")
        defer { permissionTestRemove(first.directory) }
        let second = try permissionTestMakeNote(named: "second.txt")
        defer { permissionTestRemove(second.directory) }

        let coordinator = PermissionCoordinator(presenter: PermissionFakePanelPresenter())
        #expect(coordinator.beginAccess(to: first.file) == true)
        #expect(coordinator.beginAccess(to: second.file) == true)
        #expect(coordinator.activeScopeCount == 2)

        coordinator.releaseAllScopes()
        #expect(coordinator.activeScopeCount == 0, "Every access scope is released")

        coordinator.releaseAllScopes()
        #expect(coordinator.activeScopeCount == 0, "Repeating the release is safe")

        coordinator.endAccess(to: first.file)
        #expect(coordinator.activeScopeCount == 0, "A released scope cannot be released again")

        coordinator.releaseAllScopes()
        #expect(coordinator.activeScopeCount == 0)
    }

    @Test("A fresh coordinator holds no scope and every release path is safe")
    @MainActor
    func freshCoordinatorReleasesSafely() {
        let fake = PermissionFakePanelPresenter()
        let coordinator = PermissionCoordinator(presenter: fake)

        #expect(coordinator.activeScopeCount == 0)
        #expect(coordinator.selectionState == .idle)
        #expect(coordinator.lastSelection == nil)

        coordinator.endAccess(to: URL(fileURLWithPath: "/tmp/mn-permission-never-opened.txt"))
        #expect(coordinator.activeScopeCount == 0)

        coordinator.releaseAllScopes()
        coordinator.releaseAllScopes()
        #expect(coordinator.activeScopeCount == 0)

        // The composition-root default (the AppKit bridge) is a real `PanelPresenting`
        // and starts just as idle, without presenting anything.
        let _: any PanelPresenting = NativePanelPresenter()
        let defaultCoordinator = PermissionCoordinator()
        #expect(defaultCoordinator.activeScopeCount == 0)
        #expect(defaultCoordinator.selectionState == .idle)
        #expect(defaultCoordinator.lastSelection == nil)
    }
}
