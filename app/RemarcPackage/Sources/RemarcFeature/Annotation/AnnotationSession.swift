import Foundation
import AppKit
import Combine
import CoreGraphics

/// Stroke presets, in source pixels. Mark geometry never scales with zoom.
public enum AnnotationStroke: CGFloat, CaseIterable, Sendable {
    case thin = 3, medium = 6, thick = 11

    public var label: String {
        switch self {
        case .thin: return "Thin"
        case .medium: return "Medium"
        case .thick: return "Thick"
        }
    }
}

/// What a dismissal request resolved to. A Boolean cannot distinguish a commit
/// from a cancel, and treating them alike silently discards a label the user was
/// halfway through typing.
public enum EditResolution: Equatable, Sendable {
    case committed
    case cancelledAndConsumed
    case blocked
}

public enum DismissalIntent: Equatable, Sendable {
    case escape, closeButton, clickOutside, replacement, deactivate
}

/// One annotation document, per surface.
///
/// Owns UI state, the item list, undo/redo, the generation counter, and the
/// published composite. It owns **no caches**: the filter and composite caches
/// belong to the compositor, because two owners for one cache makes coalescing
/// and eviction unspecifiable.
@MainActor
public final class AnnotationSession: ObservableObject {

    /// The immutable source. Every filter samples this, never already-annotated
    /// pixels.
    public let source: CGImage
    /// Measured from the decoded or captured image, never computed from points
    /// and never assumed to equal `selectionSize * backingScale`:
    /// `.bestResolution` guarantees no such relationship.
    public let pixelSize: CGSize

    public let compositor: AnnotationCompositor

    @Published public private(set) var items: [AnnotationItem] = []
    @Published public var tool: AnnotationTool = .arrow
    @Published public var ink: AnnotationInk = AnnotationInk.presets[0]
    @Published public var stroke: AnnotationStroke = .medium
    @Published public var arrowStyle: AnnotationArrowStyle = .straight
    @Published public var selectedItemID: UUID?

    /// The published composite and the region patch drawn over it.
    @Published public private(set) var composite: CGImage?
    @Published public private(set) var compositeGeneration: Int = -1
    @Published public private(set) var patch: (rect: CGRect, image: CGImage)?

    @Published public private(set) var isDirty = false

    /// The item list as it was last saved or loaded: the state that needs no
    /// decision. Empty for a fresh session, the restored marks for a reopened
    /// one.
    private var baselineItems: [AnnotationItem] = []
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    @Published public private(set) var counterSeed = 1

    /// Suspends mutation while an output operation fixes its target generation.
    @Published public private(set) var isFrozen = false

    /// Output pixels per source pixel for the DISPLAY raster only.
    ///
    /// At 4x on a 2x display this is 4, so a stroke is rasterized at the size it
    /// is actually shown rather than drawn at source resolution and blown up,
    /// which made every arrowhead and letter visibly jagged. Capped so a huge
    /// magnified raster cannot blow the memory budget.
    public private(set) var displayScale: CGFloat = 1

    public func setDisplayScale(_ scale: CGFloat) {
        let clamped = min(max(scale.rounded(), 1), 8)
        guard clamped != displayScale else { return }
        displayScale = clamped
        generation += 1
        Task { await requestComposite() }
    }

    private var generation = 0
    private var undoStack: [[AnnotationItem]] = []
    private var redoStack: [[AnnotationItem]] = []
    private let historyLimit = 100

    /// An inline label the user is still typing. Not a Boolean: commit and cancel
    /// are different outcomes and the caller has to be able to tell them apart.
    public private(set) var pendingText: (string: String, at: CGPoint, pointSize: CGFloat)?

    /// Whether an inline label is unresolved. Read by the preview's click-outside
    /// veto, so a click never destroys a label mid-typing.
    public var pendingTextIsActive: Bool { pendingText != nil }

    public init(source: CGImage, compositor: AnnotationCompositor = AnnotationCompositor()) {
        self.source = source
        self.pixelSize = CGSize(width: source.width, height: source.height)
        self.compositor = compositor
        Task { await self.requestComposite() }
    }

    public var viewport: AnnotationViewport {
        AnnotationViewport(pixelSize: pixelSize,
                           canvasBounds: CGRect(origin: .zero, size: pixelSize))
    }

    // MARK: - Mutation

    /// Every mutation goes through here so no path can bump the generation
    /// without also recording history and requesting a render.
    private func mutate(checkpoint: Bool = true, _ body: (inout [AnnotationItem]) -> Void) {
        guard !isFrozen else { return }
        if checkpoint { pushUndo() }
        body(&items)
        generation += 1
        isDirty = items != baselineItems
        refreshHistoryFlags()
        Task { await requestComposite() }
    }

    public func add(_ item: AnnotationItem) {
        mutate { $0.append(item) }
        if case .counter = item.payload { counterSeed += 1 }
    }

    public func replace(id: UUID, with item: AnnotationItem, checkpoint: Bool = true) {
        mutate(checkpoint: checkpoint) { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index] = item
        }
    }

    public func deleteSelected() {
        guard let selectedItemID else { return }
        mutate { list in list.removeAll { $0.id == selectedItemID } }
        self.selectedItemID = nil
    }

    public func restyleSelected(ink: AnnotationInk? = nil, stroke: AnnotationStroke? = nil) {
        guard let selectedItemID,
              let index = items.firstIndex(where: { $0.id == selectedItemID }) else { return }
        var updated = items[index]
        if let ink { updated.ink = ink }
        if let stroke { updated.strokeWidth = stroke.rawValue }
        replace(id: selectedItemID, with: updated)
    }

    public func bringSelectedToFront() {
        guard let selectedItemID else { return }
        mutate { list in
            guard let index = list.firstIndex(where: { $0.id == selectedItemID }) else { return }
            let item = list.remove(at: index)
            list.append(item)
        }
    }

    public func sendSelectedToBack() {
        guard let selectedItemID else { return }
        mutate { list in
            guard let index = list.firstIndex(where: { $0.id == selectedItemID }) else { return }
            let item = list.remove(at: index)
            list.insert(item, at: 0)
        }
    }

    // MARK: - Undo

    /// Checkpoints on completed gestures, text commit, delete, style mutation,
    /// counter placement, and z-order mutation. Zoom, selection, and focus are
    /// excluded: they are viewport and editor state, not document state.
    private func pushUndo() {
        undoStack.append(items)
        if undoStack.count > historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    public func undo() {
        guard !isFrozen, let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
        finishHistoryStep()
    }

    public func redo() {
        guard !isFrozen, let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        finishHistoryStep()
    }

    private func finishHistoryStep() {
        generation += 1
        // Compared against the BASELINE, not against emptiness. For a session
        // opened from saved marks the baseline is non-empty, so the old
        // `!items.isEmpty` test could never go clean again: undoing an edit all
        // the way back to the loaded state still demanded Apply or Discard for
        // changes that no longer existed.
        isDirty = items != baselineItems
        selectedItemID = items.contains { $0.id == selectedItemID } ? selectedItemID : nil
        refreshHistoryFlags()
        Task { await requestComposite() }
    }

    private func refreshHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Inline text

    public func beginText(at point: CGPoint, pointSize: CGFloat) {
        pendingText = ("", point, pointSize)
    }

    public func updatePendingText(_ string: String) {
        guard let current = pendingText else { return }
        pendingText = (string, current.at, current.pointSize)
    }

    /// Supplies the live text of an editor the session cannot see.
    ///
    /// The session only knows what was pushed into `pendingText`, and the AppKit
    /// field only pushes on Return or on an explicit resolve. Without this hook a
    /// user who typed a label and hit Save had it silently dropped: the output
    /// barrier read an empty `pendingText` and committed nothing.
    public var liveTextProvider: (() -> String?)?

    /// Commits a pending label or throws. **Never silently cancels.** Required
    /// before any compositor or output render: prepare, Copy, Apply, Save As.
    public func commitActiveEditForOutput() throws {
        if pendingText != nil, let live = liveTextProvider?() {
            updatePendingText(live)
        }
        guard let pending = pendingText else { return }
        pendingText = nil
        guard !pending.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return   // an empty label is nothing to commit, not a failure
        }
        add(AnnotationItem(payload: .text(pending.string, at: pending.at,
                                          pointSize: pending.pointSize),
                           ink: ink, strokeWidth: stroke.rawValue))
    }

    @discardableResult
    public func resolveActiveEdit(for intent: DismissalIntent) -> EditResolution {
        if pendingText != nil, let live = liveTextProvider?() {
            updatePendingText(live)
        }
        guard let pending = pendingText else { return .blocked }
        pendingText = nil
        switch intent {
        case .escape:
            return .cancelledAndConsumed
        case .closeButton, .clickOutside, .replacement, .deactivate:
            if !pending.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                add(AnnotationItem(payload: .text(pending.string, at: pending.at,
                                                  pointSize: pending.pointSize),
                                   ink: ink, strokeWidth: stroke.rawValue))
                return .committed
            }
            return .cancelledAndConsumed
        }
    }

    // MARK: - Composite

    public func requestComposite() async {
        let snapshot = AnnotationCompositor.Snapshot(
            generation: generation, base: source, items: items,
            pixelSize: pixelSize, displayScale: displayScale)
        let target = generation
        await compositor.submit(snapshot)
        guard let image = try? await compositor.composite(atLeast: target) else { return }
        // A result older than what is already published is dropped, so a slow
        // render cannot overwrite a newer composite.
        guard target >= compositeGeneration else { return }
        composite = image
        compositeGeneration = target
        if patch != nil, target >= generation {
            // The published composite already contains every change the patch
            // represented.
            patch = nil
        }
    }

    /// The transient patch: an opaque replacement for the union of the old and new
    /// dirty bounds, re-rendered from the current item list rather than
    /// accumulated, so rapid gestures and out-of-order completion stay correct.
    public func setLivePatch(region: CGRect, extraItems: [AnnotationItem]) async {
        let padded = region.insetBy(dx: -stroke.rawValue * 4, dy: -stroke.rawValue * 4)
        let cache = await compositor.filterCache()
        guard let image = AnnotationCompositor.patch(
            base: source, items: items + extraItems, pixelSize: pixelSize,
            region: padded, filters: cache, scale: displayScale) else { return }
        patch = (padded.integral.intersection(CGRect(origin: .zero, size: pixelSize)), image)
    }

    public func clearLivePatch() { patch = nil }

    // MARK: - Output barrier

    /// Suspends mutation, fixes the newest generation, and waits for it.
    ///
    /// Scoped rather than a bare flag: a freeze that survives its operation leaves
    /// the canvas permanently read-only. It thaws on every exit - success, render
    /// failure, cancellation, a Save As sheet the user cancels, a preview dismissed
    /// mid-export.
    public func withFrozenComposite<T>(_ body: (CGImage) async throws -> T) async throws -> T {
        try commitActiveEditForOutput()
        isFrozen = true
        defer { isFrozen = false }

        // Mutation is frozen, so nothing can change under this render.
        let output = try await compositor.renderForOutput(
            base: source, items: items, pixelSize: pixelSize)
        return try await body(output)
    }

    /// What Apply produces: a permanent base, what the user sees, and the marks
    /// that stay editable.
    public struct AppliedSplit {
        /// The capture with every redaction flattened into its pixels. Stored as
        /// the editing base, so no pristine copy of the capture is kept.
        ///
        /// Not the same as the content being unrecoverable: blur and pixelate
        /// are visual obscuration, and `CIPixellate` in particular point-samples
        /// each cell, so original pixel values survive subsampled in both this
        /// base and the flattened PNG.
        public let base: CGImage
        /// Base plus the editable marks: the flattened PNG.
        public let flattened: CGImage
        /// Marks that survive as vectors, in their original z-order.
        public let editableItems: [AnnotationItem]
    }

    /// Split the item list for Apply, rendering both halves under one freeze.
    ///
    /// The split point is AFTER THE LAST REDACTION, not "all redactions". Those
    /// differ whenever a vector sits below a blur, and hoisting redactions out
    /// of the middle would reorder the z-stack: a mark drawn under a blur would
    /// come back out on top of it. Everything up to and including the last
    /// redaction becomes permanent pixels; everything after stays editable.
    public func withAppliedSplit<T>(_ body: (AppliedSplit) async throws -> T) async throws -> T {
        try commitActiveEditForOutput()
        isFrozen = true
        defer { isFrozen = false }

        let splitIndex = items.lastIndex { $0.payload.isRedaction }.map { $0 + 1 } ?? 0
        let permanent = Array(items[..<splitIndex])
        let editable = Array(items[splitIndex...])

        let newBase = permanent.isEmpty
            ? source
            : try await compositor.renderForOutput(base: source, items: permanent,
                                                   pixelSize: pixelSize)

        // AnnotationFilterKey is kind + rect; it does NOT identify the base. Two
        // passes over two different bases through one cache is exactly the shape
        // that serves a derivative of the wrong image, and for a redaction that
        // is a privacy defect rather than a cosmetic one. `editable` cannot
        // contain a filter by construction, so this costs nothing today and
        // keeps it correct if that ever stops being true.
        await compositor.filterCache().evictAll()

        let flattened = editable.isEmpty
            ? newBase
            : try await compositor.renderForOutput(base: newBase, items: editable,
                                                   pixelSize: pixelSize)

        return try await body(AppliedSplit(base: newBase,
                                           flattened: flattened,
                                           editableItems: editable))
    }

    /// Re-open a stored image with its saved marks.
    ///
    /// The loaded state is the baseline, not an edit: history starts empty and
    /// `isDirty` stays false, so reopening and closing writes nothing and Escape
    /// does not demand a decision about changes nobody made.
    public func adoptRestored(items restored: [AnnotationItem]) {
        undoStack.removeAll()
        redoStack.removeAll()
        items = restored
        selectedItemID = nil
        pendingText = nil
        // Past the highest existing counter, so a new one does not repeat a
        // number already on the image.
        counterSeed = restored.reduce(1) { seed, item in
            if case let .counter(number, _, _) = item.payload { return max(seed, number + 1) }
            return seed
        }
        baselineItems = restored
        isDirty = false
        generation += 1
        refreshHistoryFlags()
        Task { await requestComposite() }
    }

    /// After Apply: start a fresh generation from the flattened result.
    public func adoptFlattened() {
        undoStack.removeAll()
        redoStack.removeAll()
        items.removeAll()
        baselineItems = []
        selectedItemID = nil
        pendingText = nil
        counterSeed = 1
        isDirty = false
        refreshHistoryFlags()
    }

    public func teardown() {
        items.removeAll()
        baselineItems = []
        undoStack.removeAll()
        redoStack.removeAll()
        composite = nil
        patch = nil
        pendingText = nil
        Task { [compositor] in await compositor.reset() }
    }

    // MARK: - Hit testing

    /// Topmost item whose drawn shape is within `tolerance` source pixels of
    /// `point`. Iterates in reverse because the list is z-ordered bottom to top.
    public func hitTest(_ point: CGPoint, tolerance: CGFloat) -> AnnotationItem? {
        for item in items.reversed() {
            if hits(item, point: point, tolerance: tolerance) { return item }
        }
        return nil
    }

    private func hits(_ item: AnnotationItem, point: CGPoint, tolerance: CGFloat) -> Bool {
        let slack = max(tolerance, item.strokeWidth)
        switch item.payload {
        case let .line(from, to):
            return distance(from: point, toSegment: from, to) <= slack
        case let .arrow(from, to, _):
            // Hit-tested against the straight segment even when curved: close
            // enough for a 6pt tolerance and far cheaper than sampling the curve.
            return distance(from: point, toSegment: from, to) <= slack
        case let .rect(r), let .blur(r), let .pixelate(r):
            let box = r.standardized
            if case .rect = item.payload {
                // An unfilled rectangle is only hit near its edge.
                return box.insetBy(dx: -slack, dy: -slack).contains(point)
                    && !box.insetBy(dx: slack, dy: slack).contains(point)
            }
            return box.insetBy(dx: slack, dy: slack).contains(point)
        case let .oval(r):
            let box = r.standardized
            guard box.width > 0, box.height > 0 else { return false }
            let nx = (point.x - box.midX) / (box.width / 2)
            let ny = (point.y - box.midY) / (box.height / 2)
            let d = (nx * nx + ny * ny).squareRoot()
            let band = slack / max(box.width, box.height) * 2
            return abs(d - 1) <= max(band, 0.12)
        case let .freehand(points), let .highlighter(points):
            guard points.count > 1 else {
                return points.first.map { hypot($0.x - point.x, $0.y - point.y) <= slack } ?? false
            }
            for i in 0..<(points.count - 1) {
                if distance(from: point, toSegment: points[i], points[i + 1]) <= slack { return true }
            }
            return false
        case .text, .counter:
            return item.bounds.insetBy(dx: -slack, dy: -slack).contains(point)
        }
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
        t = min(max(t, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
