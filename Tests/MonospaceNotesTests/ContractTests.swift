//
//  ContractTests.swift
//  MonospaceNotesTests
//
//  TASK-01-FOUNDATION focused test suite — owner OWN-FOUNDATION.
//
//  Fails on stack drift, identity drift, missing foundation or packet files,
//  and any forbidden technology token inside Sources/.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import Foundation
import SwiftUI
import Testing

@testable import MonospaceNotes

@Suite("Foundation contract")
struct ContractTests {

    /// Tests/MonospaceNotesTests/ContractTests.swift -> up three levels = package root.
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The complete OWN-FOUNDATION file list from TRD.md / TASKS.md.
    static let foundationFiles = [
        "Package.swift",
        "Sources/MonospaceNotes/MonospaceNotesApp.swift",
        "Sources/MonospaceNotes/AppState.swift",
        "Tests/MonospaceNotesTests/ContractTests.swift",
    ]

    /// The read-only contract packet. Never modified by any task.
    static let packetDocuments = ["PRD.md", "ARD.md", "TRD.md", "TASKS.md", "AGENTS.md"]

    /// Forbidden technologies from TRD.md "Forbidden Technologies", matched as
    /// whole words and case-insensitively.
    static let forbiddenTechnologyNames = ["iOS", "Catalyst", "Flutter", "Tauri", "Electron"]

    /// API markers that must never appear in Sources/.
    static let forbiddenAPITokens = [
        "URLSession",
        "NSURLConnection",
        "NSURLRequest",
        "CFNetwork",
        "import Network",
        "import UIKit",
        "import WebKit",
        "import XCTest",
    ]

    // MARK: - Helpers

    static func fileURL(_ relativePath: String) -> URL {
        packageRoot.appendingPathComponent(relativePath)
    }

    static func text(at relativePath: String) throws -> String {
        let data = try Data(contentsOf: fileURL(relativePath))
        return String(decoding: data, as: UTF8.self)
    }

    /// Every .swift file under Sources/, as (path, text) pairs.
    static func swiftSources() throws -> [(path: String, text: String)] {
        let sourcesRoot = packageRoot.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [(path: String, text: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let data = try Data(contentsOf: url)
            results.append((url.path, String(decoding: data, as: UTF8.self)))
        }
        return results
    }

    /// Records an `Issue` unless the operation throws `AppStateError.initializationFailed`.
    static func expectInitializationFailure(
        _ operation: () async throws -> Void,
        comment: Comment
    ) async {
        do {
            try await operation()
            Issue.record(comment)
        } catch let error as AppStateError {
            if case .initializationFailed = error {
                return
            }
            Issue.record("Expected .initializationFailed, received \(error)")
        } catch {
            Issue.record("Expected AppStateError, received \(error)")
        }
    }

    // MARK: - Foundation files

    @Test("Every foundation file exists at the exact declared path")
    func foundationFilesExist() {
        for relativePath in Self.foundationFiles {
            let url = Self.fileURL(relativePath)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "Missing foundation file at the locked path: \(relativePath)"
            )
        }
    }

    @Test("Package.swift keeps the locked package shape and stack")
    func packageShapeIsLocked() throws {
        let manifest = try Self.text(at: "Package.swift")

        #expect(manifest.contains("// swift-tools-version: 6.0"),
                "Package.swift must keep swift-tools-version 6.0 (Swift 6)")
        #expect(manifest.contains("name: \"MonospaceNotes\""))
        #expect(manifest.contains("platforms: [.macOS(.v14)]"),
                "The package platform must stay .macOS(.v14) for @Observable")
        #expect(manifest.contains(".executableTarget(name: \"MonospaceNotes\""),
                "MonospaceNotes must stay an executable target")
        #expect(manifest.contains(".testTarget(name: \"MonospaceNotesTests\""))
        #expect(manifest.contains("path: \"Sources/MonospaceNotes\""))
        #expect(manifest.contains("path: \"Tests/MonospaceNotesTests\""))
        #expect(!manifest.contains(".package("),
                "The locked stack forbids third-party package dependencies")
    }

    @Test("MonospaceNotesApp declares the @main App entry and delegates to AppState")
    func appEntryDelegatesToAppState() throws {
        let source = try Self.text(at: "Sources/MonospaceNotes/MonospaceNotesApp.swift")

        #expect(source.contains("@main"), "MonospaceNotesApp.swift must declare the @main entry")
        #expect(source.contains("struct MonospaceNotesApp: App"))
        #expect(source.contains("WindowGroup"), "The implementation marker is WindowGroup")
        #expect(source.contains("Settings {"), "A Settings scene is required")
        #expect(source.contains("AppCommands"))

        // All state and commands are delegated to AppState.
        #expect(source.contains("state.documentSurface()"))
        #expect(source.contains("state.searchSurface()"))
        #expect(source.contains("state.settingsSurface()"))
        #expect(source.contains("state.openDocument()"))
        #expect(source.contains("state.save()"))
        #expect(source.contains("state.saveAs()"))
        #expect(source.contains("state.focusSearch()"))

        // Black root view and the single modal error alert.
        #expect(source.contains("Color.black"))
        #expect(source.contains("state.errorAlert"))

        // Locked identity is the only other shared symbol this file may name.
        #expect(source.contains("LockedIdentity.bundleName"))
    }

    @Test("AppState.swift declares the locked shared surface exactly once")
    func appStateDeclaresSharedSurface() throws {
        let source = try Self.text(at: "Sources/MonospaceNotes/AppState.swift")

        let requiredDeclarations = [
            "enum OperationState",
            "struct ErrorAlert",
            "struct StatusMessage",
            "struct KeyBinding",
            "struct KeybindingSettings",
            "struct TypographySettings",
            "enum SearchMatchField",
            "struct SearchResult",
            "enum AppStateError",
            "enum LockedIdentity",
            "final class FileIOThreadRecorder",
            "protocol NoteFileAccess",
            "protocol PanelPresenting",
            "protocol SettingsStoring",
            "struct UnconfiguredNoteFileAccess",
            "struct UnconfiguredPanelPresenter",
            "struct UnconfiguredSettingsStore",
            "final class AppState",
        ]

        for declaration in requiredDeclarations {
            #expect(source.contains(declaration),
                    "AppState.swift must declare \(declaration)")
        }

        #expect(source.contains("@Observable"), "AppState is @Observable")
        #expect(source.contains("@MainActor"), "AppState is @MainActor")
    }

    // MARK: - Identity

    @Test("The locked identity is com.monospace.notes")
    func lockedIdentity() {
        #expect(LockedIdentity.bundleIdentifier == "com.monospace.notes")
        #expect(LockedIdentity.bundleName == "Monospace Notes")
        #expect(LockedIdentity.executableName == "MonospaceNotes")
        #expect(LockedIdentity.iconName == "AppIcon")
        #expect(LockedIdentity.artifactPath == "dist/Monospace Notes.app")
        #expect(LockedIdentity.shortVersion == "1.0.0")
        #expect(LockedIdentity.buildVersion == "1")
        #expect(LockedIdentity.minimumSystemVersion == "14.0")
    }

    // MARK: - Packet integrity and forbidden tokens

    @Test("The five packet documents are still present and non-empty")
    func packetDocumentsExist() throws {
        for name in Self.packetDocuments {
            let url = Self.fileURL(name)
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "Missing packet document: \(name)")
            let text = try Self.text(at: name)
            #expect(!text.isEmpty, "Packet document \(name) must not be empty")
        }
    }

    @Test("Sources contain no forbidden technology or network token")
    func sourcesContainNoForbiddenTokens() throws {
        let sources = try Self.swiftSources()
        #expect(sources.count >= 2,
                "Expected at least MonospaceNotesApp.swift and AppState.swift under Sources/")

        for (path, text) in sources {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for name in Self.forbiddenTechnologyNames {
                let regex = try NSRegularExpression(pattern: "\\b\(name)\\b", options: [.caseInsensitive])
                #expect(regex.numberOfMatches(in: text, range: range) == 0,
                        "\(path) references the forbidden technology \(name)")
            }
            for token in Self.forbiddenAPITokens {
                #expect(!text.contains(token),
                        "\(path) contains the forbidden token \(token)")
            }
        }
    }

    // MARK: - Shared value semantics

    @Test("Shared value semantics match the locked defaults")
    func lockedValueSemantics() {
        #expect(TypographySettings.default.fontFamily == "Menlo")
        #expect(TypographySettings.default.pointSize == 13)

        #expect(KeybindingSettings.default.open == KeyBinding.open)
        #expect(KeybindingSettings.default.save == KeyBinding.save)
        #expect(KeybindingSettings.default.saveAs == KeyBinding.saveAs)
        #expect(KeybindingSettings.default.search == KeyBinding.search)
        #expect(KeybindingSettings.default.settings == KeyBinding.settings)

        #expect(KeyBinding.open.displayString == "⌘O")
        #expect(KeyBinding.save.displayString == "⌘S")
        #expect(KeyBinding.saveAs.displayString == "⇧⌘S")
        #expect(KeyBinding.search.displayString == "⌘F")
        #expect(KeyBinding.settings.displayString == "⌘,")

        let firstAlert = ErrorAlert(title: "Could Not Open Note", message: "unconfigured")
        let secondAlert = ErrorAlert(title: "Could Not Open Note", message: "unconfigured")
        #expect(firstAlert.id != secondAlert.id, "Each alert needs a fresh identity")
        #expect(firstAlert != secondAlert)
        #expect(firstAlert == firstAlert)

        let status = StatusMessage(text: "Background save failed", isFailure: true)
        #expect(status.isFailure)
        #expect(status.id != StatusMessage(text: "Background save failed", isFailure: true).id)

        #expect(SearchMatchField.fileName.rawValue == "fileName")
        #expect(SearchMatchField.contents.rawValue == "contents")

        let noteURL = URL(fileURLWithPath: "/tmp/notes/example.txt")
        let result = SearchResult(url: noteURL, score: 7, matchedField: .fileName)
        #expect(result.id == noteURL)
        #expect(result.displayName == "example.txt")

        #expect(!AppStateError.initializationFailed("no store").description.isEmpty)
        #expect(!AppStateError.documentUnavailable("no document").description.isEmpty)
        #expect(!AppStateError.unsupportedCharacter("x").description.isEmpty)
    }

    @Test("FileIOThreadRecorder counts operations and main-thread violations")
    func threadRecorderCounts() {
        let recorder = FileIOThreadRecorder()
        #expect(recorder.totalOperations == 0)
        #expect(recorder.mainThreadViolations == 0)

        recorder.record(isMainThread: false)
        recorder.record(isMainThread: false)
        recorder.record(isMainThread: true)

        #expect(recorder.totalOperations == 3)
        #expect(recorder.mainThreadViolations == 1)

        recorder.reset()
        #expect(recorder.totalOperations == 0)
        #expect(recorder.mainThreadViolations == 0)
    }

    // MARK: - Placeholders and the AppState surface

    @Test("Neutral placeholders stay honest")
    func unconfiguredPlaceholders() async {
        let noteFiles = UnconfiguredNoteFileAccess()
        let noteURL = URL(fileURLWithPath: "/tmp/notes/example.txt")

        await Self.expectInitializationFailure(
            { _ = try await noteFiles.readUTF8(from: noteURL) },
            comment: "UnconfiguredNoteFileAccess.readUTF8 must throw .initializationFailed"
        )
        await Self.expectInitializationFailure(
            { try await noteFiles.writeAtomically("text", to: noteURL) },
            comment: "UnconfiguredNoteFileAccess.writeAtomically must throw .initializationFailed"
        )

        let panels = UnconfiguredPanelPresenter()
        let existing = await panels.chooseExistingNote()
        let destination = await panels.chooseNewNoteDestination(suggestedName: "note.txt")
        #expect(existing == nil, "An unconfigured open panel must report a cancel")
        #expect(destination == nil, "An unconfigured save panel must report a cancel")

        let store = UnconfiguredSettingsStore()
        #expect(store.loadTypography() == TypographySettings.default)
        #expect(store.loadKeybindings() == KeybindingSettings.default)
        try? store.storeTypography(TypographySettings(fontFamily: "Menlo", pointSize: 16))
        try? store.storeKeybindings(KeybindingSettings.default)
        #expect(store.loadTypography() == TypographySettings.default,
                "An unconfigured store must never claim a persisted value")
    }

    @Test("AppState keeps the locked surface")
    @MainActor
    func appStateLockedSurface() async {
        let state = AppState(
            noteFiles: UnconfiguredNoteFileAccess(),
            panels: UnconfiguredPanelPresenter(),
            settings: UnconfiguredSettingsStore(),
            ioRecorder: FileIOThreadRecorder()
        )

        // Injected services (composition root).
        let _: any NoteFileAccess = state.noteFiles
        let _: any PanelPresenting = state.panels
        let _: any SettingsStoring = state.settings
        let _: FileIOThreadRecorder = state.ioRecorder

        // Document presentation starts empty with no path.
        #expect(state.documentText.isEmpty)
        #expect(state.documentURL == nil)
        #expect(state.workspaceFolder == nil)
        #expect(state.hasUnsavedChanges == false)
        #expect(state.windowTitle == LockedIdentity.bundleName)

        // Typography / keybindings come from the injected store.
        #expect(state.typography == TypographySettings.default)
        #expect(state.keybindings == KeybindingSettings.default)
        let _: String? = state.settingsMessage

        // Search presentation starts empty.
        #expect(state.searchQuery.isEmpty)
        #expect(state.searchResults.isEmpty)
        let _: String? = state.searchEmptyStateText

        // Operation states and reporting surfaces exist with the locked types.
        let _: OperationState = state.launchState
        let _: OperationState = state.openState
        let _: OperationState = state.saveState
        let _: OperationState = state.backgroundSaveState
        let _: OperationState = state.searchState
        let _: Bool = state.isEditable
        let _: ErrorAlert? = state.errorAlert
        let _: StatusMessage? = state.statusMessage

        // Command surface signatures stay locked.
        await state.openDocument()
        await state.save()
        await state.saveAs()
        await state.focusSearch()
        await state.updateSearchQuery("note")
        await state.selectSearchResult(
            SearchResult(url: URL(fileURLWithPath: "/tmp/notes/example.txt"), score: 1, matchedField: .fileName)
        )
        await state.setTypography(TypographySettings.default)
        await state.setKeybindings(KeybindingSettings.default)
        let _: Bool = state.handleKeystrokeInsert("a")

        // View factories keep returning a surface.
        let _: AnyView = state.documentSurface()
        let _: AnyView = state.searchSurface()
        let _: AnyView = state.settingsSurface()
    }
}
