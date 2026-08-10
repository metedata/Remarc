import AppKit

// MARK: - Region Selection NSView

/// Full-screen overlay that lets the user drag-select a rectangular region.
/// Draws a semi-transparent dark background with a clear cutout for the selection,
/// a white border around the selection, and a size label (W x H).
@MainActor
private final class RegionSelectionView: NSView {
    var onRegionSelected: ((_ rect: NSRect) -> Void)?
    /// Fired during drag (live) — reposition panel without refocusing
    var onRegionAdjusting: ((_ rect: NSRect) -> Void)?
    /// Fired on mouseUp — reposition panel and refocus text field
    var onRegionUpdated: ((_ rect: NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private enum InteractionMode {
        case idle
        case drawing
        case resizing(Corner)
        case resizingEdge(RectEdge)
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private enum RectEdge: CaseIterable {
        case top, bottom, left, right
    }

    private var interactionMode: InteractionMode = .idle
    private var selectionRect: NSRect?
    private var dragStart: NSPoint?
    private var dragEnd: NSPoint?
    private var resizeAnchor: NSPoint?
    /// Snapshot of selection rect at drag start, for edge resize
    private var resizeOriginalRect: NSRect?
    /// Whether a completed selection has been reported via onRegionSelected
    private var hasReportedInitialSelection = false

    private let minimumSize: CGFloat = 10
    private let handleHitRadius: CGFloat = 12
    private let edgeHitThreshold: CGFloat = 8
    private let handleOffset: CGFloat = 4      // gap from selection border
    private let handleStrokeWidth: CGFloat = 2.5
    private let edgeSegmentLength: CGFloat = 24

    // MARK: - Annotation host

    /// The annotation canvas, when a frozen session exists. This is the first
    /// subview this view has ever had; AppKit draws parents before subviews, so the
    /// canvas covers the region and draws its own selection border.
    private(set) var annotationCanvas: AnnotationCanvasNSView?

    /// The magnified display rect `D`, in this view's local (unflipped, 0-based)
    /// points. Never the capture rect: `pendingQuartzRect` is derived from `S`
    /// alone and must never see this.
    private var annotationDisplayRect: NSRect?

    /// `S`, frozen at annotate-entry. The size label reports this, not `D`.
    private var frozenSelectionRect: NSRect?
    private var effectiveZoom: Int = 1

    var isAnnotating: Bool { annotationCanvas != nil }

    /// `startFrame` is where the canvas begins the entry animation; `displayRect`
    /// is where the parent's chrome should already be. Splitting them keeps the
    /// size label at its final position for the whole 0.18s enlargement instead of
    /// snapping at the end.
    func installAnnotationCanvas(_ canvas: AnnotationCanvasNSView,
                                 selection: NSRect,
                                 displayRect: NSRect,
                                 startFrame: NSRect,
                                 zoom: Int) {
        frozenSelectionRect = selection
        annotationDisplayRect = displayRect
        effectiveZoom = zoom
        annotationCanvas = canvas
        canvas.frame = startFrame
        addSubview(canvas)
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func updateAnnotationStage(displayRect: NSRect, zoom: Int) {
        annotationDisplayRect = displayRect
        effectiveZoom = zoom
        annotationCanvas?.frame = displayRect
        // A frame change marks neither view dirty on its own, and ChromeMetrics has
        // changed on both.
        annotationCanvas?.needsDisplay = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        annotationCanvas.map { window?.invalidateCursorRects(for: $0) }
    }

    func removeAnnotationCanvas() {
        annotationCanvas?.removeFromSuperview()
        annotationCanvas = nil
        annotationDisplayRect = nil
        frozenSelectionRect = nil
        effectiveZoom = 1
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Semi-transparent dark overlay. Unchanged while annotating: the dim
        // backdrop stays exactly as it is.
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: bounds).fill()

        // While a frozen session exists the geometry that drives chrome is the
        // DISPLAY rect, not the live selection.
        guard let rect = isAnnotating ? annotationDisplayRect : currentSelectionRect else { return }

        let cr = min(AppConstants.panelCornerRadius, min(rect.width, rect.height) / 4)

        if !isAnnotating {
            // Clear cutout for selected region (rounded corners, scaled for small selections)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: rect, xRadius: cr, yRadius: cr).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // White border around selection (rounded corners)
            NSColor.white.setStroke()
            let borderPath = NSBezierPath(roundedRect: rect, xRadius: cr, yRadius: cr)
            borderPath.lineWidth = 1.5
            borderPath.stroke()
        }
        // Annotating: the cutout is SKIPPED because a clamped `D` need not cover
        // `S`, and a cleared sliver outside the canvas would show undimmed desktop.
        // The border is skipped too - the canvas draws it after its own rasters, or
        // the parent's stroke would have its inner half covered.

        // Size label: text always reports the TRUE capture size; position, flip,
        // and clamp derive from the display rect.
        drawSizeLabel(for: rect, reporting: isAnnotating ? frozenSelectionRect : rect)

        // Handles — only when idle with a finalized selection. Resize is locked
        // while annotating, so the chrome constants need no zoom compensation.
        if !isAnnotating, case .idle = interactionMode, selectionRect != nil {
            drawHandles(for: rect)
        }
    }

    private func drawHandles(for rect: NSRect) {
        // Must match the dynamic corner radius used in draw()
        let cr = min(AppConstants.panelCornerRadius, min(rect.width, rect.height) / 4)
        let arcRadius = cr + handleOffset
        let handleColor = NSColor.white.withAlphaComponent(0.7)
        handleColor.setStroke()

        // Trim arc sweep when same-side arcs would crowd each other
        let verticalSpace = rect.height - 2 * cr
        let horizontalSpace = rect.width - 2 * cr
        let maxTrim: CGFloat = 25
        let trimV = max(0, min(maxTrim, maxTrim * (1 - verticalSpace / (2 * arcRadius))))
        let trimH = max(0, min(maxTrim, maxTrim * (1 - horizontalSpace / (2 * arcRadius))))

        // Corner arcs — strokes parallel to the selection's rounded corners
        let cornerArcs: [(center: NSPoint, startAngle: CGFloat, endAngle: CGFloat)] = [
            (NSPoint(x: rect.maxX - cr, y: rect.maxY - cr), 0 + trimV, 90 - trimH),     // topRight
            (NSPoint(x: rect.minX + cr, y: rect.maxY - cr), 90 + trimH, 180 - trimV),   // topLeft
            (NSPoint(x: rect.minX + cr, y: rect.minY + cr), 180 + trimV, 270 - trimH),  // bottomLeft
            (NSPoint(x: rect.maxX - cr, y: rect.minY + cr), 270 + trimH, 360 - trimV),  // bottomRight
        ]
        for (center, startAngle, endAngle) in cornerArcs {
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: arcRadius,
                           startAngle: startAngle, endAngle: endAngle)
            path.lineWidth = handleStrokeWidth
            path.lineCapStyle = .round
            path.stroke()
        }

        // Edge midpoint segments — dynamically sized, hidden if they'd overlap corner arcs
        let gapFromArc: CGFloat = 8
        let minSegment: CGFloat = 10
        let availableH = rect.width - 2 * cr - 2 * gapFromArc
        let availableV = rect.height - 2 * cr - 2 * gapFromArc

        var edgeLines: [(from: NSPoint, to: NSPoint)] = []

        if availableH >= minSegment {
            let halfSeg = min(edgeSegmentLength, availableH) / 2
            // top
            edgeLines.append((NSPoint(x: rect.midX - halfSeg, y: rect.maxY + handleOffset),
                              NSPoint(x: rect.midX + halfSeg, y: rect.maxY + handleOffset)))
            // bottom
            edgeLines.append((NSPoint(x: rect.midX - halfSeg, y: rect.minY - handleOffset),
                              NSPoint(x: rect.midX + halfSeg, y: rect.minY - handleOffset)))
        }

        if availableV >= minSegment {
            let halfSeg = min(edgeSegmentLength, availableV) / 2
            // left
            edgeLines.append((NSPoint(x: rect.minX - handleOffset, y: rect.midY - halfSeg),
                              NSPoint(x: rect.minX - handleOffset, y: rect.midY + halfSeg)))
            // right
            edgeLines.append((NSPoint(x: rect.maxX + handleOffset, y: rect.midY - halfSeg),
                              NSPoint(x: rect.maxX + handleOffset, y: rect.midY + halfSeg)))
        }

        for (from, to) in edgeLines {
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineWidth = handleStrokeWidth
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    /// `rect` positions the label; `sizeSource` supplies the numbers. They differ
    /// while magnified: the user is told what they will capture, not how big it
    /// currently looks.
    private func drawSizeLabel(for rect: NSRect, reporting sizeSource: NSRect? = nil) {
        let measured = sizeSource ?? rect
        let w = Int(measured.width)
        let h = Int(measured.height)
        // The suffix carries the EFFECTIVE zoom, never a requested one.
        let suffix = (isAnnotating && effectiveZoom > 1) ? " · \(effectiveZoom)x" : ""
        let text = "\(w) x \(h)\(suffix)"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]

        let attrString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attrString.size()

        // Position label below the selection, or above if not enough room
        let padding: CGFloat = 6
        let labelWidth = textSize.width + padding * 2
        let labelHeight = textSize.height + padding
        var labelX = rect.midX - labelWidth / 2
        var labelY = rect.minY - labelHeight - 6

        if labelY < bounds.minY + 4 {
            labelY = rect.maxY + 6
        }

        // Clamp horizontally
        labelX = max(bounds.minX + 4, min(labelX, bounds.maxX - labelWidth - 4))

        let bgRect = NSRect(x: labelX, y: labelY, width: labelWidth, height: labelHeight)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()

        let textPoint = NSPoint(
            x: bgRect.midX - textSize.width / 2,
            y: bgRect.midY - textSize.height / 2
        )
        attrString.draw(at: textPoint)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        // Region geometry is locked while a frozen annotation session exists; the
        // canvas subview owns every event inside the stage.
        guard !isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)

        if let rect = selectionRect {
            // 1. Check corners (highest priority)
            if let corner = cornerHitTest(point: point, rect: rect) {
                interactionMode = .resizing(corner)
                resizeAnchor = oppositeCorner(of: corner, in: rect)
                return
            }

            // 2. Check edges
            if let edge = edgeHitTest(point: point, rect: rect) {
                interactionMode = .resizingEdge(edge)
                resizeOriginalRect = rect
                return
            }
        }

        // 3. Click outside handles → start a new draw
        dragStart = point
        dragEnd = point
        interactionMode = .drawing
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch interactionMode {
        case .drawing:
            dragEnd = point
            needsDisplay = true

        case .resizing:
            guard let anchor = resizeAnchor else { return }
            selectionRect = rectFromCorners(anchor, point)
            needsDisplay = true
            if let rect = selectionRect { onRegionAdjusting?(rect) }

        case .resizingEdge(let edge):
            guard let orig = resizeOriginalRect else { return }
            selectionRect = computeEdgeResize(edge: edge, original: orig, mouse: point)
            needsDisplay = true
            if let rect = selectionRect { onRegionAdjusting?(rect) }

        case .idle:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard !isAnnotating else { return }
        let point = convert(event.locationInWindow, from: nil)

        switch interactionMode {
        case .drawing:
            dragEnd = point
            guard let rect = rectFromDrag,
                  rect.width >= minimumSize,
                  rect.height >= minimumSize
            else {
                // Too small — reset draw state, keep existing selection if any
                dragStart = nil
                dragEnd = nil
                interactionMode = .idle
                needsDisplay = true
                return
            }

            let previouslyHadSelection = hasReportedInitialSelection
            selectionRect = rect
            dragStart = nil
            dragEnd = nil
            interactionMode = .idle

            if previouslyHadSelection {
                onRegionUpdated?(rect)
            } else {
                hasReportedInitialSelection = true
                onRegionSelected?(rect)
            }
            needsDisplay = true

        case .resizing:
            guard let anchor = resizeAnchor else {
                interactionMode = .idle
                return
            }
            let rect = rectFromCorners(anchor, point)

            if rect.width >= minimumSize, rect.height >= minimumSize {
                selectionRect = rect
            }

            resizeAnchor = nil
            interactionMode = .idle
            needsDisplay = true

            if let final = selectionRect {
                onRegionUpdated?(final)
            }

        case .resizingEdge(let edge):
            guard let orig = resizeOriginalRect else {
                interactionMode = .idle
                return
            }
            let rect = computeEdgeResize(edge: edge, original: orig, mouse: point)

            if rect.width >= minimumSize, rect.height >= minimumSize {
                selectionRect = rect
            }

            resizeOriginalRect = nil
            interactionMode = .idle
            needsDisplay = true

            if let final = selectionRect {
                onRegionUpdated?(final)
            }

        case .idle:
            break
        }

        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }

    // MARK: - Cursor & Tracking

    override func resetCursorRects() {
        // The canvas installs its own cursor over the stage, and resize is locked,
        // so the parent contributes nothing while annotating.
        guard !isAnnotating else { return }

        if let rect = selectionRect, case .idle = interactionMode {
            let hr = handleHitRadius

            // Corner handle cursors — crosshair
            let cornerPoints: [NSPoint] = [
                NSPoint(x: rect.minX, y: rect.maxY),
                NSPoint(x: rect.maxX, y: rect.maxY),
                NSPoint(x: rect.minX, y: rect.minY),
                NSPoint(x: rect.maxX, y: rect.minY),
            ]
            for pt in cornerPoints {
                addCursorRect(NSRect(x: pt.x - hr, y: pt.y - hr, width: hr * 2, height: hr * 2),
                              cursor: .crosshair)
            }

            // Edge cursors — resize arrows
            let et = edgeHitThreshold
            // Top edge
            addCursorRect(NSRect(x: rect.minX + hr, y: rect.maxY - et, width: rect.width - hr * 2, height: et * 2),
                          cursor: .resizeUpDown)
            // Bottom edge
            addCursorRect(NSRect(x: rect.minX + hr, y: rect.minY - et, width: rect.width - hr * 2, height: et * 2),
                          cursor: .resizeUpDown)
            // Left edge
            addCursorRect(NSRect(x: rect.minX - et, y: rect.minY + hr, width: et * 2, height: rect.height - hr * 2),
                          cursor: .resizeLeftRight)
            // Right edge
            addCursorRect(NSRect(x: rect.maxX - et, y: rect.minY + hr, width: et * 2, height: rect.height - hr * 2),
                          cursor: .resizeLeftRight)
        }

        // Everything else — crosshair for drawing
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Helpers

    private var currentSelectionRect: NSRect? {
        switch interactionMode {
        case .drawing:
            return rectFromDrag
        case .resizing, .resizingEdge, .idle:
            return selectionRect
        }
    }

    /// Rect computed from the current drag points (used during drawing)
    private var rectFromDrag: NSRect? {
        guard let start = dragStart, let end = dragEnd else { return nil }
        return NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// Rect from two corner points
    private func rectFromCorners(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    /// Returns which corner handle the point is near, if any
    private func cornerHitTest(point: NSPoint, rect: NSRect) -> Corner? {
        let corners: [(Corner, NSPoint)] = [
            (.topLeft, NSPoint(x: rect.minX, y: rect.maxY)),
            (.topRight, NSPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, NSPoint(x: rect.minX, y: rect.minY)),
            (.bottomRight, NSPoint(x: rect.maxX, y: rect.minY)),
        ]
        for (corner, cornerPoint) in corners {
            let dx = point.x - cornerPoint.x
            let dy = point.y - cornerPoint.y
            if hypot(dx, dy) <= handleHitRadius {
                return corner
            }
        }
        return nil
    }

    /// Returns which edge the point is near (excluding corner zones)
    private func edgeHitTest(point: NSPoint, rect: NSRect) -> RectEdge? {
        let t = edgeHitThreshold
        let cz = handleHitRadius  // corner exclusion zone

        // Top edge
        if abs(point.y - rect.maxY) < t &&
           point.x > rect.minX + cz && point.x < rect.maxX - cz {
            return .top
        }
        // Bottom edge
        if abs(point.y - rect.minY) < t &&
           point.x > rect.minX + cz && point.x < rect.maxX - cz {
            return .bottom
        }
        // Left edge
        if abs(point.x - rect.minX) < t &&
           point.y > rect.minY + cz && point.y < rect.maxY - cz {
            return .left
        }
        // Right edge
        if abs(point.x - rect.maxX) < t &&
           point.y > rect.minY + cz && point.y < rect.maxY - cz {
            return .right
        }
        return nil
    }

    /// Compute new rect from an edge resize drag
    private func computeEdgeResize(edge: RectEdge, original: NSRect, mouse: NSPoint) -> NSRect {
        switch edge {
        case .top:
            let bottom = original.minY
            return NSRect(x: original.minX, y: min(bottom, mouse.y),
                          width: original.width, height: abs(mouse.y - bottom))
        case .bottom:
            let top = original.maxY
            return NSRect(x: original.minX, y: min(top, mouse.y),
                          width: original.width, height: abs(mouse.y - top))
        case .left:
            let right = original.maxX
            return NSRect(x: min(right, mouse.x), y: original.minY,
                          width: abs(mouse.x - right), height: original.height)
        case .right:
            let left = original.minX
            return NSRect(x: min(left, mouse.x), y: original.minY,
                          width: abs(mouse.x - left), height: original.height)
        }
    }

    /// Returns the point of the corner opposite to the given one
    private func oppositeCorner(of corner: Corner, in rect: NSRect) -> NSPoint {
        switch corner {
        case .topLeft: return NSPoint(x: rect.maxX, y: rect.minY)
        case .topRight: return NSPoint(x: rect.minX, y: rect.minY)
        case .bottomLeft: return NSPoint(x: rect.maxX, y: rect.maxY)
        case .bottomRight: return NSPoint(x: rect.minX, y: rect.maxY)
        }
    }
}

/// The capture overlay's window.
///
/// A borderless `NSPanel` returns false from `canBecomeKey`, so the existing
/// `makeKeyAndOrderFront` in `showOverlay` never actually made it key - which was
/// invisible while the overlay only needed mouse events. Annotation needs the
/// keyboard: without this the canvas can be first responder in a non-key window
/// and every tool shortcut goes to the comment text view instead. Measured before
/// the fix: pressing T and typing "hello" produced the comment "thello" and no
/// text annotation.
@MainActor
private final class KeyableOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - ScreenCaptureService

@MainActor
public final class ScreenCaptureService {
    public static let shared = ScreenCaptureService()

    var overlayPanel: NSPanel?
    private var selectionView: RegionSelectionView?
    private var escapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var onRegionSelectedCallback: ((_ captureRect: CGRect, _ sourceBundleID: String?) -> Void)?
    private var onCancelCallback: (() -> Void)?

    // Pending capture rect in global Quartz coordinates (origin top-left of primary display, Y down)
    private var pendingQuartzRect: CGRect?
    private var pendingSourceBundleID: String?

    // MARK: - Annotation state
    //
    // Owned here rather than in the controller because the canvas is a subview of
    // the overlay's region view and the stage math is expressed in that view's
    // local coordinates.

    /// The live capture session, if any. Also the re-entry guard: `startCapture`
    /// refuses while this is set, so a second hotkey press cannot overwrite the
    /// callbacks and pending state of an in-flight transaction. The guard lives
    /// here and not only in a controller wrapper because both real call sites
    /// reach the service directly, and the planned wake-screenshot hotkey would
    /// add a third on day one.
    private var captureIsLive = false

    private(set) var annotationSession: AnnotationSession?
    private let toolbarController = AnnotationToolbarPanelController()
    private let entryPillController = AnnotationEntryPillController()

    /// Selection `S` in region-view-local points, frozen at annotate-entry.
    private var pendingSelectionLocal: NSRect?
    private var overlayScreenFrame: NSRect?
    private var overlayScreen: NSScreen?

    private var stageAllowance: CGRect?
    private var stageMaxZoom = 1
    private(set) var stageEffectiveZoom = 1
    private var stageDisplayRectLocal: NSRect?
    private var isStageAnimating = false
    private var showsDiscardControls = false

    /// A prepared PNG plus the lease that owns it, handed to exactly one of
    /// `finalize` or `restore`.
    struct PreparedCapture {
        let token: UUID
        let relativePath: String
        let cgImage: CGImage
        let pointSize: CGSize
    }

    /// What a failed prepare may have left behind: no file, a lease with no file,
    /// or a file with a lease. A thrown error cannot carry this, which is why
    /// prepare returns an outcome rather than throwing.
    struct PreparedPartial {
        let relativePath: String?
        let leaseRecorded: Bool
    }

    enum PrepareOutcome {
        case success(PreparedCapture)
        case failure(Error, cleanup: PreparedPartial?)
    }

    enum ConcludeResult: Equatable {
        case finalized, restored, staleToken
    }

    private var activeToken: UUID?

    private init() {}

    var isAnnotating: Bool { annotationSession != nil }

    // MARK: - Public API

    /// Start a region capture flow.
    /// 1. Checks screen recording permission (shows panel if needed)
    /// 2. Shows full-screen overlay for region selection
    /// 3. Calls onRegionSelected immediately when user finishes selecting
    ///    (overlay stays visible — show comment input here)
    /// 4. Call `commitCapture()` later to dismiss overlay, capture, and save
    public func startCapture(
        onRegionSelected: @escaping (_ captureRect: CGRect, _ sourceBundleID: String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        // Both real call sites reach the service directly (GlobalHotkey,
        // PopoverContentView), so the guard has to be here. Overwriting callbacks
        // and pending state mid-transaction strands the first save.
        guard !captureIsLive else {
            debugLog("ScreenCaptureService: startCapture refused - a capture is already live")
            return
        }
        captureIsLive = true
        pendingSourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        self.onRegionSelectedCallback = onRegionSelected
        self.onCancelCallback = onCancel

        let permissionController = ScreenRecordingPermissionController.shared

        if permissionController.hasPermission() {
            showOverlay()
            return
        }

        permissionController.requestPermission { [weak self] granted in
            guard let self = self else { return }
            if granted {
                self.showOverlay()
            } else {
                debugLog("ScreenCaptureService: Permission denied - cancelling capture")
                self.cancel()
            }
        }
    }

    // MARK: - Overlay

    private func showOverlay() {
        // Use the screen under the mouse cursor (supports multi-monitor)
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main else {
            debugLog("ScreenCaptureService: No screen found")
            cancel()
            return
        }

        let screenFrame = screen.frame

        let panel = KeyableOverlayPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        let regionView = RegionSelectionView(frame: screenFrame)
        regionView.onRegionSelected = { [weak self] rect in
            self?.handleRegionSelected(rect, screenFrame: screenFrame, screen: screen)
        }
        regionView.onRegionAdjusting = { [weak self] rect in
            self?.handleRegionMoved(rect, screenFrame: screenFrame, screen: screen, restoreFocus: false)
        }
        regionView.onRegionUpdated = { [weak self] rect in
            self?.handleRegionMoved(rect, screenFrame: screenFrame, screen: screen, restoreFocus: true)
        }
        regionView.onCancel = { [weak self] in
            self?.cancel()
        }

        panel.contentView = regionView
        panel.setFrame(screenFrame, display: true)
        panel.alphaValue = 0

        // Activate the app so key events (Escape) reach our panel and
        // the comment input panel renders at full fidelity. The overlay
        // sits at .screenSaver level; CGWindowListCreateImage captures
        // everything BELOW it, so activation's window reorder is invisible
        // to the final capture.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(regionView)

        self.overlayPanel = panel
        self.selectionView = regionView
        self.overlayScreenFrame = screenFrame
        self.overlayScreen = screen

        // Local monitor consumes Escape when the app IS active (prevents beep).
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.cancel()
                return nil // consume — no beep
            }
            return event
        }
        // Global monitor catches Escape when the app ISN'T active
        // (e.g., screenshot triggered via hotkey while another app has focus).
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.cancel()
            }
        }

        // Fade in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscapeMonitor = nil
        }
    }

    private func dismissOverlay() {
        removeEscapeMonitor()
        teardownAnnotation()
        entryPillController.teardown()
        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        selectionView = nil
        overlayScreenFrame = nil
        overlayScreen = nil
        pendingSelectionLocal = nil
        captureIsLive = false
    }

    private func cancel() {
        dismissOverlay()
        captureIsLive = false
        let callback = onCancelCallback
        onCancelCallback = nil
        onRegionSelectedCallback = nil
        pendingQuartzRect = nil
        pendingSourceBundleID = nil
        callback?()
    }

    // MARK: - Capture

    private func updatePendingCapture(_ selectionRect: NSRect, screenFrame: NSRect, screen: NSScreen) {
        // Convert from view-local AppKit coordinates to global Quartz coordinates.
        // AppKit: origin bottom-left of primary screen, Y up.
        // Quartz: origin top-left of primary screen, Y down.
        // On multi-monitor, screenFrame.origin offsets the screen in AppKit global space.
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? screenFrame.height
        pendingQuartzRect = CGRect(
            x: selectionRect.origin.x + screenFrame.origin.x,
            y: primaryScreenHeight - selectionRect.origin.y - screenFrame.origin.y - selectionRect.height,
            width: selectionRect.width,
            height: selectionRect.height
        )
    }

    private func handleRegionSelected(_ selectionRect: NSRect, screenFrame: NSRect, screen: NSScreen) {
        removeEscapeMonitor()
        pendingSelectionLocal = selectionRect
        updatePendingCapture(selectionRect, screenFrame: screenFrame, screen: screen)
        let callback = onRegionSelectedCallback
        onRegionSelectedCallback = nil
        let sourceBundleID = pendingSourceBundleID
        // Convert from overlay-local to screen-global coordinates
        let screenRect = selectionRect.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y)
        callback?(screenRect, sourceBundleID)
        showEntryPill(selectionScreenRect: screenRect, screen: screen)
    }

    /// The Annotate pill, docked opposite the comment panel.
    ///
    /// Disabled until `panelLayoutReady`: `show()` schedules the panel's height
    /// work asynchronously and first-responder work later still, and the stage
    /// allowance reserves the panel's footprint, so entering earlier would size the
    /// stage from a stale frame.
    private func showEntryPill(selectionScreenRect rect: CGRect, screen: NSScreen) {
        entryPillController.onActivate = { [weak self] in self?.beginAnnotation() }
        entryPillController.show(
            selectionRectScreen: rect,
            panelEdge: CommentInputController.shared.frozenStageEdge,
            on: screen,
            isEnabled: CommentInputController.shared.panelLayoutReady)
        // Readiness arrives from the panel's deferred height pass, so subscribe
        // rather than poll: the poll and the height pass share one queue and the
        // poll wins, which left the pill permanently disabled.
        CommentInputController.shared.onPanelLayoutReady = { [weak self] in
            guard let self, self.annotationSession == nil,
                  self.pendingSelectionLocal != nil else { return }
            self.entryPillController.show(
                selectionRectScreen: rect,
                panelEdge: CommentInputController.shared.frozenStageEdge,
                on: screen,
                isEnabled: true)
        }
    }

    private func handleRegionMoved(_ selectionRect: NSRect, screenFrame: NSRect, screen: NSScreen, restoreFocus: Bool) {
        // Region geometry is locked while a frozen session exists. The parent view
        // already early-returns from its mouse machine, so this is belt and braces
        // against a queued callback.
        guard !isAnnotating else {
            debugLog("ScreenCaptureService: handleRegionMoved ignored - annotation session is live")
            return
        }
        pendingSelectionLocal = selectionRect
        updatePendingCapture(selectionRect, screenFrame: screenFrame, screen: screen)
        // Convert from overlay-local to screen-global coordinates
        let screenRect = selectionRect.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y)
        CommentInputController.shared.repositionForScreenshot(captureRect: screenRect, restoreFocus: restoreFocus)
        // The pill follows too. It used to stay wherever the first selection put
        // it, so resizing or moving the region left it stranded over the desktop.
        showEntryPill(selectionScreenRect: screenRect, screen: screen)
    }

    /// Capture the previously selected region, then dismiss the overlay and save.
    /// Uses CGWindowListCreateImage to grab everything below the overlay — this
    /// avoids SCKit's pixel-vs-point sourceRect ambiguity and timing races.
    public func commitCapture(onComplete: @escaping (_ imagePath: String) -> Void) {
        guard let quartzRect = pendingQuartzRect else {
            debugLog("ScreenCaptureService: commitCapture called with no pending capture")
            return
        }

        let overlayWID: CGWindowID
        if let wn = overlayPanel?.windowNumber, wn > 0 {
            overlayWID = CGWindowID(wn)
        } else {
            overlayWID = kCGNullWindowID
        }

        // Hide comment panel so it doesn't appear in the capture
        CommentInputController.shared.orderOutForSystemDialog()

        pendingQuartzRect = nil
        onCancelCallback = nil

        do {
            let image = try captureRegion(quartzRect, belowWindowID: overlayWID)
            dismissOverlay()
            let relativePath = try saveImage(image)

            if SettingsManager.shared.copyScreenshotToClipboard {
                copyImageToPasteboard(image)
            }

            debugLog("ScreenCaptureService: Capture saved to \(relativePath)")
            pendingSourceBundleID = nil
            onComplete(relativePath)
        } catch {
            dismissOverlay()
            pendingSourceBundleID = nil
            debugLog("ScreenCaptureService: Capture failed - \(error)")
        }
    }

    /// Cancel the capture — dismiss overlay without capturing.
    public func cancelCapture() {
        pendingQuartzRect = nil
        cancel()
    }

    /// Capture a region of the screen using CGWindowListCreateImage.
    /// Grabs everything on-screen below the given window (our overlay), using
    /// Quartz global coordinates (points, origin top-left of main display).
    private func captureRegion(_ quartzRect: CGRect, belowWindowID: CGWindowID) throws -> NSImage {
        let cgImage = try captureRegionCGImage(quartzRect, belowWindowID: belowWindowID)
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: quartzRect.width, height: quartzRect.height)
        )
    }

    /// The single `CGWindowListCreateImage` seam.
    ///
    /// `CGWindowListCreateImage` is **unavailable**, not merely deprecated, from
    /// macOS 15 onward; this compiles only because the package pins
    /// `.macOS(.v14)` (`Package.swift:7`). The freeze grab is a second call site,
    /// so both go through here and a future ScreenCaptureKit migration has exactly
    /// one place to change. Treat a deployment-target bump as blocked on that
    /// migration rather than as a routine change.
    private func captureRegionCGImage(_ quartzRect: CGRect,
                                      belowWindowID: CGWindowID) throws -> CGImage {
        debugLog("ScreenCaptureService: captureRegion quartzRect=\(quartzRect) belowWID=\(belowWindowID)")
        guard let cgImage = CGWindowListCreateImage(
            quartzRect,
            .optionOnScreenBelowWindow,
            belowWindowID,
            [.bestResolution]
        ) else {
            throw CaptureError.noDisplay
        }
        return cgImage
    }

    // MARK: - Save

    /// Save the captured image as a PNG in the Remarc images directory.
    /// Returns the relative path from the Remarc Application Support directory (e.g. "images/{uuid}.png").
    private func saveImage(_ image: NSImage) throws -> String {
        guard let pngData = image.pngData()
        else {
            throw CaptureError.imageConversionFailed
        }

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let imagesDir = appSupport
            .appendingPathComponent("Remarc", isDirectory: true)
            .appendingPathComponent("images", isDirectory: true)

        // Ensure directory exists
        if !FileManager.default.fileExists(atPath: imagesDir.path) {
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        }

        let filename = "\(UUID().uuidString).png"
        let fileURL = imagesDir.appendingPathComponent(filename)
        try pngData.write(to: fileURL, options: .atomic)

        return "images/\(filename)"
    }

    // MARK: - Clipboard

    private func copyImageToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        debugLog("ScreenCaptureService: Copied screenshot to clipboard")
    }

    // MARK: - Errors

    // MARK: - Annotation lifecycle

    /// Whether the Annotate control should be offered.
    var canBeginAnnotation: Bool {
        pendingQuartzRect != nil && pendingSelectionLocal != nil && annotationSession == nil
    }

    /// Freeze the selected pixels and enter annotation.
    ///
    /// The freeze grabs with the same `.optionOnScreenBelowWindow` semantics as the
    /// final capture, while the overlay is at full alpha. Verified on device: the
    /// grab ignores the overlay entirely, so the frozen bitmap is the undimmed
    /// content the user will actually capture.
    @discardableResult
    func beginAnnotation() -> Bool {
        guard annotationSession == nil,
              let quartzRect = pendingQuartzRect,
              let selection = pendingSelectionLocal,
              let regionView = selectionView,
              let screen = overlayScreen,
              let screenFrame = overlayScreenFrame else { return false }

        let overlayWID: CGWindowID = (overlayPanel?.windowNumber).map {
            $0 > 0 ? CGWindowID($0) : kCGNullWindowID
        } ?? kCGNullWindowID

        let frozen: CGImage
        do {
            frozen = try captureRegionCGImage(quartzRect, belowWindowID: overlayWID)
        } catch {
            // Remain in live selection with the typed comment intact.
            debugLog("ScreenCaptureService: Freeze grab failed - \(error)")
            ToastManager.shared.show("Could not freeze the region. Try again.")
            return false
        }

        let session = AnnotationSession(source: frozen)
        annotationSession = session

        let canvas = AnnotationCanvasNSView(pixelSize: session.pixelSize, session: session)
        canvas.onEscape = { [weak self] in self?.handleCanvasEscape() }
        // Deliberately NOT wired to refreshToolbar: AnnotationToolbarView observes
        // the session directly, so tool, colour, and undo state update themselves.
        // Re-showing the panel here relaid out the whole row on every mouse event -
        // 16 full relayouts in one second, measured during a drag.
        canvas.onStateChange = nil

        // Stage, computed in the same synchronous pass as the mode transition, so
        // there is no stable "before" frame the enlargement contradicts.
        resolveStage(selection: selection, screen: screen)
        let zoom = AnnotationStageGeometry.autoZoom(
            selection: selection.size, maxZoom: stageMaxZoom,
            comfortEdge: AnnotationStageGeometry.comfortEdgeDefault)
        let resolved = displayRect(for: selection, requestedZoom: zoom)
        stageEffectiveZoom = resolved.effectiveZoom
        stageDisplayRectLocal = resolved.rect

        regionView.installAnnotationCanvas(canvas, selection: selection,
                                           displayRect: resolved.rect,
                                           startFrame: selection,
                                           zoom: resolved.effectiveZoom)
        CommentInputController.shared.beginAnnotationAnchoring(
            displayRectScreen: resolved.rect.offsetBy(dx: screenFrame.origin.x,
                                                      dy: screenFrame.origin.y))

        animateStage(to: resolved.rect, zoom: resolved.effectiveZoom, duration: 0.18) {
            [weak self] in
            guard let self, let canvas = self.selectionView?.annotationCanvas else { return }
            // The overlay has to become KEY, not just first responder. The comment
            // panel sits a level above at .screenSaver + 1 and holds key status, so
            // making the canvas first responder in a non-key window left every tool
            // shortcut going to the comment text view - measured: pressing T then
            // typing produced the comment "thello" and no text annotation at all.
            //
            // Clicking the comment field hands focus back, which is how a user
            // types their comment; the two surfaces simply take turns.
            self.overlayPanel?.makeKeyAndOrderFront(nil)
            canvas.window?.makeFirstResponder(canvas)
        }

        entryPillController.hide()
        showToolbar()
        debugLog("ScreenCaptureService: Annotation began, \(Int(session.pixelSize.width))x\(Int(session.pixelSize.height)) px, z=\(resolved.effectiveZoom)")
        return true
    }

    /// Allowance box and the achievable zoom ceiling, for the frozen dock edge.
    private func resolveStage(selection: NSRect, screen: NSScreen) {
        let screenFrame = overlayScreenFrame ?? screen.frame
        // Local, 0-based: `panel.contentView = regionView` discards the screen
        // origin passed at construction.
        let visibleLocal = screen.visibleFrame.offsetBy(dx: -screenFrame.origin.x,
                                                        dy: -screenFrame.origin.y)
        let edge = CommentInputController.shared.frozenStageEdge

        guard let edge,
              let allowance = AnnotationStageGeometry.allowance(
                visible: visibleLocal, edge: edge,
                panelReserve: CommentInputController.panelReserve,
                toolbarReserveBelow: AnnotationToolbarPanelController.reserve)
        else {
            // Vertical docks and a missing edge both disable magnification.
            stageAllowance = nil
            stageMaxZoom = 1
            return
        }
        stageAllowance = allowance
        stageMaxZoom = AnnotationStageGeometry.resolvedMaxZoom(
            selection: selection, allowance: allowance,
            backingScale: screen.backingScaleFactor)
    }

    private func displayRect(for selection: NSRect,
                             requestedZoom: Int) -> (effectiveZoom: Int, rect: CGRect) {
        guard let allowance = stageAllowance, let screen = overlayScreen else {
            return (1, selection)
        }
        return AnnotationStageGeometry.displayRect(
            selection: selection, requestedZoom: requestedZoom,
            allowance: allowance, backingScale: screen.backingScaleFactor)
    }

    var stageMaximumZoom: Int { stageMaxZoom }

    /// Step or set the zoom. Every consumer reads the ACHIEVED zoom, never the
    /// requested one.
    func setZoom(_ requested: Int) {
        guard annotationSession != nil, !isStageAnimating,
              let selection = pendingSelectionLocal,
              let screenFrame = overlayScreenFrame else { return }
        let clamped = min(max(requested, 1), stageMaxZoom)
        let resolved = displayRect(for: selection, requestedZoom: clamped)
        guard resolved.rect != stageDisplayRectLocal || resolved.effectiveZoom != stageEffectiveZoom
        else { return }

        stageEffectiveZoom = resolved.effectiveZoom
        stageDisplayRectLocal = resolved.rect

        // Manual steps are instant; only entry and exit animate.
        selectionView?.updateAnnotationStage(displayRect: resolved.rect,
                                             zoom: resolved.effectiveZoom)
        CommentInputController.shared.setAnnotationDisplayRect(
            resolved.rect.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y))
        refreshToolbar()
    }

    func stepZoom(_ delta: Int) { setZoom(stageEffectiveZoom + delta) }

    private func animateStage(to rect: CGRect, zoom: Int, duration: TimeInterval,
                              completion: @escaping () -> Void) {
        guard let regionView = selectionView, let canvas = regionView.annotationCanvas else {
            completion(); return
        }
        // Input and editor chrome are disabled for the duration: intermediate
        // frames traverse fractional scales where ChromeMetrics does not hold.
        isStageAnimating = true
        canvas.isInputEnabled = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            canvas.animator().frame = rect
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.isStageAnimating = false
            canvas.isInputEnabled = true
            regionView.updateAnnotationStage(displayRect: rect, zoom: zoom)
            completion()
        }
    }

    // MARK: - Toolbar

    private func showToolbar() {
        guard let session = annotationSession,
              let screen = overlayScreen,
              let local = stageDisplayRectLocal,
              let screenFrame = overlayScreenFrame else { return }

        toolbarController.onCancel = { [weak self] in self?.handleToolbarEscape() }
        toolbarController.onZoomStep = { [weak self] in self?.stepZoom($0) }
        // Done KEEPS the marks. Discard is the only thing that drops them.
        toolbarController.onDone = { [weak self] in self?.finishAnnotating() }
        toolbarController.onRequestDiscard = { [weak self] in
            self?.showsDiscardControls = true
            self?.refreshToolbar()
        }
        toolbarController.onCancelDiscard = { [weak self] in
            self?.showsDiscardControls = false
            self?.refreshToolbar()
        }
        toolbarController.onConfirmDiscard = { [weak self] in
            self?.showsDiscardControls = false
            self?.exitAnnotation(discardingItems: true)
        }

        toolbarController.show(
            session: session,
            anchoredBelow: local.offsetBy(dx: screenFrame.origin.x, dy: screenFrame.origin.y),
            on: screen,
            zoomState: stageMaxZoom > 1
                ? .init(effectiveZoom: stageEffectiveZoom, maxZoom: stageMaxZoom)
                : nil,
            showsDiscardControls: showsDiscardControls)
    }

    /// Ordered out before the fly panel is created, so the two never contend for
    /// `.screenSaver + 2`. The session stays alive: a failed durable write has to
    /// be able to bring the toolbar straight back.
    func orderOutToolbarForCommit() {
        toolbarController.orderOut()
        entryPillController.hide()
    }

    func restoreToolbarAfterFailedCommit() {
        if annotationSession != nil {
            showToolbar()
            return
        }
        // Not annotating: the pill is what has to come back.
        guard let selection = pendingSelectionLocal,
              let screen = overlayScreen,
              let screenFrame = overlayScreenFrame else { return }
        showEntryPill(
            selectionScreenRect: selection.offsetBy(dx: screenFrame.origin.x,
                                                    dy: screenFrame.origin.y),
            screen: screen)
    }

    private func refreshToolbar() {
        guard annotationSession != nil, toolbarController.isVisible else { return }
        showToolbar()
    }

    // MARK: - Dismissal coordination

    /// Resolves exactly ONE layer per invocation and stops.
    func resolveDismissal(intent: DismissalIntent) -> Bool {
        guard let session = annotationSession else { return false }
        let canvas = selectionView?.annotationCanvas

        // 1. An inline text edit consumes the event and returns focus to the canvas.
        if canvas?.hasActiveTextEdit == true {
            _ = canvas?.resolveTextEdit(for: intent)
            return true
        }
        // 2. Toolbar focus returns to the canvas.
        if toolbarController.isVisible, let canvas, canvas.window?.firstResponder !== canvas {
            canvas.window?.makeFirstResponder(canvas)
            canvas.window?.makeKeyAndOrderFront(nil)
            return true
        }
        // 3. A dirty session reveals the discard controls.
        if session.isDirty && !showsDiscardControls {
            showsDiscardControls = true
            refreshToolbar()
            return true
        }
        // 4. Discard controls showing: hide them, stay in annotation.
        if showsDiscardControls {
            showsDiscardControls = false
            refreshToolbar()
            return true
        }
        // Nothing of ours left. A clean session has nothing to lose, so it exits
        // fully; a session with marks only leaves editing mode.
        if session.isDirty { finishAnnotating() } else { exitAnnotation(discardingItems: false) }
        return true
    }

    private func handleCanvasEscape() { _ = resolveDismissal(intent: .escape) }
    private func handleToolbarEscape() { _ = resolveDismissal(intent: .escape) }

    /// Finish editing but KEEP the marks.
    ///
    /// This is the "Done" checkmark. It used to tear the session down, which meant
    /// the following save fell back to a fresh below-overlay grab and shipped a
    /// screenshot with none of the user's annotations on it - the single worst
    /// outcome the feature can produce. The session, the canvas, and the stage all
    /// stay; only the toolbar goes away and focus returns to the comment field so
    /// the user can type and save.
    func finishAnnotating() {
        guard annotationSession != nil else { return }
        showsDiscardControls = false
        toolbarController.orderOut()
        // The Annotate pill comes back as the way to reopen the toolbar.
        if let screen = overlayScreen, let screenFrame = overlayScreenFrame,
           let local = stageDisplayRectLocal {
            entryPillController.onActivate = { [weak self] in self?.reopenToolbar() }
            entryPillController.show(
                selectionRectScreen: local.offsetBy(dx: screenFrame.origin.x,
                                                    dy: screenFrame.origin.y),
                panelEdge: CommentInputController.shared.frozenStageEdge,
                on: screen, isEnabled: true)
        }
        CommentInputController.shared.focusCommentField()
    }

    private func reopenToolbar() {
        guard annotationSession != nil else { return }
        entryPillController.hide()
        showToolbar()
        if let canvas = selectionView?.annotationCanvas {
            overlayPanel?.makeKeyAndOrderFront(nil)
            canvas.window?.makeFirstResponder(canvas)
        }
    }

    /// Leave annotation entirely, discarding every mark and restoring live region
    /// selection.
    ///
    /// Teardown happens at exactly one point: the completion handler of the exit
    /// animation. The canvas stays installed and the anchor stays set for the
    /// collapse, with input disabled. Nothing is cleared synchronously.
    func exitAnnotation(discardingItems: Bool) {
        guard annotationSession != nil, let selection = pendingSelectionLocal else { return }
        guard !isStageAnimating else { return }
        showsDiscardControls = false
        toolbarController.orderOut()

        animateStage(to: selection, zoom: 1, duration: 0.14) { [weak self] in
            guard let self else { return }
            self.teardownAnnotation()
            CommentInputController.shared.endAnnotationAnchoring()
            if let screen = self.overlayScreen, let screenFrame = self.overlayScreenFrame {
                self.showEntryPill(
                    selectionScreenRect: selection.offsetBy(dx: screenFrame.origin.x,
                                                            dy: screenFrame.origin.y),
                    screen: screen)
            }
            if let screenFrame = self.overlayScreenFrame {
                CommentInputController.shared.repositionForScreenshot(
                    captureRect: selection.offsetBy(dx: screenFrame.origin.x,
                                                    dy: screenFrame.origin.y),
                    restoreFocus: true)
            }
        }
        _ = discardingItems
    }

    private func teardownAnnotation() {
        toolbarController.teardown()
        selectionView?.removeAnnotationCanvas()
        annotationSession?.teardown()
        annotationSession = nil
        stageAllowance = nil
        stageDisplayRectLocal = nil
        stageEffectiveZoom = 1
        stageMaxZoom = 1
        showsDiscardControls = false
        isStageAnimating = false
    }

    // MARK: - Capture transaction

    /// Produce the final PNG without disturbing the overlay, the draft, or the
    /// session, so a failure here is fully recoverable.
    func prepareCommit() async -> PrepareOutcome {
        guard let quartzRect = pendingQuartzRect else {
            return .failure(CaptureError.noPendingRegion, cleanup: nil)
        }

        let image: CGImage
        /// Set when the marks made during capture can be re-edited later.
        var editable: (base: CGImage, items: [AnnotationItem])?

        if let session = annotationSession {
            do {
                // Commits a pending label or throws; it never silently cancels, and
                // a half-typed label must not be dropped by a save.
                try session.commitActiveEditForOutput()
            } catch {
                return .failure(CaptureError.pendingLabelUnresolved, cleanup: nil)
            }
            do {
                // The SAME split the preview panel's Apply performs, so a mark
                // made while capturing is as editable later as one added
                // afterwards. This used to render a single flat composite, which
                // meant annotating during capture - the most common way to do it -
                // produced an image whose marks were pixels forever, and reopening
                // Annotate on it offered nothing to select.
                let split = try await session.withAppliedSplit {
                    ($0.flattened, $0.base, $0.editableItems)
                }
                image = split.0
                editable = split.2.isEmpty ? nil : (split.1, split.2)
            } catch {
                return .failure(CaptureError.renderFailed("\(error)"), cleanup: nil)
            }
        } else {
            let overlayWID: CGWindowID = (overlayPanel?.windowNumber).map {
                $0 > 0 ? CGWindowID($0) : kCGNullWindowID
            } ?? kCGNullWindowID
            do {
                image = try captureRegionCGImage(quartzRect, belowWindowID: overlayWID)
            } catch {
                report(error, operation: "prepareCommit.capture")
                return .failure(error, cleanup: nil)
            }
        }

        let relativePath = "images/\(UUID().uuidString).png"
        var leaseRecorded = false
        do {
            // Off the main actor: the registry is guarded by DocumentLock, which
            // polls with Thread.sleep for up to 2s, and this sits on the capture
            // save's critical path.
            try await Task.detached(priority: .userInitiated) {
                // Recorded BEFORE the write, so a crash mid-write still leaves an
                // owned path the startup sweep can reclaim.
                try PreparedCaptureLeaseRegistry.record(path: relativePath)
            }.value
            leaseRecorded = true

            let data = try AnnotationExporter.pngData(from: image)
            let url = resolveImagePath(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)

            // After the PNG, and deliberately not fatal. The capture is complete
            // and correct without this; all it buys is re-editability, so a
            // failure here must not lose the user their screenshot.
            if let editable {
                do {
                    try AnnotationMarkStore.write(base: editable.base, items: editable.items,
                                                  flattenedPNG: data, for: relativePath)
                } catch {
                    debugLog("ScreenCaptureService: marks not stored, capture kept - \(error)")
                }
            }
        } catch {
            report(error, operation: "prepareCommit.write")
            return .failure(error, cleanup: PreparedPartial(
                relativePath: leaseRecorded ? relativePath : nil, leaseRecorded: leaseRecorded))
        }

        let token = UUID()
        activeToken = token
        return .success(PreparedCapture(
            token: token, relativePath: relativePath, cgImage: image,
            pointSize: CGSize(width: quartzRect.width, height: quartzRect.height)))
    }

    /// The comment is durably on disk. Release everything.
    ///
    /// A failed lease removal here does NOT trigger restore: the comment is written
    /// and the file is referenced, so a stale lease entry is harmless and the next
    /// startup sweep finds the file referenced and drops the entry.
    @discardableResult
    func finalize(token: UUID, prepared: PreparedCapture) -> ConcludeResult {
        guard activeToken == token else {
            debugLog("ScreenCaptureService: finalize with a stale token")
            return .staleToken
        }
        activeToken = nil

        if SettingsManager.shared.copyScreenshotToClipboard {
            copyImageToPasteboard(NSImage(cgImage: prepared.cgImage,
                                          size: prepared.pointSize))
        }

        try? PreparedCaptureLeaseRegistry.release(path: prepared.relativePath)
        pendingQuartzRect = nil
        pendingSourceBundleID = nil
        onCancelCallback = nil
        onRegionSelectedCallback = nil
        dismissOverlay()
        return .finalized
    }

    /// The durable write failed. Undo the prepared resource and leave every editor
    /// usable.
    ///
    /// Ordering matters: the PNG is deleted BEFORE the lease is removed, and the
    /// lease is retained if the deletion fails, so a file that could not be removed
    /// stays owned and reclaimable rather than becoming an untracked orphan.
    @discardableResult
    func restore(token: UUID?, partial: PreparedPartial?) -> ConcludeResult {
        if let token, activeToken != token {
            debugLog("ScreenCaptureService: restore with a stale token")
            return .staleToken
        }
        activeToken = nil

        guard let partial, let path = partial.relativePath else { return .restored }

        // The whole family. The commit may have written a base and marks after
        // the PNG, and rolling back only the PNG would strand them - for a
        // capture annotated with vectors only, that base is a copy of the
        // screenshot the user just decided not to keep.
        var deleted = true
        do { try AnnotationMarkStore.deleteImageFamily(path) }
        catch {
            deleted = false
            debugLog("ScreenCaptureService: could not delete prepared capture - \(error)")
        }
        if deleted && partial.leaseRecorded {
            try? PreparedCaptureLeaseRegistry.release(path: path)
        }
        return .restored
    }

    func restore(token: UUID, prepared: PreparedCapture) -> ConcludeResult {
        restore(token: token, partial: PreparedPartial(relativePath: prepared.relativePath,
                                                       leaseRecorded: true))
    }

    private func report(_ error: Error, operation: String) {
        debugLog("ScreenCaptureService: \(operation) failed - \(error)")
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        case imageConversionFailed
        case noPendingRegion
        case pendingLabelUnresolved
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display found for screen capture"
            case .imageConversionFailed: return "Failed to convert captured image to PNG"
            case .noPendingRegion: return "No region is selected"
            case .pendingLabelUnresolved: return "Finish the text label first"
            case .renderFailed(let detail): return "Could not render annotations - \(detail)"
            }
        }
    }
}
