import AppKit

extension NSImage {
    /// Converts the image to PNG data via TIFF → NSBitmapImageRep → PNG.
    /// Returns nil if any step fails.
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmapRep.representation(using: .png, properties: [:])
    }

    /// Creates a stretchable rounded-rect mask image for NSVisualEffectView.
    /// The mask tells the window server compositor the actual shape for backdrop blur.
    static func roundedRectMask(cornerRadius: CGFloat) -> NSImage {
        let edge = 2.0 * cornerRadius + 1.0
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(
            top: cornerRadius, left: cornerRadius,
            bottom: cornerRadius, right: cornerRadius
        )
        img.resizingMode = .stretch
        return img
    }
}
