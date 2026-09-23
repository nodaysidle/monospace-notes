//
//  WindowChrome.swift
//  MonospaceNotes
//
//  The document window's chrome around the document surface: the status bar, the
//  empty-document hint, and the frame the search palette is presented in. Every
//  colour is a shade of the locked contrast-checked foreground on #000000.
//

import SwiftUI

/// Shades of the document foreground used by the window chrome.
@MainActor
enum ChromeStyle {
    static let foreground = Color(
        nsColor: DarkMonochromaticWindowAppearanceFeature.foregroundColor(preferred: .white).nsColor
    )
    static let secondary = foreground.opacity(0.62)
    static let hairline = foreground.opacity(0.12)
    static let failure = Color(red: 1.0, green: 0.55, blue: 0.55)
}

// MARK: - Status bar

/// The bar along the bottom of the window: the note, its folder and save state on the
/// left, the latest status message in the middle, and the buffer's size and typography
/// on the right.
struct StatusBar: View {
    let state: AppState

    static let identifier = "window.statusBar"

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.hasUnsavedChanges ? ChromeStyle.foreground : Color.clear)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(state.documentDisplayName)
                    .foregroundStyle(ChromeStyle.foreground.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let folder = state.workspaceDisplayName {
                    Text("in \(folder)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("·")
                Text(state.saveStateDescription)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(documentSummary))

            Spacer(minLength: 12)

            if let status = state.statusMessage {
                Label {
                    Text(status.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } icon: {
                    Image(systemName: status.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle")
                }
                .foregroundStyle(status.isFailure ? ChromeStyle.failure : ChromeStyle.secondary)
                .help(status.text)
                .accessibilityLabel(Text(status.text))
                .transition(.opacity)

                Spacer(minLength: 12)
            }

            Text("\(state.wordCount) \(state.wordCount == 1 ? "word" : "words") · \(state.characterCount) chars")
                .monospacedDigit()
            Text("\(state.typography.fontFamily) \(Int(state.typography.pointSize.rounded()))")
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(ChromeStyle.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color.black)
        .overlay(alignment: .top) {
            Rectangle().fill(ChromeStyle.hairline).frame(height: 1)
        }
        .animation(.easeOut(duration: 0.15), value: state.statusMessage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.identifier)
    }

    private var documentSummary: String {
        var parts = [state.documentDisplayName]
        if let folder = state.workspaceDisplayName { parts.append("in \(folder)") }
        parts.append(state.saveStateDescription)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Empty document hint

/// Shown over an empty, untitled document: what the window is for and the shortcuts
/// that get a note open. It never takes clicks or focus, so typing starts a note.
struct EmptyDocumentHint: View {
    let keybindings: KeybindingSettings

    static let identifier = "document.emptyHint"
    static let headline = "Start typing, or open a note."

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(LockedIdentity.bundleName)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ChromeStyle.foreground.opacity(0.85))
                Text(Self.headline)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(ChromeStyle.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                shortcutRow(keybindings.open, "Open a note")
                shortcutRow(keybindings.search, "Search the note's folder")
                shortcutRow(keybindings.save, "Save")
                shortcutRow(keybindings.settings, "Settings")
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .padding(28)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(Self.identifier)
    }

    private func shortcutRow(_ binding: KeyBinding, _ action: String) -> some View {
        GridRow {
            Text(binding.displayString)
                .foregroundStyle(ChromeStyle.foreground.opacity(0.8))
                .gridColumnAlignment(.trailing)
            Text(action)
                .foregroundStyle(ChromeStyle.secondary)
        }
    }
}

// MARK: - Search palette frame

/// The floating frame the search surface is presented in, anchored under the title bar.
struct SearchPaletteFrame<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(width: 580)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(ChromeStyle.foreground.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
            .padding(.top, 56)
    }
}
