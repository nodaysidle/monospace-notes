//
//  WindowChromeTests.swift
//  MonospaceNotesTests
//
//  The document window's chrome: the search palette's presentation, the status bar's
//  derived values, the empty-document hint, and what each exposes to accessibility
//  when hosted the way the app hosts it.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import AppKit
import SwiftUI
import Testing

@testable import MonospaceNotes

@MainActor
private func chromeFindTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
        if let found = chromeFindTextView(in: subview) { return found }
    }
    return nil
}

@MainActor
private func chromeHost<V: View>(_ view: V, size: NSSize = NSSize(width: 900, height: 600)) -> (NSWindow, NSHostingView<V>) {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    return (window, host)
}

@Suite("Window chrome: search palette, status bar and empty-document hint")
@MainActor
struct WindowChromeTests {

    @Test("Cmd+F presents the search palette and dismissing it hides it again")
    func searchPalettePresentsAndDismisses() async {
        let state = AppState()
        #expect(state.isSearchPresented == false, "the palette is not on screen at launch")

        await state.focusSearch()
        #expect(state.isSearchPresented)

        state.dismissSearch()
        #expect(state.isSearchPresented == false)
    }

    @Test("The status bar values follow the buffer and the save state")
    func statusBarValuesFollowTheBuffer() {
        let state = AppState()
        #expect(state.documentDisplayName == "Untitled")
        #expect(state.workspaceDisplayName == nil)
        #expect(state.saveStateDescription == "Not saved")
        #expect(state.wordCount == 0)
        #expect(state.characterCount == 0)
        #expect(state.showsEmptyDocumentHint, "an empty untitled window shows the hint")

        let textView = TextKit2DocumentView.makeDocumentTextView(
            text: "two  words\nand three ☕️",
            font: state.documentFont,
            textColor: .white,
            backgroundColor: .black,
            isEditable: true
        )
        state.handleDirectEdit(in: textView)

        #expect(state.wordCount == 5)
        #expect(state.characterCount == "two  words\nand three ☕️".count)
        #expect(state.hasUnsavedChanges)
        #expect(state.saveStateDescription == "Edited")
        #expect(state.showsEmptyDocumentHint == false, "the hint gives way to the first edit")
    }

    // SwiftUI publishes its accessibility tree only to a connected assistive client, so
    // the SwiftUI elements of the chrome are audited against the running app by
    // Scripts/ax_audit.swift; this suite asserts what AppKit exposes in-process.
    @Test("The hosted window's document is a labelled, editable, scrollable text area")
    func hostedDocumentIsAccessible() throws {
        _ = NSApplication.shared
        let state = AppState()
        let (window, host) = chromeHost(RootView(state: state))
        defer { window.close() }

        let textView = try #require(chromeFindTextView(in: host), "the window built no text view")
        #expect(textView.accessibilityRole() == .textArea)
        #expect(textView.accessibilityLabel() == TextKit2DocumentView.defaultAccessibilityLabel)
        #expect(textView.isEditable)
        #expect(textView.enclosingScrollView?.hasVerticalScroller == true)
    }
}
