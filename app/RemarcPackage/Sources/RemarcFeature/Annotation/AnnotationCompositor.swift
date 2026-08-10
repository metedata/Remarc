import Foundation
import CoreGraphics

/// Source-resolution composite rendering, off the main actor, generation-numbered.
///
/// **Actor isolation alone does not give the one-render invariant.** Swift's
/// concurrency guide is explicit that actors do not guarantee atomicity across
/// suspension points: if a render method suspends, another submission enters the
/// actor and interleaves. Writing `actor` and expecting the runtime to serialize
/// whole renders would be wrong, and the two-raster memory bound assumes it.
///
/// So the invariant is enforced by state:
///
///  - the render body is a `nonisolated` synchronous function containing no
///    `await`, so it cannot be interleaved partway through
///  - `inFlight` records the running generation, and a submission arriving while
///    one is in flight becomes the single `pending` generation, replacing any
///    earlier one, rather than starting a second render
///  - when the in-flight render completes, the actor publishes it and only then
///    starts the pending generation
///
/// That gives at most one running render and at most one queued generation.
public actor AnnotationCompositor {

    public struct Snapshot: Sendable {
        public let generation: Int
        public let base: CGImage
        public let items: [AnnotationItem]
        public let pixelSize: CGSize
        /// Output pixels per source pixel for the DISPLAY raster. Export never uses
        /// this; `renderForOutput` always renders at 1.
        public let displayScale: CGFloat

        public init(generation: Int, base: CGImage, items: [AnnotationItem],
                    pixelSize: CGSize, displayScale: CGFloat = 1) {
            self.generation = generation
            self.base = base
            self.items = items
            self.pixelSize = pixelSize
            self.displayScale = displayScale
        }
    }

    private let filters = AnnotationFilterCache()

    private var inFlight: Int?
    private var pending: Snapshot?

    public private(set) var publishedGeneration: Int = -1
    private var publishedImage: CGImage?

    private struct Waiter {
        let generation: Int
        let continuation: CheckedContinuation<CGImage, Error>
    }
    private var waiters: [Waiter] = []

    /// Bumped by `reset()`. A render started before the reset carries the old epoch
    /// and is discarded on completion, so a torn-down session cannot republish a
    /// composite into a compositor that has already been cleared.
    private var epoch = 0

    /// Total budget across **every** raster on this surface, not a per-item
    /// estimate: source, filter derivatives, the published composite, and the
    /// in-flight one. Two full rasters at 5120x2880 BGRA are already about
    /// 112 MiB, so a budget that omits the caches is an estimate rather than
    /// something enforceable.
    private let rasterBudgetBytes: Int

    public init(rasterBudgetBytes: Int = 320 * 1024 * 1024) {
        self.rasterBudgetBytes = rasterBudgetBytes
    }

    public enum CompositorError: Error, Equatable {
        case renderFailed(String)
        case cancelled
    }

    // MARK: - Submission

    public func submit(_ snapshot: Snapshot) async {
        // Already rendered and published. Re-rendering it is pure waste, and during
        // a drag the same generation can arrive more than once.
        if snapshot.generation <= publishedGeneration, publishedImage != nil {
            resumeWaiters(upTo: publishedGeneration, with: .success(publishedImage!))
            return
        }
        guard inFlight == nil else {
            // Supersede any queued generation below this one that has not started.
            // Intermediate generations are dropped rather than rendered and thrown
            // away.
            if (pending?.generation ?? Int.min) < snapshot.generation {
                pending = snapshot
            }
            return
        }

        var current = snapshot
        while true {
            let startedEpoch = epoch
            inFlight = current.generation
            enforceBudget(for: current)

            let cache = filters
            let job = current
            let result: Result<CGImage, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try AnnotationRenderer.render(
                        base: job.base, items: job.items,
                        pixelSize: job.pixelSize, filters: cache,
                        scale: job.displayScale))
                } catch {
                    return .failure(error)
                }
            }.value

            inFlight = nil

            // A reset landed while this was rendering. Publishing now would revive
            // a composite for a session that has already been torn down.
            guard startedEpoch == epoch else { return }

            switch result {
            case .success(let image):
                if current.generation > publishedGeneration {
                    publishedGeneration = current.generation
                    publishedImage = image
                }
                resumeWaiters(upTo: current.generation, with: .success(image))
            case .failure(let error):
                // Resume EVERY waiter, not just the matching generation. A waiter
                // for a generation this render superseded would otherwise stay
                // suspended forever.
                resumeWaiters(upTo: .max,
                              with: .failure(CompositorError.renderFailed("\(error)")))
            }

            guard let next = pending else { break }
            pending = nil
            current = next
        }
    }

    /// The composite at or after `generation`.
    ///
    /// The output barrier - export, prepare, Copy, Apply - takes a scoped freeze
    /// token that suspends canvas mutation before calling this, which fixes the
    /// target. Awaiting "whichever generation is current" could starve while the
    /// user keeps drawing; awaiting a fixed generation without freezing could hang
    /// once superseded, which is why the failure path resumes everything.
    public func composite(atLeast generation: Int) async throws -> CGImage {
        if publishedGeneration >= generation, let image = publishedImage { return image }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(generation: generation, continuation: continuation))
        }
    }

    public func latestPublished() -> (generation: Int, image: CGImage)? {
        guard let publishedImage else { return nil }
        return (publishedGeneration, publishedImage)
    }

    /// Render a dirty region synchronously for the transient patch. Called from the
    /// main actor during a drag, so it is deliberately scoped to the dirty rect:
    /// a full-frame composite per mouse event is untenable at 5K.
    /// - Parameter scale: must match the committed raster's display scale, or the
    ///   mark under the cursor is rasterized at source resolution and blown up
    ///   while every committed mark beside it is crisp - the stroke visibly
    ///   sharpens at mouse-up, which is exactly the artefact the display-scale
    ///   render exists to remove.
    public nonisolated static func patch(
        base: CGImage, items: [AnnotationItem], pixelSize: CGSize,
        region: CGRect, filters: AnnotationFilterCache, scale: CGFloat = 1
    ) -> CGImage? {
        try? AnnotationRenderer.renderRegion(
            base: base, items: items, pixelSize: pixelSize, region: region,
            filters: filters, scale: scale)
    }

    /// The **export** raster: always exactly `pixelSize`, never the display scale,
    /// and deliberately not sharing the published display raster.
    ///
    /// Once the editor renders at the display's device-pixel ratio so magnified
    /// strokes are not jagged, the on-screen raster is no longer the same object as
    /// the file. What is guaranteed instead, and what the tests assert, is that both
    /// come from the same renderer and the same item list, and that the file is
    /// exactly the source pixel dimensions.
    public func renderForOutput(base: CGImage, items: [AnnotationItem],
                                pixelSize: CGSize) throws -> CGImage {
        try AnnotationRenderer.render(base: base, items: items,
                                      pixelSize: pixelSize, filters: filters, scale: 1)
    }

    public func filterCache() -> AnnotationFilterCache { filters }

    public func reset() {
        epoch &+= 1
        inFlight = nil
        pending = nil
        publishedImage = nil
        publishedGeneration = -1
        filters.evictAll()
        resumeWaiters(upTo: .max, with: .failure(CompositorError.cancelled))
    }

    // MARK: - Internals

    private func resumeWaiters(upTo generation: Int, with result: Result<CGImage, Error>) {
        guard !waiters.isEmpty else { return }
        let satisfied = waiters.filter { $0.generation <= generation }
        waiters.removeAll { $0.generation <= generation }
        for waiter in satisfied {
            switch result {
            case .success(let image): waiter.continuation.resume(returning: image)
            case .failure(let error): waiter.continuation.resume(throwing: error)
            }
        }
    }

    /// Evict filter derivatives first: they are the only rasters regenerable
    /// without user-visible loss.
    private func enforceBudget(for snapshot: Snapshot) {
        let scaled = CGSize(width: snapshot.pixelSize.width * snapshot.displayScale,
                            height: snapshot.pixelSize.height * snapshot.displayScale)
        let raster = AnnotationRenderer.rasterBytes(scaled)
        // source + published + the one about to be produced
        let committed = raster * (publishedImage == nil ? 2 : 3)
        if committed + filters.byteCount > rasterBudgetBytes {
            filters.evictAll()
        }
    }
}
