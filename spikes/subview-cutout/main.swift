import AppKit

// Three questions, all unverified in this codebase:
//  (a) does a plain non-layer-backed child draw OPAQUE pixels over a region the
//      superview cleared with .clear compositing?
//  (b) does the parent's cutout still produce transparency when no child is present?
//  (c) does adding the child CHANGE the parent's layer-backing state?
//
// (b) is measured against a known pure-red window placed underneath, not against
// the desktop: an unknown wallpaper colour cannot distinguish "transparent" from
// "50% black over something already dark".
//
// (c) is measured BEFORE and AFTER. `nil` after is not the question - a window's
// contentView is layer-backed by AppKit itself on every modern macOS - the
// question is whether adding a subview changes it.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard CGPreflightScreenCaptureAccess() else {
    print("FAIL: no screen recording permission for this process.")
    exit(2)
}

let frame = NSRect(x: 400, y: 400, width: 400, height: 300)
let cutout = NSRect(x: 100, y: 75, width: 200, height: 150)

// A known pure-red backdrop, so (b) has an unambiguous expected value.
let red = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
red.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
red.isOpaque = true
red.level = .normal
red.orderFrontRegardless()

final class Parent: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(rect: bounds).fill()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(roundedRect: cutout, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }
}

final class Child: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).setFill()   // pure green
        NSBezierPath(rect: bounds).fill()
    }
}

let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.backgroundColor = .clear
panel.isOpaque = false
panel.hasShadow = false
panel.level = .screenSaver
let parent = Parent(frame: NSRect(origin: .zero, size: frame.size))
panel.contentView = parent
panel.orderFrontRegardless()
RunLoop.current.run(until: Date().addingTimeInterval(0.6))

func samplePixel(at screenPoint: CGPoint) -> [UInt8] {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let q = CGRect(x: screenPoint.x, y: primaryHeight - screenPoint.y, width: 1, height: 1)
    guard let img = CGWindowListCreateImage(q, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution]),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return [0, 0, 0, 0] }
    var px: [UInt8] = [0, 0, 0, 0]
    guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return px }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(img.width), height: CGFloat(img.height)))
    return px
}

let centre = CGPoint(x: frame.minX + cutout.midX, y: frame.minY + cutout.midY)
let dimmed = CGPoint(x: frame.minX + 20, y: frame.minY + 20)   // inside the panel, outside the cutout

let layerBefore = parent.layer
let cutoutPixel = samplePixel(at: centre)
let dimPixel = samplePixel(at: dimmed)
print("(b) cutout, NO child      = \(cutoutPixel)   [expect ~255,0,0 - the red backdrop showing through]")
print("    dimmed area, NO child = \(dimPixel)   [expect ~127,0,0 - 50% black over red]")

let child = Child(frame: cutout)
parent.addSubview(child)
parent.needsDisplay = true
RunLoop.current.run(until: Date().addingTimeInterval(0.6))
let layerAfter = parent.layer

let withChild = samplePixel(at: centre)
let dimAfter = samplePixel(at: dimmed)
print("(a) cutout, WITH child    = \(withChild)   [expect pure green 0,255,0]")
print("    dimmed area, WITH child = \(dimAfter)   [expect ~127,0,0 - still dimmed]")
print("(c) parent.layer before = \(layerBefore.map { "\($0)" } ?? "nil")")
print("    parent.layer after  = \(layerAfter.map { "\($0)" } ?? "nil")")
print("    child.layer         = \(child.layer.map { "\($0)" } ?? "nil")")
print("    layer identity unchanged by addSubview -> \(layerBefore === layerAfter)")
print("    parent.wantsLayer   = \(parent.wantsLayer)   child.wantsLayer = \(child.wantsLayer)")

let cutoutTransparent = cutoutPixel[0] > 200 && cutoutPixel[1] < 50 && cutoutPixel[2] < 50
let dimStillDims = dimPixel[0] > 90 && dimPixel[0] < 190
let opaqueGreen = withChild[1] > 240 && withChild[0] < 40 && withChild[2] < 40
let dimSurvives = dimAfter[0] > 90 && dimAfter[0] < 190
let backingUnchanged = layerBefore === layerAfter

print("")
print("(a) opaque child over cleared region : \(opaqueGreen ? "PASS" : "FAIL")")
print("(b) cutout is genuinely transparent  : \(cutoutTransparent ? "PASS" : "FAIL")")
print("    dim fill survives adding a child : \(dimStillDims && dimSurvives ? "PASS" : "FAIL")")
print("(c) addSubview leaves backing alone  : \(backingUnchanged ? "PASS" : "FAIL")")

if opaqueGreen && cutoutTransparent && dimStillDims && dimSurvives && backingUnchanged {
    print("PASS: an opaque child composites over the cleared region and disturbs nothing else.")
    exit(0)
} else {
    print("FAIL: see the per-question lines above.")
    exit(1)
}
