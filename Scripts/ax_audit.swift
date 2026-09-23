#!/usr/bin/env swift
//
// Scripts/ax_audit.swift — audits the accessibility tree of the running app the
// way VoiceOver sees it, through the system accessibility API.
//
//   swift Scripts/ax_audit.swift ["/Applications/Monospace Notes.app"]
//
// Launches the bundle's executable, then checks:
//   * the document window exposes a labelled text area, the status bar and the
//     empty-document hint;
//   * Cmd+F presents the search palette with its labelled field, Escape dismisses it;
//   * Cmd+, opens Settings with every control present by identifier;
//   * every interactive element on screen carries a spoken label.
// The terminal running it needs Accessibility permission (System Settings >
// Privacy & Security > Accessibility). Exits non-zero on the first failed gate.
//
import AppKit
import ApplicationServices

let bundlePath = CommandLine.arguments.dropFirst().first ?? "/Applications/Monospace Notes.app"
let executable = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/MacOS/MonospaceNotes")

guard AXIsProcessTrusted() else {
    print("AX AUDIT FAILED: this process is not trusted for accessibility")
    exit(2)
}

var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    print(condition ? "  ok    \(message)" : "  FAIL  \(message)")
    if !condition { failures.append(message) }
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    (attribute(element, name) as? String).flatMap { $0.isEmpty ? nil : $0 }
}

struct Node {
    let role: String
    let subrole: String?
    let identifier: String?
    let label: String?
}

/// The title-bar buttons belong to AppKit, not to the app; a stepper's arrows and a
/// scroller's page areas are parts of a control VoiceOver speaks as one element.
let windowControlSubroles: Set<String> = [
    "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton",
    "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage",
]

func walk(_ element: AXUIElement, depth: Int = 0, into nodes: inout [Node]) {
    guard depth < 60 else { return }
    let role = string(element, kAXRoleAttribute) ?? "?"
    let label = string(element, kAXDescriptionAttribute)
        ?? string(element, kAXTitleAttribute)
        ?? (role == "AXStaticText" ? string(element, kAXValueAttribute) : nil)
    nodes.append(Node(
        role: role,
        subrole: string(element, kAXSubroleAttribute),
        identifier: string(element, "AXIdentifier"),
        label: label ?? string(element, kAXHelpAttribute)
    ))
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
        walk(child, depth: depth + 1, into: &nodes)
    }
}

func windows(of app: AXUIElement) -> [AXUIElement] {
    (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

func tree(of app: AXUIElement) -> [Node] {
    var nodes: [Node] = []
    for window in windows(of: app) { walk(window, into: &nodes) }
    return nodes
}

func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(50_000)
    }
    return condition()
}

func press(_ keyCode: CGKeyCode, command: Bool, pid: pid_t) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
        if command { event?.flags = .maskCommand }
        event?.postToPid(pid)
        usleep(30_000)
    }
}

let interactiveRoles: Set<String> = [
    "AXButton", "AXTextField", "AXTextArea", "AXPopUpButton", "AXIncrementor", "AXCheckBox", "AXMenuButton",
]

func auditLabels(_ nodes: [Node], _ context: String) {
    let unlabelled = nodes.filter {
        interactiveRoles.contains($0.role)
            && !windowControlSubroles.contains($0.subrole ?? "")
            && $0.label == nil
    }
    let described = unlabelled.map { "\($0.role)/\($0.subrole ?? "-")/\($0.identifier ?? "-")" }
    check(unlabelled.isEmpty, "\(context): every interactive element has a spoken label \(described)")
}

// Launch.
let process = Process()
process.executableURL = executable
process.standardOutput = FileHandle.nullDevice
process.standardError = FileHandle.nullDevice
do { try process.run() } catch {
    print("AX AUDIT FAILED: cannot launch \(executable.path): \(error)")
    exit(2)
}
let pid = process.processIdentifier
let app = AXUIElementCreateApplication(pid)
NSRunningApplication(processIdentifier: pid)?.activate()

print("Document window")
check(waitFor(5) { !windows(of: app).isEmpty }, "a window appears")
usleep(400_000)
var nodes = tree(of: app)
check(nodes.contains { $0.role == "AXTextArea" && $0.label == "Note text" }, "the document is a text area labelled \"Note text\"")
check(nodes.contains { $0.identifier == "window.statusBar" }, "the status bar is exposed")
check(nodes.contains { ($0.label ?? "").contains("Untitled") && ($0.label ?? "").contains("Not saved") },
      "the status bar speaks the note name and save state")
check(nodes.contains { $0.identifier == "document.emptyHint" }, "the empty-document hint is exposed")
auditLabels(nodes, "document window")

print("Search palette")
press(3, command: true, pid: pid) // Cmd+F
check(waitFor(3) { tree(of: app).contains { $0.identifier == "search.field" } }, "Cmd+F presents the labelled search field")
nodes = tree(of: app)
check(nodes.contains { $0.identifier == "search.field" && $0.label == "Search Notes" }, "the search field is labelled \"Search Notes\"")
check(nodes.contains { $0.identifier == "search.emptyState" }, "with no note open the palette says why it has nothing to search")
auditLabels(nodes, "search palette")
press(53, command: false, pid: pid) // Escape
check(waitFor(3) { !tree(of: app).contains { $0.identifier == "search.field" } }, "Escape dismisses the palette")

print("Settings window")
press(43, command: true, pid: pid) // Cmd+,
let settingsIdentifiers = [
    "settings.fontFamily", "settings.pointSize",
    "settings.keyBinding.open", "settings.keyBinding.save", "settings.keyBinding.saveAs",
    "settings.keyBinding.search", "settings.keyBinding.settings",
]
check(waitFor(4) { windows(of: app).count >= 2 }, "Cmd+, opens the Settings window")
usleep(400_000)
nodes = tree(of: app)
for identifier in settingsIdentifiers {
    check(nodes.contains { $0.identifier == identifier }, "Settings exposes \(identifier)")
}
auditLabels(nodes, "Settings window")

process.terminate()
process.waitUntilExit()
print(failures.isEmpty ? "\nAX AUDIT PASSED" : "\nAX AUDIT FAILED (\(failures.count))")
exit(failures.isEmpty ? 0 : 1)
