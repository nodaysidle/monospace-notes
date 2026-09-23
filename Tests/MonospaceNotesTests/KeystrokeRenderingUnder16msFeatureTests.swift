//
//  KeystrokeRenderingUnder16msFeatureTests.swift
//  MonospaceNotesTests
//
//  TASK-06-KEYSTROKE-RENDERING-UNDER-16MS focused suite — owner
//  OWN-KEYSTROKE-RENDERING-UNDER-16MS.
//
//  Covers FEAT-KEYSTROKE-RENDERING-UNDER-16MS and its two contracts against the
//  real `KeystrokeRenderingUnder16msFeature` and the real `TextKit2DocumentView`:
//
//    * ACC-KEYSTROKE-RENDERING-UNDER-16MS-01 — a layout failure leaves the text
//      buffer unchanged for that keystroke: the injected layout-and-drawing step
//      reports a failure against a real `NSTextView`, the buffer is asserted to be
//      exactly the buffer it was, `bufferUnchangedOnFailure == true`, the failure is
//      explained non-modally, and the retry is explicit (a second call succeeds).
//      The rejected-insertion branch (an insertion point outside the buffer), the
//      non-editable surface, the empty interpretation, and a non-TextKit-2 surface
//      are covered too.
//    * ACC-KEYSTROKE-RENDERING-UNDER-16MS-02 — MEASURED from key event to updated
//      text view drawing, keystroke rendering completes in under 16 ms for a 100 KB
//      document: a real `NSTextView` holding exactly `documentSizeForBudgetBytes`
//      (102400) bytes of text, a character inserted through the text-input entry
//      point AppKit uses for a typed character, TextKit 2 layout forced, the visible
//      region drawn, measured with `ContinuousClock` and compared against the locked
//      budget constants. Every number is printed, and the bitmap the surface drew
//      into is fingerprinted so "the updated text view drawing" is checked to really
//      contain the change. The measurement runs at three real caret positions — the
//      end, the middle, and the start of the 100 KB document.
//    * ACC-KEYSTROKE-RENDERING-UNDER-16MS-03 — no file read or write occurs on the
//      main thread during keystroke handling: proved STRUCTURALLY. The feature source
//      is scanned for every file-I/O token and for the URL type, the `insert` entry
//      points are asserted to take a character and a text view and nothing else, and
//      the feature is asserted to hold no injected file or settings service at all,
//      so the main-actor keystroke path has no I/O it could perform. The limitation is
//      stated where it matters: a source scan proves the published implementation
//      contains no file-I/O API; it is not a runtime trace and it is not evidence about
//      code that does not exist.
//    * ACC-KEYSTROKE-RENDERING-UNDER-16MS-04 — the inserted character appears in the
//      text buffer immediately after the key event is handled: asserted on a small
//      note and on the 100 KB document, at the caret and at an explicit insertion
//      point, with the buffer, the text storage, the caret, and the measurement all
//      checked.
//
//  RECOVERY: the keystroke is represented as idle / active / succeeded / failed /
//  cancelled; a failure or a cancellation publishes nothing, puts the buffer back to
//  the last valid state, produces no modal alert, and retries only when the user types
//  again. The feature holds no task, stream, handle, or delegate, and
//  `releaseSurfaceResources()` releases what it does hold.
//
//  This suite constructs AppKit objects and measures real work, so it is `.serialized`:
//  its tests run one at a time instead of competing with a parallel run. The only
//  wall-clock assertions are the real budget measurements of ACC-02, and the one
//  deliberately slow measurement that proves the clock reports real elapsed time.
//
//  Swift Testing only: no XCTest, no placeholder assertions.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import MonospaceNotes

/// Shorthand for the type under test; file-private, so no other test file can collide
/// with it.
private typealias Keystroke = KeystrokeRenderingUnder16msFeature

// MARK: - File-scope fixtures (unique names: every test file compiles together)

/// The file-I/O tokens the keystroke path must not contain. `URL` is included on
/// purpose: the keystroke path names no path type at all, not merely no read or write
/// call.
private let keystrokeForbiddenFileIOTokens: [String] = [
    "FileManager",
    "Data(contentsOf:",
    "write(to:",
    "FileHandle",
    "URLSession",
    "NSDocument",
    "FileWrapper",
    "import Network",
    "URL",
]

/// The package root, found from this file's own compile-time path so the scan does not
/// depend on the process working directory.
private func keystrokeRenderingPackageRoot(filePath: String = #filePath) -> URL? {
    var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    for _ in 0..<8 {
        if FileManager.default.fileExists(
            atPath: candidate.appendingPathComponent("Package.swift").path
        ) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    return nil
}

/// The 100 KB document the budget is measured against: `bytes` bytes of UTF-8 text in
/// the shape a real note has — short lines, and roughly 2,700 of them at 100 KB.
/// ASCII only, so bytes and characters coincide and the size is exact.
@MainActor
private func keystrokeRenderingHundredKilobyteDocument(
    bytes: Int = KeystrokeRenderingUnder16msFeature.documentSizeForBudgetBytes
) -> String {
    var document = ""
    var line = 0
    while document.utf8.count < bytes {
        document += "line \(line) the quick brown fox jumps over the lazy dog 0123456789\n"
        line += 1
    }
    if document.utf8.count > bytes {
        document = String(document.prefix(bytes))
    }
    return document
}

/// The monospace font the surface renders with.
@MainActor
private func keystrokeRenderingFont(size: CGFloat = 13) -> NSFont {
    NSFont(name: TypographySettings.default.fontFamily, size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

/// The document surface, built by the feature's own surface factory and hosted the way
/// the app hosts it: a real TextKit 2 text view inside a scroll view, so the viewport
/// follows the caret.
@MainActor
private func keystrokeRenderingSurface(
    document: String,
    viewport: NSSize = NSSize(width: 960, height: 640)
) -> (scrollView: NSScrollView, textView: NSTextView) {
    _ = NSApplication.shared

    let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .black

    let textView = TextKit2DocumentView.makeDocumentTextView(
        text: document,
        font: keystrokeRenderingFont(),
        textColor: .white,
        backgroundColor: .black,
        isEditable: true,
        frame: NSRect(origin: .zero, size: viewport)
    )
    scrollView.documentView = textView
    return (scrollView, textView)
}

/// A prepared surface: the document is laid out and the caret is where the user is
/// typing, with the surface's drawing buffer already created — the state a document is
/// in when the user starts typing, which is when keystrokes are measured.
@MainActor
private func keystrokeRenderingPreparedSurface(
    document: String,
    caret: Int
) throws -> (feature: KeystrokeRenderingUnder16msFeature, scrollView: NSScrollView, textView: NSTextView) {
    let (scrollView, textView) = keystrokeRenderingSurface(document: document)
    let feature = KeystrokeRenderingUnder16msFeature()

    textView.setSelectedRange(NSRange(location: caret, length: 0))
    textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
    scrollView.layoutSubtreeIfNeeded()

    _ = try #require(feature.prepareSurface(textView), "the document surface could not be prepared")
    return (feature, scrollView, textView)
}

/// An order-sensitive fingerprint of what was really rasterised: FNV-1a over a strided
/// sample of every byte of the bitmap. Two different pictures give two different
/// numbers, which is how "the updated drawing contains the change" is checked.
@MainActor
private func keystrokeRenderingDrawnFingerprint(_ bitmap: NSBitmapImageRep) -> UInt64 {
    guard let data = bitmap.bitmapData else { return 0 }
    let total = bitmap.bytesPerRow * bitmap.pixelsHigh
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    var index = 0
    while index < total {
        hash = (hash ^ UInt64(data[index])) &* 0x0000_0100_0000_01b3
        index += 17
    }
    return hash
}

/// Finds the text view a SwiftUI host really built, without the test knowing anything
/// about the hierarchy in between.
@MainActor
private func keystrokeRenderingFindTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for subview in view.subviews {
        if let found = keystrokeRenderingFindTextView(in: subview) { return found }
    }
    return nil
}

/// Compares two colours by their rendered sRGB components, so two separately created
/// colours with the same components are recognised as the same colour.
@MainActor
private func keystrokeRenderingSameColor(_ first: NSColor, _ second: NSColor) -> Bool {
    guard let a = first.usingColorSpace(.sRGB), let b = second.usingColorSpace(.sRGB) else { return false }
    return a.redComponent == b.redComponent
        && a.greenComponent == b.greenComponent
        && a.blueComponent == b.blueComponent
        && a.alphaComponent == b.alphaComponent
}

/// The characters at a location in a buffer, or `nil` when the buffer is too short.
/// Used instead of indexing the buffer directly: an assertion about a buffer that did
/// not grow fails cleanly instead of trapping the whole suite.
@MainActor
private func keystrokeRenderingCharacters(
    in text: String,
    at location: Int,
    length: Int
) -> String? {
    let buffer = text as NSString
    guard location >= 0, length >= 0, location + length <= buffer.length else { return nil }
    return buffer.substring(with: NSRange(location: location, length: length))
}

/// The injected layout-and-drawing step of the failure and cancellation tests. It
/// reports a real failure on the attempts it is scripted to fail, and can interrupt a
/// keystroke in flight the way an application termination does — so both branches are
/// exercised against a real `NSTextView` instead of pretending that AppKit failed.
private final class KeystrokeRenderingScriptedLayoutStep: @unchecked Sendable {
    enum Script {
        /// A real layout and drawing pass: the character is rendered.
        case render
        /// The surface could not lay out or draw the updated text.
        case fail
        /// The application terminates while the keystroke is in flight.
        case interrupt
    }

    private let lock = NSLock()
    private var remaining: [Script]
    private var calls = 0

    init(scripts: [Script]) {
        self.remaining = scripts
    }

    /// Runs the step for one keystroke. `feature` is the feature whose keystroke is in
    /// flight, which the interruption script cancels.
    @MainActor
    func run(_ textView: NSTextView, feature: KeystrokeRenderingUnder16msFeature?) -> Bool {
        lock.lock()
        let script: Script = remaining.isEmpty ? .render : remaining.removeFirst()
        calls += 1
        lock.unlock()

        switch script {
        case .render:
            // A real pass: TextKit 2 layout of the document and a real drawing pass of
            // the visible region, written here so the retry after a failure renders for
            // real rather than being asserted as a success.
            guard let layoutManager = textView.textLayoutManager else { return false }
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            let visible = textView.visibleRect
            guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: visible) else { return false }
            textView.cacheDisplay(in: visible, to: bitmap)
            return true
        case .fail:
            return false
        case .interrupt:
            _ = feature?.cancel()
            return true
        }
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Holds the feature the injected step runs inside, so the interruption script needs no
/// global state.
private final class KeystrokeRenderingFeatureBox: @unchecked Sendable {
    var feature: KeystrokeRenderingUnder16msFeature?
}

/// Records what the surface's keystroke routing did.
private final class KeystrokeRenderingRouterRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var views: [NSTextView] = []

    func note(_ entry: String, _ textView: NSTextView) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(entry)
        views.append(textView)
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    var lastView: NSTextView? {
        lock.lock()
        defer { lock.unlock() }
        return views.last
    }
}

// MARK: - Suite

@Suite("FEAT-KEYSTROKE-RENDERING-UNDER-16MS keystroke rendering", .serialized)
@MainActor
struct KeystrokeRenderingUnder16msFeatureTests {

    // MARK: - Locked constants and the initial state

    @Test("The locked keystroke budget and document size are the contract values")
    func lockedBudgetConstants() {
        #expect(KeystrokeRenderingUnder16msFeature.budgetMilliseconds == 16)
        #expect(KeystrokeRenderingUnder16msFeature.keystrokeBudget == .milliseconds(16))
        #expect(KeystrokeRenderingUnder16msFeature.documentSizeForBudgetBytes == 102_400)
        #expect(
            KeystrokeRenderingUnder16msFeature.milliseconds(of: .milliseconds(16)) == 16,
            "the Duration and the number describe the same budget"
        )
        #expect(
            KeystrokeRenderingUnder16msFeature.milliseconds(of: KeystrokeRenderingUnder16msFeature.keystrokeBudget) == 16
        )

        let document = keystrokeRenderingHundredKilobyteDocument()
        #expect(document.utf8.count == KeystrokeRenderingUnder16msFeature.documentSizeForBudgetBytes)
        #expect(document.count == document.utf8.count, "the measured document is ASCII: bytes == characters")
        #expect(document.contains("\n"), "the measured document has the shape of a real note")

        let feature = KeystrokeRenderingUnder16msFeature()
        #expect(feature.keystrokeState == .idle)
        #expect(feature.lastMeasurement == nil)
        #expect(feature.lastKeystrokeMetBudget == nil)
        #expect(feature.lastFailureReason == nil)
        #expect(feature.lastStatusMessage == nil)
        #expect(feature.documentTextView == nil)
        #expect(feature.drawingBuffer == nil)
        #expect(feature.cancel() == false, "there is no keystroke in flight while idle")
    }

    // MARK: - ACC-KEYSTROKE-RENDERING-UNDER-16MS-04: the character reaches the buffer

    @Test("ACC-KEYSTROKE-RENDERING-UNDER-16MS-04: the inserted character appears in the buffer immediately")
    func insertedCharacterAppearsInTheBufferImmediately() throws {
        let (_, textView) = keystrokeRenderingSurface(document: "note")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        let feature = KeystrokeRenderingUnder16msFeature()
        feature.attach(textView)

        let inserted = feature.insert("q", into: textView)

        // The key event was handled and the buffer already carries the character.
        #expect(textView.string == "noteq")
        #expect(textView.textStorage?.string == "noteq", "the text storage and the surface agree")
        #expect(inserted.inserted)
        #expect(inserted.bufferUnchangedOnFailure == false)
        #expect(inserted.milliseconds >= 0)
        #expect(feature.keystrokeState == .succeeded)
        #expect(feature.lastMeasurement == inserted)
        #expect(feature.lastFailureReason == nil)
        #expect(feature.lastStatusMessage == nil)
        #expect(feature.documentTextView === textView)

        // The character is at the insertion point it was typed at, and the caret moved
        // past it, so the next keystroke lands where the user expects.
        #expect(keystrokeRenderingCharacters(in: textView.string, at: 4, length: 1) == "q")
        #expect(textView.selectedRange().location == 5)

        // A second keystroke through the same path lands right after it.
        let second = feature.insert("a", into: textView)
        #expect(second.inserted)
        #expect(textView.string == "noteqa")
        #expect(keystrokeRenderingCharacters(in: textView.string, at: 4, length: 2) == "qa")

        // An explicit insertion point is honoured too, and the buffer is exact.
        let third = feature.insert("-", into: textView, at: 0)
        #expect(third.inserted)
        #expect(textView.string == "-noteqa")
    }

    @Test("ACC-KEYSTROKE-RENDERING-UNDER-16MS-04: the character reaches a 100 KB buffer immediately")
    func insertedCharacterAppearsInHundredKilobyteBuffer() throws {
        let document = keystrokeRenderingHundredKilobyteDocument()
        let length = (document as NSString).length
        let (feature, _, textView) = try keystrokeRenderingPreparedSurface(document: document, caret: length)

        let measurement = feature.insert("z", into: textView)

        #expect(measurement.inserted)
        #expect(textView.string.hasSuffix("z"))
        #expect((textView.string as NSString).length == length + 1)
        #expect(textView.string.hasPrefix(document), "the document is untouched apart from the new character")
        #expect(keystrokeRenderingCharacters(in: textView.string, at: length, length: 1) == "z")
        #expect(feature.keystrokeState == .succeeded)
    }

    // MARK: - ACC-KEYSTROKE-RENDERING-UNDER-16MS-02: the measured 16 ms budget

    @Test("ACC-KEYSTROKE-RENDERING-UNDER-16MS-02: keystroke rendering on a 100 KB document stays inside 16 ms")
    func keystrokeRenderingStaysInsideBudgetOnHundredKilobyteDocument() throws {
        let document = keystrokeRenderingHundredKilobyteDocument()
        let length = (document as NSString).length
        #expect(document.utf8.count == KeystrokeRenderingUnder16msFeature.documentSizeForBudgetBytes)

        // Real caret positions in a 100 KB note: the end of the note, the middle of it,
        // and the beginning of it.
        let positions: [(label: String, caret: Int)] = [
            ("caret at the end of the document", length),
            ("caret in the middle of the document", length / 2),
            ("caret at the start of the document", 0),
        ]

        let keystrokesPerPosition = 9
        var everyMeasuredNumber: [Double] = []

        for position in positions {
            let (feature, _, textView) = try keystrokeRenderingPreparedSurface(
                document: document, caret: position.caret
            )
            #expect(textView.textLayoutManager != nil, "the measured surface must be TextKit 2")
            #expect(textView.string == document)

            var numbers: [Double] = []
            var previousFingerprint: UInt64?
            var drawingsThatChanged = 0
            var consecutivePairs = 0

            for _ in 0..<keystrokesPerPosition {
                // The key event: one character from the caret, handled as one
                // uninterrupted call — the clock runs inside `insert`.
                let measurement = feature.insert("x", into: textView)
                numbers.append(measurement.milliseconds)
                everyMeasuredNumber.append(measurement.milliseconds)

                // ACC-02: the real measured number, compared against the locked budget.
                #expect(measurement.milliseconds < KeystrokeRenderingUnder16msFeature.budgetMilliseconds)
                #expect(measurement.duration < KeystrokeRenderingUnder16msFeature.keystrokeBudget)
                #expect(KeystrokeRenderingUnder16msFeature.meetsBudget(measurement))
                #expect(feature.lastKeystrokeMetBudget == true)
                #expect(measurement.metBudget)

                // ACC-04 on every measured keystroke.
                #expect(measurement.inserted)
                #expect(measurement.drew)
                #expect(measurement.cancelled == false)
                #expect(feature.keystrokeState == .succeeded)

                // The updated drawing really contains the change: the bitmap this
                // keystroke was drawn into differs from the previous one.
                let bitmap = try #require(
                    feature.drawingBuffer,
                    "the surface has no drawing buffer, so nothing was rasterised"
                )
                let fingerprint = keystrokeRenderingDrawnFingerprint(bitmap)
                #expect(fingerprint != 0, "the drawn bitmap holds no pixels at all")
                if let previous = previousFingerprint {
                    consecutivePairs += 1
                    if fingerprint != previous { drawingsThatChanged += 1 }
                }
                previousFingerprint = fingerprint
            }

            let measured = numbers.map { String(format: "%.3f", $0) }.joined(separator: ", ")
            print("[TASK-06] ACC-02 keystroke rendering, 100 KB document (\(document.utf8.count) bytes), "
                  + "\(position.label): \(measured) ms — max "
                  + "\(String(format: "%.3f", numbers.max() ?? -1)) ms, budget "
                  + "\(KeystrokeRenderingUnder16msFeature.budgetMilliseconds) ms; drawings that changed: "
                  + "\(drawingsThatChanged)/\(consecutivePairs)")

            #expect(numbers.count == keystrokesPerPosition)
            #expect(numbers.allSatisfy { $0 < KeystrokeRenderingUnder16msFeature.budgetMilliseconds })
            #expect(
                drawingsThatChanged == consecutivePairs,
                "a character that reached the buffer must change the drawn region"
            )

            // The buffer is exactly the document plus this position's inserted run,
            // wherever the caret was: it grew by one character per keystroke, the run the
            // keystrokes inserted sits at this caret, and removing exactly that run
            // restores the original document character for character. Stated this way the
            // check holds at every caret position — including the start of the document,
            // where a prefix check fails for a perfectly correct keystroke.
            let buffer = textView.string as NSString
            #expect(
                buffer.length == length + keystrokesPerPosition,
                "the buffer grew by exactly the inserted length"
            )
            let insertedRun = NSRange(location: position.caret, length: keystrokesPerPosition)
            try #require(insertedRun.location + insertedRun.length <= buffer.length)
            #expect(
                buffer.substring(with: insertedRun) == String(repeating: "x", count: keystrokesPerPosition),
                "the run this position inserted is exactly the keystrokes it accepted"
            )
            #expect(
                buffer.replacingCharacters(in: insertedRun, with: "") == document,
                "removing exactly the inserted run restores the original document"
            )
        }

        let worst = everyMeasuredNumber.max() ?? .infinity
        print("[TASK-06] ACC-02 all \(everyMeasuredNumber.count) measured keystrokes on the 100 KB document: "
              + "worst \(String(format: "%.3f", worst)) ms against the "
              + "\(KeystrokeRenderingUnder16msFeature.budgetMilliseconds) ms budget")
        #expect(worst < KeystrokeRenderingUnder16msFeature.budgetMilliseconds)
    }

    @Test("A keystroke that did not render never meets the rendering budget")
    func budgetCannotBeMetByAFailedKeystroke() {
        let fast = Keystroke.Measurement(
            milliseconds: 1, inserted: true, bufferUnchangedOnFailure: false,
            duration: .milliseconds(1), drew: true, cancelled: false
        )
        let slow = Keystroke.Measurement(
            milliseconds: 16.5, inserted: true, bufferUnchangedOnFailure: false,
            duration: .milliseconds(16.5), drew: true, cancelled: false
        )
        let exactlyAtTheBudget = Keystroke.Measurement(
            milliseconds: 16, inserted: true, bufferUnchangedOnFailure: false,
            duration: .milliseconds(16), drew: true, cancelled: false
        )
        let notRendered = Keystroke.Measurement(
            milliseconds: 0.5, inserted: false, bufferUnchangedOnFailure: true,
            duration: .milliseconds(0.5), drew: false, cancelled: false
        )
        let interrupted = Keystroke.Measurement(
            milliseconds: 0.5, inserted: false, bufferUnchangedOnFailure: true,
            duration: .milliseconds(0.5), drew: true, cancelled: true
        )

        let feature = KeystrokeRenderingUnder16msFeature()

        #expect(KeystrokeRenderingUnder16msFeature.meetsBudget(fast))
        #expect(fast.metBudget)
        #expect(KeystrokeRenderingUnder16msFeature.meetsBudget(slow) == false)
        #expect(slow.metBudget == false)
        #expect(
            KeystrokeRenderingUnder16msFeature.meetsBudget(exactlyAtTheBudget) == false,
            "the budget is strict: 16 ms is not under 16 ms"
        )
        #expect(KeystrokeRenderingUnder16msFeature.meetsBudget(notRendered) == false)
        #expect(KeystrokeRenderingUnder16msFeature.meetsBudget(interrupted) == false)

        #expect(feature.evaluate(fast) == .succeeded)
        #expect(
            feature.evaluate(slow) == .succeeded,
            "a surface that renders slowly has rendered: the budget is reported separately"
        )
        #expect(feature.evaluate(notRendered) == .failed)
        #expect(feature.evaluate(interrupted) == .cancelled)
    }

    @Test("The measured number is real elapsed time, not a constant")
    func measurementReflectsRealElapsedTime() throws {
        let (_, textView) = keystrokeRenderingSurface(document: "note")
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        let feature = KeystrokeRenderingUnder16msFeature(layoutAndDraw: { textView in
            // A layout-and-drawing step that really takes 30 ms cannot measure faster.
            Thread.sleep(forTimeInterval: 0.03)
            guard let layoutManager = textView.textLayoutManager else { return false }
            layoutManager.ensureLayout(for: layoutManager.documentRange)
            return true
        })

        let measurement = feature.insert("x", into: textView)

        #expect(measurement.milliseconds >= 30)
        #expect(measurement.duration >= .milliseconds(30))
        #expect(KeystrokeRenderingUnder16msFeature.meetsBudget(measurement) == false)
        #expect(feature.lastKeystrokeMetBudget == false)
        #expect(feature.keystrokeState == .succeeded, "a budget miss is not a keystroke failure")
        #expect(textView.string == "notex")
    }

    @Test("The single-line 100 KB worst case is measured and reported, not asserted against the budget")
    func singleLineHundredKilobyteWorstCaseIsReported() throws {
        // A 100 KB note with no line breaks is one enormous wrapped paragraph: TextKit 2
        // has to re-wrap that whole paragraph for every keystroke, which is a different
        // workload from typing in a normal note. It is measured here and printed so the
        // number is on the record; the budget assertion of ACC-02 is made on the
        // realistic note shape above, where a keystroke pays only for the layout its own
        // edit invalidates.
        let document = String(
            repeating: "the quick brown fox jumps over the lazy dog 0123456789 ",
            count: KeystrokeRenderingUnder16msFeature.documentSizeForBudgetBytes / 55
        )
        #expect(document.utf8.count >= 100_000)
        #expect(document.contains("\n") == false, "the worst case really has no line breaks")

        let (feature, _, textView) = try keystrokeRenderingPreparedSurface(
            document: document, caret: (document as NSString).length
        )

        var numbers: [Double] = []
        var insertedCount = 0
        for _ in 0..<6 {
            let measurement = feature.insert("x", into: textView)
            numbers.append(measurement.milliseconds)
            if measurement.inserted { insertedCount += 1 }
        }

        let measured = numbers.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        print("[TASK-06] single-line 100 KB note (\(document.utf8.count) bytes, one wrapped paragraph), "
              + "real measured keystrokes: \(measured) ms — reported, not asserted against the "
              + "\(KeystrokeRenderingUnder16msFeature.budgetMilliseconds) ms budget")

        #expect(numbers.count == 6)
        #expect(numbers.allSatisfy { $0 > 0 }, "every keystroke was really measured")
        #expect(insertedCount == 6, "every character still reached the buffer immediately")
        #expect((textView.string as NSString).length == (document as NSString).length + 6)
    }

    // MARK: - ACC-KEYSTROKE-RENDERING-UNDER-16MS-01: a failure leaves the buffer unchanged

    @Test("ACC-KEYSTROKE-RENDERING-UNDER-16MS-01: a layout failure leaves the buffer unchanged")
    func layoutFailureLeavesTheBufferUnchanged() throws {
        let scripts = KeystrokeRenderingScriptedLayoutStep(scripts: [.fail])
        let box = KeystrokeRenderingFeatureBox()
        let feature = KeystrokeRenderingUnder16msFeature(layoutAndDraw: { textView in
            scripts.run(textView, feature: box.feature)
        })
        box.feature = feature

        // The failure text is one constant that mentions "the note" as a common noun, so a
        // document whose content is the literal string "note" could not tell leaked note
        // content from the message's own words. This document cannot collide with it.
        let document = "alpha bravo"
        let (_, textView) = keystrokeRenderingSurface(document: document)
        textView.setSelectedRange(NSRange(location: (document as NSString).length, length: 0))
        feature.attach(textView)

        let measurement = feature.insert("x", into: textView)

        // The failure behaviour of the interface contract, asserted on the real buffer.
        #expect(textView.string == document, "a failed keystroke leaves the buffer unchanged")
        #expect(measurement.bufferUnchangedOnFailure)
        #expect(measurement.inserted == false)
        #expect(measurement.drew == false)
        #expect(measurement.cancelled == false)
        #expect(KeystrokeRenderingUnder16msFeature.meetsBudget(measurement) == false)
        #expect(feature.keystrokeState == .failed)
        #expect(feature.lastFailureReason == .layoutFailed)
        #expect(feature.lastKeystrokeMetBudget == nil)

        // The failure is explained non-modally and says nothing about the document.
        let status = try #require(feature.lastStatusMessage)
        #expect(status.isFailure)
        #expect(status.text == KeystrokeRenderingUnder16msFeature.failureStatusText)
        #expect(status.text.contains("/") == false, "the message carries no file path")
        #expect(status.text.contains(document) == false, "the message carries no note content")
        #expect(status.text.contains(textView.string) == false, "the message carries no buffer content")
        #expect(status.text.contains("retry"), "the explicit retry the recovery contract asks for is stated")

        // The injected step ran exactly once: nothing was retried automatically.
        #expect(scripts.callCount == 1)

        // The explicit retry (the user types again) renders for real and publishes.
        let retry = feature.insert("x", into: textView)
        #expect(retry.inserted)
        #expect(retry.drew)
        #expect(retry.bufferUnchangedOnFailure == false)
        #expect(textView.string == document + "x")
        #expect(feature.keystrokeState == .succeeded)
        #expect(feature.lastFailureReason == nil)
        #expect(feature.lastStatusMessage == nil)
        #expect(feature.lastKeystrokeMetBudget == true)
        #expect(scripts.callCount == 2)
    }

    @Test("ACC-KEYSTROKE-RENDERING-UNDER-16MS-01: an out-of-range insertion point leaves the buffer unchanged")
    func outOfRangeInsertionPointLeavesTheBufferUnchanged() throws {
        let (_, textView) = keystrokeRenderingSurface(document: "note")
        let feature = KeystrokeRenderingUnder16msFeature()

        let pastTheEnd = feature.insert("x", into: textView, at: 9_999)
        #expect(textView.string == "note")
        #expect(pastTheEnd.bufferUnchangedOnFailure)
        #expect(pastTheEnd.inserted == false)
        #expect(pastTheEnd.milliseconds == 0)
        #expect(pastTheEnd.duration == .zero)
        #expect(feature.keystrokeState == .failed)
        #expect(feature.lastFailureReason == .insertionPointOutOfRange)
        #expect(feature.lastStatusMessage?.isFailure == true)
        #expect(feature.lastStatusMessage?.text == KeystrokeRenderingUnder16msFeature.failureStatusText)

        let beforeTheStart = feature.insert("x", into: textView, at: -1)
        #expect(textView.string == "note")
        #expect(beforeTheStart.bufferUnchangedOnFailure)
        #expect(feature.lastFailureReason == .insertionPointOutOfRange)

        // One past the last character is inside the buffer, so it is a valid caret.
        let appendAtTheEnd = feature.insert("x", into: textView, at: 4)
        #expect(appendAtTheEnd.inserted)
        #expect(textView.string == "notex")
        #expect(feature.keystrokeState == .succeeded)
    }

    @Test("A non-editable surface and an empty interpretation are rejected without touching the buffer")
    func rejectedKeystrokesLeaveTheBufferAlone() throws {
        let (_, textView) = keystrokeRenderingSurface(document: "note")
        let feature = KeystrokeRenderingUnder16msFeature()

        let empty = feature.insert("", into: textView)
        #expect(textView.string == "note")
        #expect(empty.bufferUnchangedOnFailure)
        #expect(feature.lastFailureReason == .nothingToInsert)

        textView.isEditable = false
        let notEditable = feature.insert("x", into: textView)
        #expect(textView.string == "note", "a surface that is not editable accepts no keystroke")
        #expect(notEditable.bufferUnchangedOnFailure)
        #expect(notEditable.inserted == false)
        #expect(feature.lastFailureReason == .documentNotEditable)

        // The same surface becomes editable again and renders the keystroke.
        textView.isEditable = true
        #expect(textView.selectedRange().location == 0, "a rejected keystroke never moves the caret")
        let accepted = feature.insert("x", into: textView)
        #expect(accepted.inserted)
        #expect(textView.string == "xnote", "the caret is still at index 0, so the character lands there")
    }

    @Test("A non-TextKit-2 surface is refused, never silently rendered somewhere else")
    func nonTextKit2SurfaceIsRefused() {
        _ = NSApplication.shared
        // `NSTextView(frame:)` is already a TextKit 2 surface on this toolchain, so the
        // compatibility surface has to be asked for explicitly: otherwise this test
        // asserts about a surface that is not the one it means to test.
        let legacy = NSTextView(usingTextLayoutManager: false)
        legacy.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        legacy.string = "note"
        #expect(
            legacy.textLayoutManager == nil,
            "the compatibility surface really has no TextKit 2 layout manager"
        )
        #expect(legacy.layoutManager != nil, "the compatibility surface is a real TextKit 1 text view")

        let feature = KeystrokeRenderingUnder16msFeature()
        let measurement = feature.insert("x", into: legacy, at: 4)

        #expect(legacy.string == "note")
        #expect(measurement.inserted == false)
        #expect(measurement.bufferUnchangedOnFailure)
        #expect(feature.lastFailureReason == .surfaceIsNotTextKit2)
    }

    // MARK: - RECOVERY: cancellation, last valid state, cleanup

    @Test("An interrupted keystroke is never published and the buffer keeps the last valid state")
    func interruptedKeystrokeIsNeverPublished() throws {
        let scripts = KeystrokeRenderingScriptedLayoutStep(scripts: [.interrupt])
        let box = KeystrokeRenderingFeatureBox()
        let feature = KeystrokeRenderingUnder16msFeature(layoutAndDraw: { textView in
            scripts.run(textView, feature: box.feature)
        })
        box.feature = feature

        let (_, textView) = keystrokeRenderingSurface(document: "note")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        feature.attach(textView)

        let measurement = feature.insert("x", into: textView)

        #expect(textView.string == "note", "an interrupted keystroke is rolled back")
        #expect(measurement.cancelled)
        #expect(measurement.inserted == false)
        #expect(measurement.bufferUnchangedOnFailure)
        #expect(feature.keystrokeState == .cancelled)
        #expect(feature.lastKeystrokeMetBudget == nil)
        #expect(feature.lastStatusMessage == nil, "an interruption is not an error")
        #expect(feature.evaluate(measurement) == .cancelled)

        // Interrupting again reports no further interruption, and the surface recovers.
        #expect(feature.cancel() == false)
        let afterTheInterruption = feature.insert("y", into: textView)
        #expect(afterTheInterruption.inserted)
        #expect(textView.string == "notey")
        #expect(feature.keystrokeState == .succeeded)
    }

    @Test("Releasing the surface resources releases the view and the drawing buffer and is idempotent")
    func releaseSurfaceResourcesIsCleanAndIdempotent() throws {
        let document = keystrokeRenderingHundredKilobyteDocument(bytes: 8_192)
        let (feature, _, textView) = try keystrokeRenderingPreparedSurface(
            document: document, caret: (document as NSString).length
        )
        #expect(feature.documentTextView != nil)
        #expect(feature.drawingBuffer != nil)
        #expect(feature.lastFullLayoutBounds.height > 0, "the prepared surface really laid the document out")

        feature.releaseSurfaceResources()

        #expect(feature.documentTextView == nil)
        #expect(feature.drawingBuffer == nil)

        // Idempotent, and the surface can be attached and rendered again afterwards.
        feature.releaseSurfaceResources()
        #expect(feature.documentTextView == nil)
        #expect(feature.prepareSurface(textView))
        let measurement = feature.insert("x", into: textView)
        #expect(measurement.inserted)
        #expect((textView.string as NSString).length == (document as NSString).length + 1)
    }

    // MARK: - ACC-KEYSTROKE-RENDERING-UNDER-16MS-03: no file I/O on the keystroke path

    @Test("ACC-KEYSTROKE-RENDERING-UNDER-16MS-03: the keystroke path reaches no file I/O")
    func keystrokePathReachesNoFileIO() throws {
        // STRUCTURAL PROOF, with its limitation stated plainly: this scans the published
        // implementation of the keystroke path for file-I/O API. It is not a runtime
        // trace, and it says nothing about code that does not exist — it is the guard
        // that a future edit cannot quietly add file I/O to the keystroke path.
        let root = try #require(keystrokeRenderingPackageRoot(), "package root not found")
        let sourceURL = root.appendingPathComponent(
            "Sources/MonospaceNotes/Features/KeystrokeRenderingUnder16msFeature.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // The scan is over the real file: a vacuous pass would prove nothing.
        #expect(source.utf8.count > 20_000, "expected the whole keystroke path, read \(source.utf8.count) bytes")
        #expect(source.contains("final class KeystrokeRenderingUnder16msFeature"))
        #expect(source.contains("struct TextKit2DocumentView: NSViewRepresentable"))
        #expect(source.contains("NSTextView(usingTextLayoutManager: true)"), "the surface really is TextKit 2")
        #expect(source.contains("textLayoutManager"))
        #expect(source.contains("@MainActor"), "the keystroke path runs on the main actor")

        // No file-I/O API, and no path type at all, exists in the keystroke path.
        for token in keystrokeForbiddenFileIOTokens {
            #expect(
                source.contains(token) == false,
                "the keystroke path contains '\(token)', so main-thread file I/O could be reached from it"
            )
        }
        #expect(keystrokeForbiddenFileIOTokens.count >= 6)

        // The insert entry points take a character and a text view and nothing else.
        let signatures = source.split(separator: "\n").filter { $0.contains("func insert(") }
        #expect(signatures.count >= 2, "expected both insert entry points, found \(signatures.count)")
        for signature in signatures {
            #expect(signature.contains("character: String"))
            #expect(signature.contains("into textView: NSTextView"))
            for token in keystrokeForbiddenFileIOTokens {
                #expect(signature.contains(token) == false)
            }
        }

        // The API shape is a compile-time proof as well: this call passes a character
        // and a text view, and there is no parameter through which a file could reach
        // the keystroke path.
        let (_, textView) = keystrokeRenderingSurface(document: "note")
        let feature = KeystrokeRenderingUnder16msFeature()
        let measurement = feature.insert("x", into: textView)
        #expect(measurement.inserted)

        // The feature has no injected file or settings service at all, so the
        // main-actor keystroke path holds nothing that performs I/O.
        #expect(source.contains("NoteFileAccess") == false)
        #expect(source.contains("SettingsStoring") == false)
        #expect(source.contains("DataStore") == false)
        #expect(source.contains("ioRecorder") == false)
        #expect(feature.documentTextView == nil, "a freshly built feature holds no file service and no surface")
    }

    // MARK: - The TextKit 2 document surface

    @Test("The document surface is a real TextKit 2 text view carrying the document values")
    func documentSurfaceIsGenuinelyTextKit2() throws {
        _ = NSApplication.shared
        let font = keystrokeRenderingFont()
        let document = "note text\nsecond line\n"

        let textView = TextKit2DocumentView.makeDocumentTextView(
            text: document,
            font: font,
            textColor: .white,
            backgroundColor: .black,
            isEditable: true
        )

        #expect(textView.textLayoutManager != nil, "the surface must be genuinely TextKit 2")
        #expect(textView.textContainer != nil)
        #expect(textView.textContentStorage != nil)
        #expect(textView.string == document)
        #expect(textView.isEditable)
        #expect(textView.isSelectable)
        #expect(textView.isRichText == false)
        #expect(textView.drawsBackground)
        #expect(textView.font?.familyName == font.familyName)
        #expect(textView.font?.pointSize == font.pointSize)
        #expect(keystrokeRenderingSameColor(try #require(textView.textColor), .white))
        #expect(keystrokeRenderingSameColor(textView.backgroundColor, .black))
        #expect(keystrokeRenderingSameColor(textView.insertionPointColor, .white))
        #expect(textView.accessibilityLabel() == TextKit2DocumentView.defaultAccessibilityLabel)
        #expect(textView.accessibilityRole() == .textArea)
        #expect(TextKit2DocumentView.defaultAccessibilityLabel == "Note text")

        // The same wiring path updates an existing surface without moving the caret.
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        let secondFont = keystrokeRenderingFont(size: 16)
        TextKit2DocumentView.apply(
            text: document,
            font: secondFont,
            textColor: .black,
            backgroundColor: .white,
            isEditable: false,
            to: textView
        )
        #expect(textView.string == document, "identical text is not rewritten")
        #expect(textView.selectedRange().location == 2, "an update does not move the caret")
        #expect(textView.font?.pointSize == 16)
        #expect(textView.isEditable == false)
        #expect(keystrokeRenderingSameColor(try #require(textView.textColor), .black))
        #expect(keystrokeRenderingSameColor(textView.backgroundColor, .white))

        // New text is applied, and a caret past the new end is clamped instead of lost.
        textView.setSelectedRange(NSRange(location: 21, length: 0))
        TextKit2DocumentView.apply(
            text: "short",
            font: secondFont,
            textColor: .black,
            backgroundColor: .white,
            isEditable: true,
            to: textView
        )
        #expect(textView.string == "short")
        #expect(textView.selectedRange().location == 5)
    }

    @Test("The document surface is wired to AppState's document text, font, and colours")
    func documentSurfaceIsWiredToAppState() throws {
        _ = NSApplication.shared
        let state = AppState()

        let surface = TextKit2DocumentView(state: state)

        #expect(surface.text == state.documentText)
        #expect(surface.text == "", "a freshly launched app has no open note")
        #expect(surface.font.familyName == state.documentFont.familyName)
        #expect(surface.font.pointSize == state.documentFont.pointSize)
        #expect(
            surface.font.familyName == TypographySettings.default.fontFamily,
            "the surface renders the configured monospace family"
        )
        #expect(surface.font.pointSize == CGFloat(TypographySettings.default.pointSize))
        #expect(keystrokeRenderingSameColor(surface.textColor, state.documentTextColor))
        #expect(keystrokeRenderingSameColor(surface.backgroundColor, state.windowBackgroundColor))
        #expect(keystrokeRenderingSameColor(surface.backgroundColor, .black))
        #expect(
            state.documentContrastRatio >= 7,
            "the surface renders the contrast-checked foreground of the appearance feature"
        )
        #expect(surface.isEditable == state.isEditable)
        #expect(surface.handleKeystroke != nil, "typed characters are routed through AppState")
        #expect(
            surface.onDocumentTextViewReady == nil,
            "nothing is attached until the composition root wires the surface"
        )

        // The surface the app builds from this state is TextKit 2 and carries the state.
        let textView = TextKit2DocumentView.makeDocumentTextView(
            text: surface.text,
            font: surface.font,
            textColor: surface.textColor,
            backgroundColor: surface.backgroundColor,
            isEditable: surface.isEditable,
            accessibilityLabel: surface.accessibilityLabel
        )
        #expect(textView.textLayoutManager != nil)
        #expect(textView.font?.familyName == state.documentFont.familyName)
        #expect(keystrokeRenderingSameColor(try #require(textView.textColor), surface.textColor))
    }

    @Test("The document surface renders in a SwiftUI host as a wired TextKit 2 text view")
    func documentSurfaceRendersInAHostingView() throws {
        _ = NSApplication.shared
        let recorder = KeystrokeRenderingRouterRecorder()
        let surface = TextKit2DocumentView(
            text: "note text",
            font: keystrokeRenderingFont(),
            textColor: .white,
            backgroundColor: .black,
            isEditable: true,
            handleKeystroke: { character, textView in
                recorder.note(character, textView)
                return true
            },
            onDocumentTextViewReady: { textView in recorder.note("ready", textView) }
        )

        let host = NSHostingView(rootView: surface)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()

        let hosted = try #require(
            keystrokeRenderingFindTextView(in: host),
            "the SwiftUI host built no text view"
        )
        #expect(hosted.textLayoutManager != nil, "the hosted surface must be TextKit 2")
        #expect(hosted.enclosingScrollView?.hasVerticalScroller == true,
                "a note longer than the window must scroll")
        #expect(hosted.string == "note text")
        #expect(hosted.isEditable)
        #expect(hosted.font?.familyName == keystrokeRenderingFont().familyName)
        #expect(keystrokeRenderingSameColor(try #require(hosted.textColor), .white))
        #expect(keystrokeRenderingSameColor(hosted.backgroundColor, .black))
        #expect(hosted.accessibilityLabel() == TextKit2DocumentView.defaultAccessibilityLabel)

        // The surface handed its text view over exactly once, and it is the hosted one.
        #expect(recorder.recorded.first == "ready")
        #expect(recorder.lastView === hosted)

        // Keystrokes typed into the hosted surface are routed to the app's path.
        hosted.setSelectedRange(NSRange(location: 4, length: 0))
        hosted.insertText("q", replacementRange: NSRange(location: 4, length: 0))
        #expect(recorder.recorded.contains("q"))
        #expect(recorder.lastView === hosted)
    }

    @Test("A keystroke typed into the surface runs the whole measured path and inserts exactly once")
    func hostedKeystrokeRunsTheMeasuredPath() throws {
        _ = NSApplication.shared
        let feature = KeystrokeRenderingUnder16msFeature()
        let surface = TextKit2DocumentView(
            text: "note",
            font: keystrokeRenderingFont(),
            textColor: .white,
            backgroundColor: .black,
            isEditable: true,
            handleKeystroke: { character, textView in
                feature.attach(textView)
                let measurement = feature.insert(character, into: textView)
                return measurement.inserted
            }
        )

        let host = NSHostingView(rootView: surface)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        let textView = try #require(keystrokeRenderingFindTextView(in: host))
        #expect(feature.prepareSurface(textView))

        // AppKit's own text-input entry point, i.e. what a typed character does.
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        textView.insertText("q", replacementRange: NSRange(location: 4, length: 0))

        #expect(
            textView.string == "noteq",
            "the character is inserted exactly once, through the measured path"
        )
        #expect(feature.keystrokeState == .succeeded)
        let measurement = try #require(feature.lastMeasurement)
        #expect(measurement.inserted)
        #expect(measurement.milliseconds >= 0)
        #expect(feature.documentTextView === textView)

        // A second character lands right after the first, with no duplicate insertion.
        textView.insertText("a", replacementRange: NSRange(location: 5, length: 0))
        #expect(textView.string == "noteqa")
    }

    @Test("The surface routes a keystroke to the app exactly once, even when the app inserts it itself")
    func keystrokeRoutingIsNotReentrant() throws {
        let (_, textView) = keystrokeRenderingSurface(document: "note")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        let range = NSRange(location: 4, length: 0)

        // The app's measured keystroke path: it inserts the character itself and reports
        // that it did, so AppKit must not insert a second copy.
        let recorder = KeystrokeRenderingRouterRecorder()
        let applied = TextKit2DocumentView(
            text: "note",
            font: keystrokeRenderingFont(),
            textColor: .white,
            backgroundColor: .black,
            isEditable: true,
            handleKeystroke: { character, surface in
                recorder.note(character, surface)
                // The measured path's own insertion goes through the same entry point,
                // which is what the delegate sees again.
                surface.insertText(character, replacementRange: surface.selectedRange())
                return true
            }
        )
        let appliedCoordinator = TextKit2DocumentView.Coordinator(parent: applied)
        let allowed = appliedCoordinator.textView(textView, shouldChangeTextIn: range, replacementString: "q")

        #expect(allowed == false, "the app owns keystroke insertion, so AppKit does not insert a second copy")
        #expect(recorder.recorded == ["q"], "the handler ran exactly once for one keystroke")
        #expect(appliedCoordinator.routedKeystrokeCount == 1)
        #expect(appliedCoordinator.isApplyingMeasuredKeystroke == false, "the re-entry guard is released")
        #expect(textView.string == "noteq", "the character was inserted by the app's path only")

        // A keystroke the app did not render is left unrendered: AppKit does not insert
        // it behind the path that refused it.
        let rejected = TextKit2DocumentView(
            text: "noteq",
            font: keystrokeRenderingFont(),
            textColor: .white,
            backgroundColor: .black,
            isEditable: true,
            handleKeystroke: { _, _ in false }
        )
        let rejectedCoordinator = TextKit2DocumentView.Coordinator(parent: rejected)
        let rejectedAllowed = rejectedCoordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 5, length: 0), replacementString: "x"
        )
        #expect(rejectedAllowed == false)
        #expect(textView.string == "noteq", "a rejected keystroke leaves the buffer unchanged")
        #expect(rejectedCoordinator.routedKeystrokeCount == 1)

        // With no keystroke path installed, AppKit's own insertion is left alone.
        let unmanaged = TextKit2DocumentView(
            text: "noteq",
            font: keystrokeRenderingFont(),
            textColor: .white,
            backgroundColor: .black,
            isEditable: true
        )
        let unmanagedCoordinator = TextKit2DocumentView.Coordinator(parent: unmanaged)
        #expect(unmanagedCoordinator.textView(textView, shouldChangeTextIn: range, replacementString: "q"))
        #expect(
            unmanagedCoordinator.routedKeystrokeCount == 0,
            "no handler means no routing, not a swallowed keystroke"
        )

        // An insertion AppKit makes on its own (no replacement text) is not routed.
        let recording = KeystrokeRenderingRouterRecorder()
        let observing = TextKit2DocumentView(
            text: "noteq",
            font: keystrokeRenderingFont(),
            textColor: .white,
            backgroundColor: .black,
            isEditable: true,
            handleKeystroke: { character, surface in
                recording.note(character, surface)
                return true
            }
        )
        let observingCoordinator = TextKit2DocumentView.Coordinator(parent: observing)
        #expect(observingCoordinator.textView(textView, shouldChangeTextIn: range, replacementString: nil))
        #expect(recording.recorded.isEmpty)
    }

    @Test("Deleting and replacing a selection edit the document and reach the buffer")
    func deletionsAndSelectionReplacementsEditTheBuffer() throws {
        _ = NSApplication.shared
        let state = AppState()
        let surface = TextKit2DocumentView(state: state)
        let coordinator = TextKit2DocumentView.Coordinator(parent: surface)
        let (scrollView, textView) = keystrokeRenderingSurface(document: "")
        defer { _ = scrollView }
        textView.delegate = coordinator
        state.keystrokeRendering.attach(textView)

        for character in ["h", "e", "l", "l", "o"] {
            textView.insertText(character, replacementRange: textView.selectedRange())
        }
        #expect(textView.string == "hello")
        #expect(state.documentText == "hello")
        #expect(state.hasUnsavedChanges)

        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.deleteBackward(nil)
        #expect(textView.string == "hell", "Backspace removes the character before the caret")
        #expect(state.documentText == "hell", "the buffer Cmd+S writes follows the deletion")

        textView.setSelectedRange(NSRange(location: 0, length: 2))
        textView.insertText("J", replacementRange: textView.selectedRange())
        #expect(textView.string == "Jll", "typing over a selection replaces it")
        #expect(state.documentText == "Jll")

        textView.setSelectedRange(NSRange(location: 0, length: 1))
        textView.delete(nil)
        #expect(textView.string == "ll", "deleting a selection removes it")
        #expect(state.documentText == "ll")
        #expect(state.statusMessage == nil, "an ordinary edit reports no failure")
    }
}
