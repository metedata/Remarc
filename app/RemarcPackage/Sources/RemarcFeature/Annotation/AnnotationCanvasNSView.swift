import AppKit
import Combine
import CoreGraphics

/// Editor-only measurements, in source pixels, recomputed on every zoom change.
///
/// Two axes, not one: the viewport carries independent X and Y scales because the
/// captured image is never assumed to have exactly the selection's aspect ratio.
/// **Mark geometry never converts through here.**
public struct ChromeMetrics: Equatable, Sendable {
    public var hitTolerance: CGFloat
    public var handleRadius: CGFloat
    public var borderWidth: CGFloat

    /// - Parameter stageScale: displayed points per source pixel, per axis.
    ///
    ///   NOT derived from `AnnotationViewport`. The canvas pins `bounds` to
    ///   `pixelSize` on every path, which is the whole coordinate contract, so the
    ///   viewport's scale is identically 1 and chrome derived from it never
    ///   changed: hit tolerance stayed 6 SOURCE pixels, which at 4x is 1.5 points
    ///   on screen - about a fifth of what a pointer can reliably hit.
    public static func make(stageScale: CGSize) -> ChromeMetrics {
        let mean = max((stageScale.width + stageScale.height) / 2, 0.0001)
        // Constants are in on-screen points; dividing converts them to the source
        // pixels every hit test and stroke actually uses.
        return ChromeMetrics(hitTolerance: 6 / mean,
                             handleRadius: 4 / mean,
                             borderWidth: 2 / mean)
    }
}

/// The drawing surface.
///
/// Flipped, so its local coordinate system IS source-image pixels with a top-left
/// origin. `canvas.convert(event.locationInWindow, from: nil)` therefore yields
/// source pixels directly, with no zoom arithmetic anywhere on the input path,
/// which is what makes it impossible for zoom to corrupt stored geometry.
@MainActor
public final class AnnotationCanvasNSView: NSView {

    public weak var session: AnnotationSession?
    /// Called when the canvas wants the surrounding UI to refresh (tool changed by
    /// shortcut, selection changed, dirty state changed).
    public var onStateChange: (() -> Void)?
    /// Escape reached the canvas with nothing of its own to resolve.
    public var onEscape: (() -> Void)?

    /// A session constant, independent of backing, so `AnnotationViewport` is
    /// bit-identical for the life of the session.
    private let pixelSize: CGSize

    private var cancellables: Set<AnyCancellable> = []
    /// Text is typed straight onto the image, with no field and no box.
    ///
    /// An `NSTextField` overlay meant a white rectangle sitting on the picture at a
    /// size that had nothing to do with the text, and it clipped at the image edge.
    /// Keystrokes go into the session's pending label instead, the live patch draws
    /// it in real ink at the exact size and position it will export at, and the only
    /// chrome is a caret.
    private var isTypingText = false
    private var caretVisible = true
    private var caretTimer: Timer?

    /// Whether the parent should draw the selection border. The canvas draws it
    /// itself, after its rasters, because the parent draws first and its stroke's
    /// inner half would be covered.
    public var drawsSelectionBorder = true
    public var isInputEnabled = true

    // Gesture state. Editor-only: never exported, never checkpointed.
    private enum Gesture {
        case none
        case drawing(start: CGPoint, points: [CGPoint])
        case moving(id: UUID, original: AnnotationItem, grab: CGPoint)
    }
    private var gesture: Gesture = .none

    /// Bumped on every gesture start and end. A live-patch render that completes
    /// after its gesture is over carries a stale id and is dropped, so an abandoned
    /// stroke cannot stay painted over the composite.
    private var gestureToken = 0

    /// Union of everything the current gesture has touched.
    ///
    /// A patch replaces its rect wholesale, so patching only the newest segment
    /// showed a freehand stroke one segment at a time with the rest erased. The
    /// region accumulates instead, and `patchInFlight` coalesces so a long stroke
    /// does not queue a render per mouse event.
    private var liveDirtyRegion: CGRect = .null
    private var patchInFlight = false

    public init(pixelSize: CGSize, session: AnnotationSession) {
        self.pixelSize = pixelSize
        self.session = session
        super.init(frame: CGRect(origin: .zero, size: pixelSize))
        bounds = CGRect(origin: .zero, size: pixelSize)
        observe(session)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    /// **The re-assertion is the whole coordinate contract.**
    ///
    /// Setting `bounds` to a size different from `frame` does not pin the
    /// coordinate system; it records a *scale factor* AppKit then preserves across
    /// subsequent frame changes. Measured: `bounds = 400x160` while `frame =
    /// 200x80` records a 2x factor, and setting `frame = 800x320` afterwards gives
    /// `bounds = 1600x640`. Without this override the canvas coordinate system is
    /// multiplied by the zoom on every step and every stored coordinate is wrong by
    /// that factor.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        bounds.size = pixelSize
        syncDisplayScale()
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        // Guard against anything else in AppKit resizing bounds out from under the
        // contract.
        super.setBoundsSize(pixelSize)
    }

    private func observe(_ session: AnnotationSession) {
        session.objectWillChange
            // DispatchQueue.main, NOT RunLoop.main. RunLoop.main only delivers in
            // the run loop's default mode, and a mouse drag runs it in
            // .eventTracking - so every live patch published mid-drag was held
            // until the user released the button and the stroke appeared only
            // after they stopped drawing.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.needsDisplay = true
                self?.onStateChange?()
            }
            .store(in: &cancellables)
    }

    public var viewport: AnnotationViewport {
        AnnotationViewport(pixelSize: pixelSize, canvasBounds: bounds)
    }

    /// Displayed points per source pixel, straight from the frame-to-bounds ratio.
    public var stageScale: CGSize {
        CGSize(width: bounds.width > 0 ? frame.width / bounds.width : 1,
               height: bounds.height > 0 ? frame.height / bounds.height : 1)
    }

    public var chrome: ChromeMetrics { ChromeMetrics.make(stageScale: stageScale) }

    // MARK: - Interpolation

    /// Device pixels per source pixel.
    ///
    /// The canvas's local unit is already one source pixel, so this is a **direct**
    /// conversion of a unit size. Passing `stageScale` here instead would yield
    /// roughly `backingScale * stageScale²`, because the local unit is a source
    /// pixel and not a point.
    private var devicePixelsPerSourcePixel: NSSize {
        convertToBacking(NSSize(width: 1, height: 1))
    }

    private var interpolation: NSImageInterpolation {
        let q = devicePixelsPerSourcePixel
        // Nearest-neighbour only at a true 1:1 pixel view, where it is exact and
        // meaningful. Magnified, the composite is already rendered at the display's
        // device-pixel ratio, so `.high` here only smooths the base image, which
        // has no more detail to give at any setting. The earlier `>= 1` form used
        // nearest at every zoom above 1:1 and made the whole stage look blocky.
        let isOneToOne = abs(q.width - 1) < 0.01 && abs(q.height - 1) < 0.01
        return isOneToOne ? .none : .high
    }

    /// Keeps the composite's render resolution in step with what is on screen.
    private func syncDisplayScale() {
        let q = devicePixelsPerSourcePixel
        session?.setDisplayScale(max(q.width, q.height))
    }

    // MARK: - Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.imageInterpolation = interpolation

        let full = CGRect(origin: .zero, size: pixelSize)

        if let composite = session?.composite {
            ctx.cgContext.draw(flipped: composite, in: full)
        } else if let source = session?.source {
            ctx.cgContext.draw(flipped: source, in: full)
        }

        // Copy semantics, not source-over: the patch is an opaque REPLACEMENT of
        // its rect. Compositing it over would leave the old pixels of a moved or
        // deleted mark visible underneath until the full render landed, and a
        // deletion would have nothing to draw at all.
        if let patch = session?.patch {
            ctx.saveGraphicsState()
            ctx.compositingOperation = .copy
            ctx.cgContext.draw(flipped: patch.image, in: patch.rect)
            ctx.restoreGraphicsState()
        }

        drawSelectionChrome(ctx.cgContext)
        drawTextCaret(ctx.cgContext)
        if drawsSelectionBorder { drawBorder(ctx.cgContext, in: full) }
    }

    private func drawBorder(_ ctx: CGContext, in rect: CGRect) {
        let width = chrome.borderWidth
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
        ctx.setLineWidth(width)
        ctx.stroke(rect.insetBy(dx: width / 2, dy: width / 2))
    }

    private func drawSelectionChrome(_ ctx: CGContext) {
        guard let session, let id = session.selectedItemID,
              let item = session.items.first(where: { $0.id == id }) else { return }
        let metrics = chrome
        let box = item.bounds.insetBy(dx: -metrics.handleRadius * 1.5,
                                      dy: -metrics.handleRadius * 1.5)
        ctx.setStrokeColor(CGColor(srgbRed: 0.15, green: 0.47, blue: 0.95, alpha: 0.9))
        ctx.setLineWidth(metrics.borderWidth * 0.75)
        ctx.setLineDash(phase: 0, lengths: [metrics.handleRadius, metrics.handleRadius])
        ctx.stroke(box)
        ctx.setLineDash(phase: 0, lengths: [])
    }

    // MARK: - Cursor

    public override func resetCursorRects() {
        discardCursorRects()
        guard isInputEnabled else { return }
        addCursorRect(bounds, cursor: session?.tool == .select ? .arrow : .crosshair)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // The interpolation measurement, the chrome metrics, and the composite's
        // render resolution all change; the viewport does not, by construction.
        syncDisplayScale()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Input

    public override var acceptsFirstResponder: Bool { isInputEnabled }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A drag on the canvas draws; it never moves the host window.
    ///
    /// `NSView`'s default returns true for a non-opaque view, and the preview
    /// panel sets `isMovableByWindowBackground`. AppKit consults this BEFORE
    /// dispatching `mouseDown(with:)`, so the window began dragging and the
    /// canvas never saw the gesture at all - every mark drawn from a saved
    /// comment's image was lost to a window move. Unconditional rather than
    /// keyed to `isInputEnabled`: a frozen canvas should swallow the drag, not
    /// hand it to the window.
    public override var mouseDownCanMoveWindow: Bool { false }

    private func sourcePoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(local.x, 0), pixelSize.width),
                       y: min(max(local.y, 0), pixelSize.height))
    }

    public override func mouseDown(with event: NSEvent) {
        guard isInputEnabled, let session, !session.isFrozen else { return }
        // A click while typing commits what is there, then acts normally.
        commitTypedText()
        let point = sourcePoint(event)

        switch session.tool {
        case .select:
            gestureToken &+= 1
            if let hit = session.hitTest(point, tolerance: chrome.hitTolerance) {
                session.selectedItemID = hit.id
                gesture = .moving(id: hit.id, original: hit, grab: point)
            } else {
                session.selectedItemID = nil
                gesture = .none
            }
        case .text:
            session.selectedItemID = nil
            beginTypingText(at: point)
        case .counter:
            session.selectedItemID = nil
            session.add(AnnotationItem(
                payload: .counter(session.counterSeed, at: point,
                                  radius: session.stroke.rawValue * 2.4),
                ink: session.ink, strokeWidth: session.stroke.rawValue))
        default:
            session.selectedItemID = nil
            gestureToken &+= 1
            liveDirtyRegion = .null
            gesture = .drawing(start: point, points: [point])
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isInputEnabled, let session, !session.isFrozen else { return }
        let point = sourcePoint(event)

        switch gesture {
        case .drawing(let start, var points):
            points.append(point)
            gesture = .drawing(start: start, points: points)
            if let preview = makeItem(tool: session.tool, start: start, current: point,
                                      points: points, session: session) {
                liveDirtyRegion = liveDirtyRegion.isNull
                    ? preview.bounds
                    : liveDirtyRegion.union(preview.bounds)
                schedulePatch(region: liveDirtyRegion, preview: preview, session: session)
            }
        case .moving(let id, let original, let grab):
            let offset = CGPoint(x: point.x - grab.x, y: point.y - grab.y)
            var moved = original
            moved.payload = original.payload.translated(by: offset)
            // No checkpoint per drag event: the checkpoint is taken once, on mouse
            // up, so one drag is one undo step.
            session.replace(id: id, with: moved, checkpoint: false)
        case .none:
            break
        }
        needsDisplay = true
    }

    /// One render at a time. Extra drag events during a render are dropped rather
    /// than queued: the next one carries the accumulated region anyway, so nothing
    /// is lost and a fast stroke cannot build a backlog.
    private func schedulePatch(region: CGRect, preview: AnnotationItem,
                               session: AnnotationSession) {
        guard !patchInFlight else { return }
        patchInFlight = true
        let token = gestureToken
        Task { [weak self] in
            await session.setLivePatch(region: region, extraItems: [preview])
            guard let self else { return }
            self.patchInFlight = false
            if self.gestureToken != token {
                // The gesture ended while this was rendering.
                session.clearLivePatch()
            }
            // Explicit: the Combine sink is a fallback, and during .eventTracking
            // the redraw has to be asked for directly.
            self.needsDisplay = true
            self.displayIfNeeded()
        }
    }

    public override func mouseUp(with event: NSEvent) {
        guard isInputEnabled, let session, !session.isFrozen else { return }
        let point = sourcePoint(event)

        switch gesture {
        case .drawing(let start, var points):
            points.append(point)
            liveDirtyRegion = .null
            session.clearLivePatch()
            if let item = makeItem(tool: session.tool, start: start, current: point,
                                   points: points, session: session) {
                session.add(item)
            }
        case .moving(let id, let original, let grab):
            let offset = CGPoint(x: point.x - grab.x, y: point.y - grab.y)
            // A click that only selects is not an edit. Without this a bare click
            // pushed an undo step and marked the document dirty, which then made
            // Escape demand a discard decision for changes nobody made.
            guard abs(offset.x) > 0.5 || abs(offset.y) > 0.5 else { break }
            var moved = original
            moved.payload = original.payload.translated(by: offset)
            // Restore, then re-apply through a checkpointing mutation, so the undo
            // step lands on the pre-drag state exactly once.
            session.replace(id: id, with: original, checkpoint: false)
            session.replace(id: id, with: moved, checkpoint: true)
        case .none:
            break
        }
        gesture = .none
        gestureToken &+= 1
        needsDisplay = true
    }

    /// A gesture too small to be intentional produces nothing, so a stray click
    /// does not leave an invisible zero-length mark in the document.
    private func makeItem(tool: AnnotationTool, start: CGPoint, current: CGPoint,
                          points: [CGPoint], session: AnnotationSession) -> AnnotationItem? {
        let width = session.stroke.rawValue
        let box = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                         width: abs(current.x - start.x), height: abs(current.y - start.y))
        let minimum = max(width, 3)

        switch tool {
        case .arrow:
            guard hypot(current.x - start.x, current.y - start.y) > minimum else { return nil }
            return AnnotationItem(payload: .arrow(from: start, to: current,
                                                  style: session.arrowStyle),
                                  ink: session.ink, strokeWidth: width)
        case .line:
            guard hypot(current.x - start.x, current.y - start.y) > minimum else { return nil }
            return AnnotationItem(payload: .line(from: start, to: current),
                                  ink: session.ink, strokeWidth: width)
        case .rect:
            guard box.width > minimum, box.height > minimum else { return nil }
            return AnnotationItem(payload: .rect(box), ink: session.ink, strokeWidth: width)
        case .oval:
            guard box.width > minimum, box.height > minimum else { return nil }
            return AnnotationItem(payload: .oval(box), ink: session.ink, strokeWidth: width)
        case .blur:
            guard box.width > minimum, box.height > minimum else { return nil }
            return AnnotationItem(payload: .blur(box), ink: session.ink, strokeWidth: width)
        case .pixelate:
            guard box.width > minimum, box.height > minimum else { return nil }
            return AnnotationItem(payload: .pixelate(box), ink: session.ink, strokeWidth: width)
        case .freehand:
            guard points.count > 1 else { return nil }
            return AnnotationItem(payload: .freehand(points: points),
                                  ink: session.ink, strokeWidth: width)
        case .highlighter:
            guard points.count > 1 else { return nil }
            return AnnotationItem(payload: .highlighter(points: points),
                                  ink: .highlighter, strokeWidth: width * 3)
        case .select, .text, .counter:
            return nil
        }
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        guard isInputEnabled, let session else { return super.keyDown(with: event) }

        // Typing consumes everything unmodified, so a label containing "arrow" does
        // not switch tools halfway through the word.
        if handleTypingKey(event) { return }

        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z":
                event.modifierFlags.contains(.shift) ? session.redo() : session.undo()
                needsDisplay = true
                return
            default:
                return super.keyDown(with: event)
            }
        }

        switch event.keyCode {
        case 51, 117:   // delete, forward delete
            session.deleteSelected()
            needsDisplay = true
            return
        default:
            break
        }

        // Unmodified letters are tool shortcuts here, and only here. The comment
        // text view keeps its own keys: the canvas is only first responder while
        // annotation is active.
        if let shortcut = event.charactersIgnoringModifiers?.lowercased(),
           let tool = Self.tool(forShortcut: shortcut) {
            session.tool = tool
            window?.invalidateCursorRects(for: self)
            onStateChange?()
            return
        }
        super.keyDown(with: event)
    }

    public static func tool(forShortcut key: String) -> AnnotationTool? {
        switch key {
        case "v": return .select
        case "a": return .arrow      // `A` is arrow, per the control table
        case "l": return .line
        case "r": return .rect
        case "o": return .oval
        case "p": return .freehand
        case "h": return .highlighter
        case "t": return .text
        case "c": return .counter
        case "b": return .blur
        case "x": return .pixelate
        default: return nil
        }
    }

    public override func cancelOperation(_ sender: Any?) {
        if isTypingText {
            // One layer per invocation: cancel the edit and stop. Nothing further
            // happens on this keystroke.
            cancelTypedText()
            return
        }
        onEscape?()
    }

    // MARK: - Inline text field

    private func beginTypingText(at point: CGPoint) {
        guard let session else { return }
        let pointSize = session.stroke.rawValue * 4
        session.beginText(at: point, pointSize: pointSize)
        isTypingText = true
        liveDirtyRegion = .null
        gestureToken &+= 1
        // The session can be asked for the live string by an output path that never
        // routes back through this view.
        session.liveTextProvider = { [weak session] in session?.pendingText?.string }
        startCaretBlink()
        refreshTypingPreview()
    }

    /// Draws the in-progress label through the same renderer the export uses, so
    /// what is on screen while typing is exactly what lands in the file.
    private func refreshTypingPreview() {
        guard let session, let pending = session.pendingText else { return }
        let preview = AnnotationItem(
            payload: .text(pending.string, at: pending.at, pointSize: pending.pointSize),
            ink: session.ink, strokeWidth: session.stroke.rawValue)
        // Union, not replace: deleting a character shrinks the text, and the region
        // has to still cover where the removed glyphs were in order to erase them.
        liveDirtyRegion = liveDirtyRegion.isNull
            ? preview.bounds
            : liveDirtyRegion.union(preview.bounds)
        schedulePatch(region: liveDirtyRegion, preview: preview, session: session)
        needsDisplay = true
    }

    private func commitTypedText() {
        guard isTypingText, let session else { return }
        endTyping()
        try? session.commitActiveEditForOutput()
    }

    private func cancelTypedText() {
        guard isTypingText, let session else { return }
        endTyping()
        session.resolveActiveEdit(for: .escape)
    }

    private func endTyping() {
        isTypingText = false
        stopCaretBlink()
        liveDirtyRegion = .null
        gestureToken &+= 1
        session?.liveTextProvider = nil
        session?.clearLivePatch()
        needsDisplay = true
    }

    /// Typed characters, in the same responder path as the tool shortcuts, which is
    /// why the typing branch has to run first and consume everything.
    /// Returns true when the event was a text keystroke.
    private func handleTypingKey(_ event: NSEvent) -> Bool {
        guard isTypingText, let session, var pending = session.pendingText else { return false }

        switch event.keyCode {
        case 36, 76:                       // Return, keypad Enter
            commitTypedText()
            return true
        case 51:                           // Delete
            guard !pending.string.isEmpty else { return true }
            pending.string.removeLast()
            session.updatePendingText(pending.string)
            refreshTypingPreview()
            return true
        default:
            break
        }

        // Anything with Command is a shortcut, not text.
        guard !event.modifierFlags.contains(.command) else { return false }
        guard let typed = event.characters, !typed.isEmpty else { return false }
        let printable = typed.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        guard !printable.isEmpty else { return false }

        session.updatePendingText(pending.string + printable)
        refreshTypingPreview()
        return true
    }

    // MARK: - Caret

    private func startCaretBlink() {
        stopCaretBlink()
        caretVisible = true
        caretTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isTypingText else { return }
                self.caretVisible.toggle()
                self.needsDisplay = true
            }
        }
        // .common so it keeps blinking while the run loop is tracking a drag
        // elsewhere on the overlay.
        caretTimer.map { RunLoop.main.add($0, forMode: .common) }
    }

    private func stopCaretBlink() {
        caretTimer?.invalidate()
        caretTimer = nil
        caretVisible = true
    }

    private func drawTextCaret(_ ctx: CGContext) {
        guard isTypingText, caretVisible, let session,
              let pending = session.pendingText else { return }
        let measured = AnnotationRenderer.textBounds(pending.string, pointSize: pending.pointSize)
        let x = pending.at.x + measured.width + pending.pointSize * 0.06
        let height = max(measured.height, pending.pointSize)
        ctx.setFillColor(session.ink.cgColor)
        ctx.fill(CGRect(x: x, y: pending.at.y,
                        width: max(pending.pointSize * 0.07, chrome.borderWidth * 0.6),
                        height: height))
    }

    /// True while an inline label is being typed, so the dismissal coordinator can
    /// resolve that layer first.
    public var hasActiveTextEdit: Bool { isTypingText }

    public func resolveTextEdit(for intent: DismissalIntent) -> EditResolution {
        guard isTypingText, let session else { return .blocked }
        endTyping()
        let resolution = session.resolveActiveEdit(for: intent)
        window?.makeFirstResponder(self)
        needsDisplay = true
        return resolution
    }
}

// MARK: - Helpers

extension AnnotationPayload {
    /// Translation in source pixels. Never in view points: zoom must not reach
    /// stored geometry.
    func translated(by offset: CGPoint) -> AnnotationPayload {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + offset.x, y: p.y + offset.y) }
        func move(_ r: CGRect) -> CGRect { r.offsetBy(dx: offset.x, dy: offset.y) }
        switch self {
        case let .arrow(from, to, style):
            return .arrow(from: move(from), to: move(to), style: style)
        case let .line(from, to): return .line(from: move(from), to: move(to))
        case let .rect(r): return .rect(move(r))
        case let .oval(r): return .oval(move(r))
        case let .blur(r): return .blur(move(r))
        case let .pixelate(r): return .pixelate(move(r))
        case let .freehand(points): return .freehand(points: points.map(move))
        case let .highlighter(points): return .highlighter(points: points.map(move))
        case let .text(s, at, size): return .text(s, at: move(at), pointSize: size)
        case let .counter(n, at, radius): return .counter(n, at: move(at), radius: radius)
        }
    }
}

extension CGContext {
    /// Draws a `CGImage` into a flipped (top-left origin) context right side up.
    func draw(flipped image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.minY + rect.height)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}
