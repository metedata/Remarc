import Foundation
import CoreGraphics

/// Maps between a surface's canvas coordinates and source-image pixels.
///
/// Both axes carry their own scale: `.bestResolution` guarantees no fixed
/// relationship between the selection's size and the returned image's size, so a
/// single scalar would be wrong whenever the aspect drifts.
///
/// On the capture surface `canvasBounds` is the pixel size itself, making this the
/// identity; the preview surface exercises the general path.
public struct AnnotationViewport: Equatable, Sendable {

    public let pixelSize: CGSize
    public let canvasBounds: CGRect

    public init(pixelSize: CGSize, canvasBounds: CGRect) {
        self.pixelSize = pixelSize
        self.canvasBounds = canvasBounds
    }

    /// Source pixels per canvas unit.
    public var scaleX: CGFloat {
        guard canvasBounds.width > 0 else { return 1 }
        return pixelSize.width / canvasBounds.width
    }

    public var scaleY: CGFloat {
        guard canvasBounds.height > 0 else { return 1 }
        return pixelSize.height / canvasBounds.height
    }

    /// Canvas point to source pixel, clipped to the image.
    public func pixel(fromCanvas point: CGPoint) -> CGPoint {
        let x = (point.x - canvasBounds.minX) * scaleX
        let y = (point.y - canvasBounds.minY) * scaleY
        return CGPoint(x: min(max(x, 0), pixelSize.width),
                       y: min(max(y, 0), pixelSize.height))
    }

    /// Source pixel back to canvas point.
    public func canvas(fromPixel point: CGPoint) -> CGPoint {
        CGPoint(x: canvasBounds.minX + point.x / scaleX,
                y: canvasBounds.minY + point.y / scaleY)
    }

    /// Converts a screen-constant chrome measurement into source pixels, so
    /// selection outlines and hit tolerances stay the same visual size at any zoom.
    /// Mark geometry must NEVER go through this.
    public func chromeUnits(_ points: CGFloat) -> CGSize {
        CGSize(width: points * scaleX, height: points * scaleY)
    }
}
