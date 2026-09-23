//
//  KeystrokeRenderingUnder16msFeature.swift
//  MonospaceNotes
//
//  TASK-06-KEYSTROKE-RENDERING-UNDER-16MS — owner
//  OWN-KEYSTROKE-RENDERING-UNDER-16MS.
//
//  Owns the keystroke path and the document surface of
//  FEAT-KEYSTROKE-RENDERING-UNDER-16MS:
//
//    * CON-KEYSTROKE-RENDERING-UNDER-16MS-INTERFACE — "the app inserts the
//      character into the text buffer and lays out and draws the updated text
//      using TextKit 2. The main thread performs no file I/O during keystroke
//      handling." The transition is measured with `ContinuousClock` against
//      `keystrokeBudget` (16 ms) on the machine that runs it, for a document of
//      `documentSizeForBudgetBytes` (102400 bytes = 100 KB).
//    * CON-KEYSTROKE-RENDERING-UNDER-16MS-RECOVERY — the keystroke is always one
//      of idle / active / succeeded / failed / cancelled. A keystroke the surface
//      cannot lay out or draw is reported, the text buffer keeps the last valid
//      state for that keystroke, and the retry is explicit (the user types again);
//      nothing is retried automatically. The feature holds no task, stream, handle,
//      or delegate, and every terminal path that does not publish a keystroke
//      releases what it holds.
//
//  What exactly is measured
//  ------------------------
//  `insert(_:into:)` is the whole key-event handler: it validates the insertion
//  point, inserts the character through the text-input entry point AppKit uses for
//  a typed character, forces TextKit 2 layout of the document, and forces a drawing
//  pass of the surface's visible region. The clock starts immediately before that
//  edit and stops the instant the drawing pass returns — "key event to updated text
//  view drawing". The verification that the character really reached the buffer
//  (`inserted`) happens after the clock has stopped, because verification is not
//  rendering work.
//
//  What the document surface is
//  -----------------------------
//  `TextKit2DocumentView` is the `NSViewRepresentable` of the document surface: a
//  real `NSTextView` whose `textLayoutManager` is non-nil — genuinely TextKit 2, not
//  the compatibility path — wired to `AppState`'s document text, font, and colours.
//  It is handed to the app through `AppState.documentSurface()`.
//
//  Where the drawing goes
//  ----------------------
//  Inside a window the drawing pass is the surface's own display pass
//  (`needsDisplay` + `displayIfNeeded`), i.e. the window's drawing. Without a window
//  — the headless case, which is also how the measured proof runs — the drawing pass
//  rasterises the visible region into the surface's own offscreen buffer through
//  `cacheDisplay(in:to:)`. That is a real glyph rasterisation, not a "pretend draw":
//  the pixels of the visible region change when a character is inserted, and the
//  tests assert exactly that. The offscreen buffer is the surface's backing store and
//  is created by `prepareSurface(_:)` when the document surface appears, so a
//  keystroke never pays for it — a window's backing store exists before the first
//  keystroke for the same reason.
//
//  The first TextKit 2 layout of a document is document-opening work, not keystroke
//  work: `prepareSurface(_:)` performs it when the surface is created, exactly as
//  opening and displaying a note lays out the text the user is about to type into.
//  A keystroke then pays only for the layout its own edit invalidates.
//
//  ACC-KEYSTROKE-RENDERING-UNDER-16MS-03 — what is proved, and what is not
//  ---------------------------------------------------------------------
//  "No file read or write occurs on the main thread during keystroke handling" is
//  proved STRUCTURALLY, and the limitation is stated plainly:
//
//    * The keystroke path has no file operation to perform: `insert(_:into:)` takes a
//      character and a text view, no path, handle, or file parameter exists anywhere
//      in this file, and this feature has no injected file service at all. That is a
//      property of the code as written, enforced by the source scan in the focused
//      suite, and it holds because the whole path runs on the main actor — the main
//      actor cannot accidentally reach I/O it does not have.
//    * A source scan is not a runtime trace: it proves the published implementation
//      contains no file-I/O API, not that a future edit could not add one. The scan
//      is the guard against that edit; it is not evidence about code that does not
//      exist.
//    * The open-document buffer is in memory only
//      (CON-PERSISTENCE-OPEN-DOCUMENT-BUFFER): no keystroke ever writes the document
//      anywhere, which is why there is nothing for the main thread to write.
//
//  Invariants honoured here
//  ------------------------
//    * No network APIs and no third-party dependencies.
//    * No file I/O of any kind in this file: no path, handle, stream, or read/write
//      call, on any thread.
//    * `UserDefaults` is not reached from here.
//    * Reporting values never carry note contents, buffers, or file paths: the failure
//      text names the operation, never the document.
//    * A keystroke failure is not reported with a modal alert: an alert would interrupt
//      typing, and the contract asks for the failure to be logged and the last valid
//      buffer to be kept, so it is reported through a non-modal status message and the
//      explicit retry is the user typing the character again.
//

import AppKit
import Foundation
import SwiftUI

@MainActor
final class KeystrokeRenderingUnder16msFeature {

    // MARK: - Locked surface

    /// The locked keystroke budget, measured with `ContinuousClock`.
    nonisolated static let keystrokeBudget: Duration = .milliseconds(16)

    /// The same budget as a number so a real measured millisecond value can be
    /// compared against it directly.
    nonisolated static let budgetMilliseconds: Double = 16

    /// The locked document size the budget is measured against: 100 KB
    /// (ACC-KEYSTROKE-RENDERING-UNDER-16MS-02).
    nonisolated static let documentSizeForBudgetBytes: Int = 102_400

    /// One measured keystroke.
    struct Measurement: Equatable, Sendable {
        /// Time from the key event to the updated text view drawing.
        let milliseconds: Double

        /// `true` only when the inserted character is present in the text buffer.
        let inserted: Bool

        /// `true` only when the keystroke did not render and the text buffer is
        /// exactly the buffer it was before the keystroke: the failure behaviour of
        /// the interface contract ("leaves the text buffer unchanged for that
        /// keystroke"). A published keystroke reports `false`.
        let bufferUnchangedOnFailure: Bool

        /// `milliseconds` as a `Duration`, for a direct comparison against
        /// `keystrokeBudget`.
        let duration: Duration

        /// Whether TextKit 2 layout and a drawing pass of the updated text really
        /// ran for this keystroke.
        let drew: Bool

        /// Whether `cancel()` interrupted this keystroke while it was in flight. An
        /// interrupted keystroke is never published as a success.
        let cancelled: Bool

        /// Whether this keystroke was rendered inside the locked 16 ms budget. A
        /// keystroke that did not render never meets the rendering budget, whatever
        /// its duration.
        var metBudget: Bool {
            inserted
                && drew
                && cancelled == false
                && milliseconds < KeystrokeRenderingUnder16msFeature.budgetMilliseconds
        }
    }

    /// Why a keystroke was not rendered. Content-free: it names the condition, never
    /// the document.
    enum FailureReason: String, Sendable, Equatable {
        /// The insertion point is outside the text buffer.
        case insertionPointOutOfRange
        /// The interpreted text was empty, so there was no character to render.
        case nothingToInsert
        /// The document surface is not editable, so it accepts no keystroke.
        case documentNotEditable
        /// The surface is not a TextKit 2 surface (no text layout manager).
        case surfaceIsNotTextKit2
        /// The surface refused the insertion: the character never reached the buffer.
        case insertionRejected
        /// The character reached the buffer but TextKit 2 layout or the drawing pass
        /// failed, so the buffer was put back to the last valid state.
        case layoutFailed
    }

    /// The non-modal text a keystroke failure reports. It names no file, buffer, or
    /// note content, and it asks for the explicit user retry the recovery contract
    /// requires: typing the character again.
    static let failureStatusText: String =
        "The keystroke could not be rendered: the document surface could not lay out "
        + "or draw the updated text. The note is unchanged. Type the character again "
        + "to retry."

    // MARK: - Keystroke state (idle / active / succeeded / failed / cancelled)

    /// The keystroke operation state. Starts `.idle`: no keystroke has been handled.
    private(set) var keystrokeState: OperationState = .idle

    /// The most recent measurement, whatever its outcome.
    private(set) var lastMeasurement: Measurement?

    /// Whether the most recent *rendered* keystroke met the 16 ms budget; `nil` until
    /// a keystroke has been rendered. Reported separately from `keystrokeState`,
    /// because a surface that renders a keystroke slowly has rendered it.
    private(set) var lastKeystrokeMetBudget: Bool?

    /// Why the most recent keystroke was not rendered; `nil` after a rendered
    /// keystroke.
    private(set) var lastFailureReason: FailureReason?

    /// The non-modal explanation of the most recent failed keystroke; `nil` after a
    /// rendered keystroke and after an interruption (a cancellation is not an error).
    private(set) var lastStatusMessage: StatusMessage?

    /// The document text view the app handed over with `attach(_:)`. `nil` until a
    /// document surface has been created, and again after
    /// `releaseSurfaceResources()`.
    private(set) var documentTextView: NSTextView?

    // MARK: - Injected steps

    /// The TextKit 2 layout + drawing step, injected so the failure branch is
    /// exercised against a real `NSTextView` instead of pretending that AppKit
    /// failed. `nil` means the real step: `performTextKit2LayoutAndDraw(_:)`.
    private let injectedLayoutAndDraw: ((NSTextView) -> Bool)?

    /// - Parameter layoutAndDraw: the layout-and-drawing step of a keystroke. It
    ///   returns `false` when the surface could not lay out or draw the updated text,
    ///   which is the failure the recovery contract describes. The injected step
    ///   exists for the failure and cancellation branches; the default is the real
    ///   TextKit 2 step.
    init(layoutAndDraw: ((NSTextView) -> Bool)? = nil) {
        self.injectedLayoutAndDraw = layoutAndDraw
    }

    // MARK: - Surface ownership

    /// Takes ownership of the document text view the surface was built with, so the
    /// keystroke path renders into the same view the user sees. Idempotent, and safe
    /// to call with the view that is already attached.
    func attach(_ textView: NSTextView) {
        documentTextView = textView
    }

    /// Prepares a document surface for measured keystrokes: forces the first TextKit 2
    /// layout of the document and creates the surface's drawing buffer.
    ///
    /// Both are surface-creation work, not keystroke work — a document is laid out when
    /// it is opened and displayed, and a window's backing store exists before the first
    /// keystroke — so they are deliberately outside the measured keystroke window. A
    /// keystroke then pays only for the layout its own edit invalidates and for
    /// drawing the region it changed. Returns whether the surface is ready to render a
    /// keystroke.
    @discardableResult
    func prepareSurface(_ textView: NSTextView) -> Bool {
        documentTextView = textView

        guard let layoutManager = textView.textLayoutManager else {
            discardDrawingBuffer()
            return false
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        lastFullLayoutBounds = layoutManager.usageBoundsForTextContainer

        let visible = Self.drawingRect(of: textView)
        guard visible.width > 0, visible.height > 0,
              let buffer = textView.bitmapImageRepForCachingDisplay(in: visible) else {
            discardDrawingBuffer()
            return false
        }
        drawingBuffer = buffer
        drawingBufferSize = visible.size
        return true
    }

    /// Releases everything this feature retains: the document text view and the
    /// surface's drawing buffer. Called on the terminal path of the session
    /// (application termination), so nothing outlives the document. Interrupts a
    /// keystroke that is still in flight, because a keystroke cannot outlive its
    /// surface. Idempotent.
    func releaseSurfaceResources() {
        if keystrokeState == .active {
            keystrokeState = .cancelled
        }
        documentTextView = nil
        discardDrawingBuffer()
    }

    // MARK: - The measured keystroke path

    /// Handles one typed character at the caret: the whole key-event path, measured
    /// from the edit to the updated drawing.
    ///
    /// - Parameters:
    ///   - character: the character the key event produced (the interpreted text).
    ///   - textView: the document surface the character is typed into.
    /// - Returns: the measurement of this keystroke, including whether the character
    ///   reached the buffer and whether the buffer was left unchanged by a failure.
    @discardableResult
    func insert(_ character: String, into textView: NSTextView) -> Measurement {
        insert(character, into: textView, at: textView.selectedRange().location)
    }

    /// The same keystroke path with an explicit insertion point. The focused suite
    /// drives the rejected-insertion branch through this entry point (an insertion
    /// point outside the buffer), and the app uses the caret entry point above.
    @discardableResult
    func insert(_ character: String, into textView: NSTextView, at location: Int) -> Measurement {
        keystrokeState = .active
        lastStatusMessage = nil
        lastFailureReason = nil

        let before = textView.string
        let bufferLength = (before as NSString).length
        let insertedLength = (character as NSString).length
        let caret = NSRange(location: location, length: 0)
        let insertedRange = NSRange(location: location, length: insertedLength)

        // Validation: nothing below touches the buffer, so a rejected keystroke leaves
        // the last valid state exactly as it was.
        guard character.isEmpty == false, insertedLength > 0 else {
            return failure(
                textView: textView, before: before, reason: .nothingToInsert,
                duration: .zero, milliseconds: 0
            )
        }
        guard textView.isEditable, textView.isSelectable else {
            return failure(
                textView: textView, before: before, reason: .documentNotEditable,
                duration: .zero, milliseconds: 0
            )
        }
        guard location >= 0, location <= bufferLength else {
            return failure(
                textView: textView, before: before, reason: .insertionPointOutOfRange,
                duration: .zero, milliseconds: 0
            )
        }
        guard textView.textLayoutManager != nil else {
            return failure(
                textView: textView, before: before, reason: .surfaceIsNotTextKit2,
                duration: .zero, milliseconds: 0
            )
        }

        // The measured region: the key event's edit, the TextKit 2 layout of the text
        // that edit invalidated, and the drawing pass of the updated surface.
        let clock = ContinuousClock()
        let start = clock.now

        textView.insertText(character, replacementRange: caret)
        let drew = layoutAndDraw(textView)

        let duration = start.duration(to: clock.now)
        let milliseconds = Self.milliseconds(of: duration)

        // Verification, after the clock has stopped: the character really is in the
        // buffer, at the insertion point it was typed at.
        let after = textView.string
        let afterLength = (after as NSString).length
        let inserted = afterLength == bufferLength + insertedLength
            && insertedRange.location + insertedRange.length <= afterLength
            && (after as NSString).substring(with: insertedRange) == character

        if keystrokeState == .cancelled {
            // The application terminated while the keystroke was in flight. Nothing is
            // published: the buffer goes back to the last valid state.
            restore(textView, to: before, removing: insertedRange, inserted: inserted)
            let measurement = Measurement(
                milliseconds: milliseconds, inserted: false,
                bufferUnchangedOnFailure: textView.string == before,
                duration: duration, drew: drew, cancelled: true
            )
            lastMeasurement = measurement
            lastKeystrokeMetBudget = nil
            lastStatusMessage = nil
            return measurement
        }

        guard inserted, drew else {
            // CON-KEYSTROKE-RENDERING-UNDER-16MS-RECOVERY: the failure is reported, the
            // buffer keeps the last valid state for this keystroke, and the retry is
            // explicit.
            restore(textView, to: before, removing: insertedRange, inserted: inserted)
            return failure(
                textView: textView, before: before,
                reason: inserted ? .layoutFailed : .insertionRejected,
                duration: duration, milliseconds: milliseconds, drew: drew
            )
        }

        let measurement = Measurement(
            milliseconds: milliseconds, inserted: true,
            bufferUnchangedOnFailure: false,
            duration: duration, drew: true, cancelled: false
        )
        lastMeasurement = measurement
        keystrokeState = evaluate(measurement)
        lastKeystrokeMetBudget = Self.meetsBudget(measurement)
        return measurement
    }

    // MARK: - Evaluation and reporting

    /// The operation state of a measured keystroke: `.succeeded` when the character
    /// was inserted and the updated text was laid out and drawn, `.cancelled` when the
    /// attempt was interrupted, `.failed` otherwise. The 16 ms budget is reported
    /// separately by `meetsBudget(_:)` and `lastKeystrokeMetBudget`, so a surface that
    /// renders a keystroke slowly is never reported as a keystroke that did not render.
    func evaluate(_ measurement: Measurement) -> OperationState {
        if measurement.cancelled { return .cancelled }
        return measurement.inserted && measurement.drew ? .succeeded : .failed
    }

    /// Whether a measured keystroke met the locked 16 ms budget. A keystroke that did
    /// not render never met it, whatever its duration.
    static func meetsBudget(_ measurement: Measurement) -> Bool {
        measurement.inserted
            && measurement.drew
            && measurement.cancelled == false
            && measurement.milliseconds < budgetMilliseconds
    }

    /// The number of milliseconds a `Duration` spans.
    nonisolated static func milliseconds(of duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    // MARK: - Cancellation

    /// Interrupts a keystroke that is still in flight, e.g. because the application is
    /// terminating while a key event is being handled. Nothing about the attempt is
    /// published as a success: it becomes `.cancelled`, the buffer keeps the last valid
    /// state, and — because an interruption is not an error — no failure is reported.
    /// Returns whether an in-flight keystroke was actually interrupted.
    @discardableResult
    func cancel() -> Bool {
        guard keystrokeState == .active else { return false }
        keystrokeState = .cancelled
        return true
    }

    // MARK: - Rendering steps

    /// Runs the layout and drawing step of a keystroke: the injected step when one was
    /// supplied, otherwise the real TextKit 2 step. Runs inside the measured window.
    private func layoutAndDraw(_ textView: NSTextView) -> Bool {
        if let injected = injectedLayoutAndDraw {
            return injected(textView)
        }
        return performTextKit2LayoutAndDraw(textView)
    }

    /// The real step: force the TextKit 2 layout of everything this keystroke
    /// invalidated and draw the updated surface.
    ///
    /// TextKit 2 layout is what "lays out the updated text" means here, and
    /// `usageBoundsForTextContainer` is read back afterwards, so a layout that produced
    /// nothing is reported as a failure rather than as a rendered keystroke. Drawing is
    /// the window's display pass when the surface is in a window, and a real
    /// rasterisation of the visible region into the surface's own buffer when it is not
    /// (a headless surface, which is how the measured proof runs).
    private func performTextKit2LayoutAndDraw(_ textView: NSTextView) -> Bool {
        guard let layoutManager = textView.textLayoutManager else { return false }

        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let laidOut = layoutManager.usageBoundsForTextContainer
        guard laidOut.height > 0 || laidOut.width > 0 else { return false }

        if textView.window != nil {
            textView.needsDisplay = true
            textView.displayIfNeeded()
            return true
        }
        return drawVisibleRegion(textView)
    }

    /// The headless drawing pass: rasterise the visible region of the surface into the
    /// surface's own drawing buffer. `cacheDisplay(in:to:)` is a real drawing pass — the
    /// pixels of the region change when the text changes — which is what makes the
    /// "updated text view drawing" half of the measurement checkable.
    private func drawVisibleRegion(_ textView: NSTextView) -> Bool {
        let visible = Self.drawingRect(of: textView)
        guard visible.width > 0, visible.height > 0 else { return false }

        let buffer: NSBitmapImageRep
        if let cached = drawingBuffer, drawingBufferSize == visible.size {
            buffer = cached
        } else if let fresh = textView.bitmapImageRepForCachingDisplay(in: visible) {
            // The visible region changed size (a resize, not a keystroke): the
            // surface's buffer is resized with it.
            drawingBuffer = fresh
            drawingBufferSize = visible.size
            buffer = fresh
        } else {
            return false
        }

        textView.cacheDisplay(in: visible, to: buffer)
        return buffer.bitmapData != nil
    }

    // MARK: - Private

    /// The region a drawing pass rasterises: the visible region when the surface has a
    /// real one, otherwise the surface's own bounds.
    ///
    /// `NSView.visibleRect` is meaningful for a view inside a clip view — which is how
    /// the document surface lives in a window — and is a "no viewport" sentinel for a
    /// bare view, so it is only used when it is finite and of a drawable size. The size
    /// is also bounded: a surface cannot ask for a bitmap larger than a screen's worth
    /// of text, whatever a caller has configured.
    static func drawingRect(of textView: NSTextView) -> NSRect {
        let maximumEdge: CGFloat = 100_000
        let visible = textView.visibleRect
        if visible.width.isFinite, visible.height.isFinite,
           visible.width > 0, visible.height > 0,
           visible.width <= maximumEdge, visible.height <= maximumEdge {
            return visible
        }
        return textView.bounds
    }

    /// The surface's drawing buffer — the bitmap the headless drawing pass rasterises the
    /// visible region into — and the visible size it was created for. Readable so a
    /// caller can verify that the drawing pass really produced pixels of the updated
    /// text; `nil` before `prepareSurface(_:)` and after
    /// `releaseSurfaceResources()`.
    private(set) var drawingBuffer: NSBitmapImageRep?

    private var drawingBufferSize: NSSize = .zero

    /// The laid-out bounds of the document after the last full layout, kept so a
    /// caller can see that the surface really has laid-out text.
    private(set) var lastFullLayoutBounds: CGRect = .zero

    private func discardDrawingBuffer() {
        drawingBuffer = nil
        drawingBufferSize = .zero
    }

    /// Shapes a non-rendered keystroke: the state becomes `.failed`, the failure is
    /// explained non-modally, and the measurement reports that the buffer kept the
    /// buffer it had before the keystroke.
    private func failure(
        textView: NSTextView,
        before: String,
        reason: FailureReason,
        duration: Duration,
        milliseconds: Double,
        drew: Bool = false
    ) -> Measurement {
        keystrokeState = .failed
        lastFailureReason = reason
        lastStatusMessage = StatusMessage(text: Self.failureStatusText, isFailure: true)

        let measurement = Measurement(
            milliseconds: milliseconds,
            inserted: false,
            bufferUnchangedOnFailure: textView.string == before,
            duration: duration,
            drew: drew,
            cancelled: false
        )
        lastMeasurement = measurement
        lastKeystrokeMetBudget = nil
        return measurement
    }

    /// Puts the buffer back to the last valid state: exactly the characters this
    /// keystroke added are removed, and the surface is asked to redraw, so a failure
    /// leaves neither a stray character nor a stale picture.
    private func restore(
        _ textView: NSTextView,
        to before: String,
        removing insertedRange: NSRange,
        inserted: Bool
    ) {
        if inserted {
            textView.insertText("", replacementRange: insertedRange)
        }
        if textView.string != before {
            textView.string = before
        }
        textView.needsDisplay = true
    }
}

// MARK: - The TextKit 2 document surface

/// The document surface: a SwiftUI view wrapping a real TextKit 2 `NSTextView`,
/// wired to the document text, the configured monospace font, and the
/// contrast-checked colours.
///
/// The text view it creates is genuinely TextKit 2 — `NSTextView(usingTextLayoutManager:)`
/// — so `textView.textLayoutManager` is non-nil and the keystroke path lays out and
/// draws through TextKit 2 rather than the compatibility path.
///
/// Typed characters are routed to the app's own keystroke path instead of AppKit's
/// default insertion: `handleKeystroke` receives the interpreted text and the text
/// view, and when the app is the one that renders keystrokes, the surface returns
/// `false` from the text-view delegate so the character is inserted exactly once —
/// through the measured path. A keystroke that path does not render is not inserted
/// by AppKit either, which is what keeps "a layout failure leaves the text buffer
/// unchanged for that keystroke" true on the surface the user types into.
///
/// No file access is possible from here: the surface carries document text, a font,
/// colours, and two closures — no path, handle, or file parameter of any kind.
struct TextKit2DocumentView: NSViewRepresentable {

    /// The document text the surface renders (the open in-memory buffer,
    /// CON-DATA-OPEN-DOCUMENT-BUFFER — never written to disk).
    let text: String

    /// The configured monospace font.
    let font: NSFont

    /// The contrast-checked text foreground colour.
    let textColor: NSColor

    /// The window/document background colour.
    let backgroundColor: NSColor

    /// Whether the surface accepts keystrokes.
    let isEditable: Bool

    /// The stable accessibility label of the document surface.
    let accessibilityLabel: String

    /// Reports a keystroke AppKit is about to apply to the document surface, as the
    /// interpreted text and the surface's text view. When a handler is installed the
    /// surface gives up its own insertion, so the app's measured keystroke path is the
    /// only path that inserts a character — whether or not that path rendered it.
    let handleKeystroke: ((String, NSTextView) -> Bool)?

    /// Called once with the text view the surface was built with, so the app's
    /// keystroke path can render into the surface the user is typing into.
    let onDocumentTextViewReady: ((NSTextView) -> Void)?

    /// Reports an edit AppKit applied itself (a deletion, a selection replacement, cut,
    /// or undo/redo), so the app's buffer follows the surface.
    let onTextChange: ((NSTextView) -> Void)?

    /// The default accessibility label of the document surface.
    static let defaultAccessibilityLabel: String = "Note text"

    init(
        text: String,
        font: NSFont,
        textColor: NSColor,
        backgroundColor: NSColor,
        isEditable: Bool,
        accessibilityLabel: String = TextKit2DocumentView.defaultAccessibilityLabel,
        handleKeystroke: ((String, NSTextView) -> Bool)? = nil,
        onDocumentTextViewReady: ((NSTextView) -> Void)? = nil,
        onTextChange: ((NSTextView) -> Void)? = nil
    ) {
        self.text = text
        self.font = font
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.isEditable = isEditable
        self.accessibilityLabel = accessibilityLabel
        self.handleKeystroke = handleKeystroke
        self.onDocumentTextViewReady = onDocumentTextViewReady
        self.onTextChange = onTextChange
    }

    /// The surface for an `AppState`: the document buffer, the resolved monospace
    /// font, the contrast-checked foreground, the #000000 background, and the
    /// editability of the launch, with keystrokes routed to `AppState`'s keystroke
    /// path.
    ///
    /// - Parameter onDocumentTextViewReady: called once with the surface's text view
    ///   when the surface is created. The composition root uses it to hand the view to
    ///   the keystroke path.
    init(state: AppState, onDocumentTextViewReady: ((NSTextView) -> Void)? = nil) {
        self.init(
            text: state.documentText,
            font: state.documentFont,
            textColor: state.documentTextColor,
            backgroundColor: state.windowBackgroundColor,
            isEditable: state.isEditable,
            accessibilityLabel: Self.defaultAccessibilityLabel,
            handleKeystroke: { character, _ in state.handleKeystrokeInsert(character) },
            onDocumentTextViewReady: onDocumentTextViewReady,
            onTextChange: { textView in state.handleDirectEdit(in: textView) }
        )
    }

    // MARK: - NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = Self.makeDocumentTextView(
            text: text,
            font: font,
            textColor: textColor,
            backgroundColor: backgroundColor,
            isEditable: isEditable,
            accessibilityLabel: accessibilityLabel
        )
        // Handed over before the delegate is attached, so the launch's keystroke probe
        // stays on the surface and never reaches the document buffer.
        onDocumentTextViewReady?(textView)
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = backgroundColor
        scrollView.documentView = textView
        textView.textContainer?.widthTracksTextView = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        scrollView.backgroundColor = backgroundColor
        guard let textView = scrollView.documentView as? NSTextView else { return }
        Self.apply(
            text: text,
            font: font,
            textColor: textColor,
            backgroundColor: backgroundColor,
            isEditable: isEditable,
            accessibilityLabel: accessibilityLabel,
            to: textView
        )
    }

    /// The document surface takes the room it is offered. A vertically resizable text view
    /// otherwise reports the height of a single line as its ideal size, which would leave
    /// the document surface one line tall in the window it is presented in.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        guard width.isFinite, height.isFinite else { return nil }
        return CGSize(width: max(width, 1), height: max(height, 1))
    }

    // MARK: - The text view itself

    /// Builds the document text view: a real TextKit 2 `NSTextView` carrying the
    /// document text, the configured font, the resolved colours, and a stable
    /// accessibility label and role.
    ///
    /// The view is configured the way a text view inside a scroll view is (it grows
    /// vertically and its viewport follows the caret through
    /// `scrollRangeToVisible(_:)`), so a window or a scroll view hosting it scrolls to
    /// where the user is typing while the keystroke path lays out and draws what is
    /// visible.
    @discardableResult
    static func makeDocumentTextView(
        text: String,
        font: NSFont,
        textColor: NSColor,
        backgroundColor: NSColor,
        isEditable: Bool,
        accessibilityLabel: String = TextKit2DocumentView.defaultAccessibilityLabel,
        frame: NSRect = NSRect(x: 0, y: 0, width: 960, height: 640)
    ) -> NSTextView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.allowsUndo = true
        // Plain text is saved exactly as typed: no curly quotes, en dashes or replacements.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.frame = frame

        apply(
            text: text,
            font: font,
            textColor: textColor,
            backgroundColor: backgroundColor,
            isEditable: isEditable,
            accessibilityLabel: accessibilityLabel,
            to: textView
        )
        return textView
    }

    /// Writes the surface's values onto a text view. This is the body both
    /// `makeNSView` and `updateNSView` run, so the surface a keystroke renders into and
    /// the surface SwiftUI updates are configured by the same code.
    ///
    /// The document text is only written when it differs, and the caret is clamped to
    /// the new buffer rather than reset, so an update never moves the insertion point
    /// out from under the user.
    static func apply(
        text: String,
        font: NSFont,
        textColor: NSColor,
        backgroundColor: NSColor,
        isEditable: Bool,
        accessibilityLabel: String = TextKit2DocumentView.defaultAccessibilityLabel,
        to textView: NSTextView
    ) {
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = backgroundColor
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.font = font
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.setAccessibilityRole(.textArea)

        if textView.string != text {
            let caret = textView.selectedRange().location
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(caret, length), length: 0))
        }
        textView.needsDisplay = true
    }

    // MARK: - Keystroke routing

    /// Routes a keystroke to the app's measured keystroke path.
    ///
    /// `textView(_:shouldChangeTextIn:replacementString:)` is consulted for typed
    /// characters — including the app's own `insertText(_:replacementRange:)` call,
    /// which is why re-entry is guarded here. The handler runs exactly once per
    /// keystroke and the surface never applies its own insertion on top of it.
    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        /// The surface this coordinator serves. Updated by `updateNSView(_:context:)`.
        var parent: TextKit2DocumentView

        /// `true` while the app's own measured insertion is being applied, so the
        /// delegate call that insertion produces is not routed back into the handler.
        private(set) var isApplyingMeasuredKeystroke = false

        /// How many keystrokes were routed to the app's keystroke path.
        private(set) var routedKeystrokeCount = 0

        init(parent: TextKit2DocumentView) {
            self.parent = parent
            super.init()
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard let replacement = replacementString, let handle = parent.handleKeystroke else {
                // No keystroke path is installed: AppKit inserts the character itself.
                return true
            }
            guard isApplyingMeasuredKeystroke == false else {
                // Re-entry: the app's keystroke path is inserting the character it has
                // already accounted for.
                return true
            }
            let caret = textView.selectedRange()
            guard replacement.isEmpty == false,
                  affectedCharRange.length == 0,
                  affectedCharRange.location == caret.location,
                  caret.length == 0 else {
                // Deletions, selection replacements, cut, and undo/redo away from the caret
                // are applied by AppKit; `textDidChange(_:)` reports them to the app.
                return true
            }

            isApplyingMeasuredKeystroke = true
            defer { isApplyingMeasuredKeystroke = false }
            routedKeystrokeCount += 1
            _ = handle(replacement, textView)

            // The app owns keystroke insertion: exactly one insertion happens, through
            // the path that measured it. A keystroke that path did not render is left
            // unrendered rather than inserted behind its back.
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard isApplyingMeasuredKeystroke == false,
                  let textView = notification.object as? NSTextView else { return }
            parent.onTextChange?(textView)
        }
    }
}
