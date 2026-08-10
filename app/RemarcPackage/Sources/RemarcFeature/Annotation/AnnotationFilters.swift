import Foundation
import CoreImage
import CoreGraphics

/// Cache key for a filter derivative.
///
/// **Never includes a zoom factor.** A redaction that looks opaque on a magnified
/// stage but under-redacts in the file is a privacy defect, and keying by zoom is
/// exactly how that happens: the cached image would carry the editor's display
/// scale into the export.
public struct AnnotationFilterKey: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case blur, pixelate }
    public let kind: Kind
    /// Source-pixel rect, quantized so sub-pixel jitter during a drag does not
    /// produce a new cache entry per mouse event.
    public let x: Int, y: Int, width: Int, height: Int

    public init(kind: Kind, rect: CGRect) {
        self.kind = kind
        let r = rect.standardized.integral
        self.x = Int(r.minX); self.y = Int(r.minY)
        self.width = Int(r.width); self.height = Int(r.height)
    }

    public var rect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}

/// Blur and pixelate derivatives of the immutable source image.
///
/// Filters always sample the **base**, never already-annotated pixels, so a filter
/// placed below a vector in the z-order does not smear that vector.
///
/// Both filters are destructive by construction: every output pixel is a
/// weighted average of a neighbourhood, so no original value is carried through
/// either one. Pixelate blurs by half a cell before forming the cells for
/// exactly this reason - `CIPixellate` on its own point-samples each cell
/// centre, which left the region holding real original pixels at full fidelity,
/// subsampled one per cell.
///
/// They remain visual obscuration rather than a security guarantee. The averages
/// still describe the region, so low-entropy content - a short PIN, a value from
/// a known small set - can be narrowed by someone who knows what they are
/// looking for. Reach for a solid rectangle when the content must be gone
/// rather than unreadable.
public final class AnnotationFilterCache: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [AnnotationFilterKey: CGImage] = [:]
    private let ciContext: CIContext

    /// Approximate bytes held by cached derivatives. Read under the lock: the
    /// compositor consults it from its own executor while renders populate the
    /// cache from a detached task.
    private var _byteCount: Int = 0
    public var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _byteCount
    }

    public init() {
        // Software rendering keeps this usable from a detached task without
        // fighting for the GPU with the compositor's own draws.
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
    }

    /// Blur radius and pixelate cell scale with the region, so a small redaction is
    /// as unreadable as a large one. Both are pure functions of source pixels.
    public static func blurRadius(for rect: CGRect) -> CGFloat {
        max(8, min(rect.width, rect.height) / 8)
    }

    public static func pixelateScale(for rect: CGRect) -> CGFloat {
        max(6, min(rect.width, rect.height) / 10)
    }

    public func image(for key: AnnotationFilterKey, base: CGImage) -> CGImage? {
        lock.lock()
        if let hit = storage[key] { lock.unlock(); return hit }
        lock.unlock()

        guard let produced = render(key: key, base: base) else { return nil }

        lock.lock()
        // Re-check: two callers can miss concurrently and both render, and adding
        // both sizes would double-count the one that loses.
        if let raced = storage[key] {
            lock.unlock()
            return raced
        }
        storage[key] = produced
        _byteCount += produced.height * produced.bytesPerRow
        lock.unlock()
        return produced
    }

    private func render(key: AnnotationFilterKey, base: CGImage) -> CGImage? {
        let rect = key.rect
        guard rect.width >= 1, rect.height >= 1 else { return nil }

        // CGImage is top-left origin; CIImage is bottom-left. Flip the crop rect.
        let ciBase = CIImage(cgImage: base)
        let flipped = CGRect(x: rect.minX,
                             y: CGFloat(base.height) - rect.maxY,
                             width: rect.width, height: rect.height)

        let output: CIImage?
        switch key.kind {
        case .blur:
            // Clamp before blurring, or the filter samples transparent black
            // outside the image and the region's edges wash out.
            let clamped = ciBase.clampedToExtent()
            output = clamped
                .applyingFilter("CIGaussianBlur",
                                parameters: [kCIInputRadiusKey: Self.blurRadius(for: rect)])
                .cropped(to: flipped)
        case .pixelate:
            let scale = Self.pixelateScale(for: rect)
            // Averaged into each cell BEFORE the cells are formed.
            //
            // `CIPixellate` alone point-samples the centre of every cell, it does
            // not average one: measured directly, a striped region through it at
            // scale 6 comes back holding exactly two distinct colours, both of
            // them original. So the obscured region was a subsample of the
            // secret - one real pixel out of every cell, kept at full fidelity -
            // rather than something derived from it. Blurring first by half the
            // cell means the pixel that gets sampled is already a weighted
            // average of its neighbourhood, so no original value survives while
            // the flat blocky result looks exactly the same.
            let clamped = ciBase.clampedToExtent()
            output = clamped
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: scale / 2])
                .clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputCenterKey: CIVector(x: flipped.midX, y: flipped.midY)
                ])
                .cropped(to: flipped)
        }

        guard let output else { return nil }
        return ciContext.createCGImage(output, from: flipped)
    }

    /// Drop derivatives. The compositor evicts these first when the total raster
    /// budget is exceeded, because they are the only rasters that can be
    /// regenerated without user-visible loss.
    public func evictAll() {
        lock.lock()
        storage.removeAll()
        _byteCount = 0
        lock.unlock()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }
}
