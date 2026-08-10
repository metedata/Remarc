import AppKit

// Does CGWindowListCreateImage(.optionOnScreenBelowWindow) see through a
// full-alpha dimming overlay? Puts a known pure-red window on screen, covers it
// with a 50%-black overlay at .screenSaver, grabs below the overlay, and samples
// the centre pixel. Pure red means the grab ignored the overlay (design holds).
// Dark red means it did not (design is moot).

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard CGPreflightScreenCaptureAccess() else {
    print("FAIL: no screen recording permission for this process.")
    print("Grant Terminal (or the host app) Screen Recording in System Settings, then rerun.")
    CGRequestScreenCaptureAccess()
    exit(2)
}

let target = NSRect(x: 300, y: 300, width: 400, height: 300)

// 1. A known pure-red window underneath.
let red = NSWindow(contentRect: target, styleMask: .borderless, backing: .buffered, defer: false)
red.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
red.isOpaque = true
red.level = .normal
red.orderFrontRegardless()

// 2. A dimming overlay above it, exactly as RegionSelectionView draws it.
final class Dim: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: bounds).fill()
    }
}
let overlayFrame = target.insetBy(dx: -100, dy: -100)
let overlay = NSPanel(contentRect: overlayFrame, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
overlay.backgroundColor = .clear
overlay.isOpaque = false
overlay.hasShadow = false
overlay.level = .screenSaver
overlay.contentView = Dim(frame: NSRect(origin: .zero, size: overlayFrame.size))
overlay.orderFrontRegardless()

RunLoop.current.run(until: Date().addingTimeInterval(1.0))

// 3. Grab below the overlay, in Quartz coordinates (top-left origin).
let primaryHeight = NSScreen.screens.first?.frame.height ?? target.height
let quartz = CGRect(x: target.origin.x,
                    y: primaryHeight - target.origin.y - target.height,
                    width: target.width, height: target.height)
let wid = CGWindowID(overlay.windowNumber)

guard let image = CGWindowListCreateImage(quartz, .optionOnScreenBelowWindow, wid, [.bestResolution]) else {
    print("FAIL: CGWindowListCreateImage returned nil")
    exit(1)
}

// 4. Sample the centre pixel.
let w = image.width, h = image.height
guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { exit(1) }
var px: [UInt8] = [0, 0, 0, 0]
guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.draw(image, in: CGRect(x: -CGFloat(w / 2), y: -CGFloat(h / 2),
                           width: CGFloat(w), height: CGFloat(h)))

print("grabbed \(w)x\(h), centre pixel RGBA = \(px[0]), \(px[1]), \(px[2]), \(px[3])")
if px[0] > 240 && px[1] < 40 && px[2] < 40 {
    print("PASS: grab ignored the full-alpha overlay. Freeze-on-toggle is viable.")
    exit(0)
} else if px[0] > 100 && px[0] < 200 {
    print("FAIL: grab captured DIMMED pixels. Freeze-on-toggle as specced is not viable.")
    exit(1)
} else {
    print("INCONCLUSIVE: unexpected colour. Check window ordering and rerun.")
    exit(3)
}
