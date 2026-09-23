//
//  MonospaceNotesApp.swift
//  MonospaceNotes
//
//  TASK-01-FOUNDATION — owner OWN-FOUNDATION.
//
//  The `@main` App scene entry, locked once and never edited again.
//
//  This file references only `AppState`, `ErrorAlert`, `StatusMessage`, the
//  three `AnyView` factories on `AppState`, and `LockedIdentity`. Every feature
//  surface arrives behind those factories, so no later task needs to touch it.
//
//  Structure:
//    * `WindowGroup`  — Dock-first application entry (CON-LIFECYCLE-PRESET).
//    * `Settings`     — Settings window opened from the macOS menu bar.
//    * `AppCommands`  — menu commands wired to the command surface and to the
//                       user's keybindings.
//    * `RootView`     — #000000 root view with the document surface, the
//                       non-modal status area, the search surface, and the one
//                       modal error-alert presentation.
//

import AppKit
import SwiftUI

@main
struct MonospaceNotesApp: App {
    @State private var state = AppState()

    init() {
        // The window chrome is dark whatever the system appearance, set before any
        // window exists so the first frame is already drawn dark.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        WindowGroup {
            RootView(state: state)
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            AppCommands(state: state)
        }

        Settings {
            state.settingsSurface()
                .frame(minWidth: 480, idealWidth: 500, minHeight: 480, idealHeight: 500)
        }
    }
}

// MARK: - Root view

/// Dock-first root view: black background, the document surface, the non-modal
/// status area, the search surface, and the modal error alert.
struct RootView: View {
    let state: AppState

    var body: some View {
        ZStack(alignment: .top) {
            // Locked appearance: window background is #000000.
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    state.documentSurface()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if state.showsEmptyDocumentHint {
                        EmptyDocumentHint(keybindings: state.keybindings)
                            .transition(.opacity)
                    }
                }

                StatusBar(state: state)
            }

            if state.isSearchPresented {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { state.dismissSearch() }
                    .accessibilityHidden(true)
                    .transition(.opacity)

                SearchPaletteFrame {
                    state.searchSurface()
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.14), value: state.isSearchPresented)
        .animation(.easeOut(duration: 0.2), value: state.showsEmptyDocumentHint)
        .frame(minWidth: 520, minHeight: 320)
        .navigationTitle(state.windowTitle)
        .onChange(of: state.hasUnsavedChanges) { _, edited in
            NSApp.keyWindow?.isDocumentEdited = edited
        }
        .alert(
            state.errorAlert?.title ?? LockedIdentity.bundleName,
            isPresented: Binding(
                get: { state.errorAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        state.errorAlert = nil
                    }
                }
            ),
            presenting: state.errorAlert
        ) { _ in
            Button("OK", role: .cancel) {
                state.errorAlert = nil
            }
        } message: { alert in
            Text(alert.message)
        }
    }
}

// MARK: - Commands

/// Menu commands wired to `AppState`'s command surface. Shortcuts come from
/// `AppState.keybindings`, so a user's keybinding choices drive the menu.
struct AppCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                Task { await state.openDocument() }
            }
            .keyboardShortcut(shortcut(key: state.keybindings.open.key,
                                       command: state.keybindings.open.command,
                                       shift: state.keybindings.open.shift,
                                       option: state.keybindings.open.option,
                                       control: state.keybindings.open.control))
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                Task { await state.save() }
            }
            .keyboardShortcut(shortcut(key: state.keybindings.save.key,
                                       command: state.keybindings.save.command,
                                       shift: state.keybindings.save.shift,
                                       option: state.keybindings.save.option,
                                       control: state.keybindings.save.control))

            Button("Save As…") {
                Task { await state.saveAs() }
            }
            .keyboardShortcut(shortcut(key: state.keybindings.saveAs.key,
                                       command: state.keybindings.saveAs.command,
                                       shift: state.keybindings.saveAs.shift,
                                       option: state.keybindings.saveAs.option,
                                       control: state.keybindings.saveAs.control))
        }

        CommandGroup(after: .textEditing) {
            Button("Search Notes") {
                Task { await state.focusSearch() }
            }
            .keyboardShortcut(shortcut(key: state.keybindings.search.key,
                                       command: state.keybindings.search.command,
                                       shift: state.keybindings.search.shift,
                                       option: state.keybindings.search.option,
                                       control: state.keybindings.search.control))
        }

        CommandGroup(replacing: .appSettings) {
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(shortcut(key: state.keybindings.settings.key,
                                       command: state.keybindings.settings.command,
                                       shift: state.keybindings.settings.shift,
                                       option: state.keybindings.settings.option,
                                       control: state.keybindings.settings.control))
        }
    }

    /// Builds a menu shortcut from a locked keybinding's primitive fields.
    private func shortcut(key: String,
                          command: Bool,
                          shift: Bool,
                          option: Bool,
                          control: Bool) -> KeyboardShortcut {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }

        let character = key.first ?? "s"
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers)
    }
}
