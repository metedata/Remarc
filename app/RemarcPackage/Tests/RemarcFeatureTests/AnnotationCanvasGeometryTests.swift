import XCTest
import AppKit
@testable import RemarcFeature

/// The coordinate contract the whole magnification design rests on.
@MainActor
final class AnnotationCanvasGeometryTests: XCTestCase {

    private let pixelSize = CGSize(width: 400, height: 160)

    private func makeCanvas() -> AnnotationCanvasNSView {
        let source = TestImages.solid(width: 400, height: 160, red: 1, green: 0, blue: 0)
        let session = AnnotationSession(source: source)
        return AnnotationCanvasNSView(pixelSize: pixelSize, session: session)
    }

    /// Setting `bounds` to a size different from `frame` does NOT pin the
    /// coordinate system: AppKit records a scale factor and preserves it across
    /// later frame changes. This asserts at every ladder step rather than only at
    /// setup, because a setup-only assertion passes against the broken form.
    func testBoundsStayThePixelSizeAtEveryZoomStep() {
        let canvas = makeCanvas()
        for zoom in [1, 2, 4, 8] {
            canvas.setFrameSize(NSSize(width: pixelSize.width * CGFloat(zoom),
                                       height: pixelSize.height * CGFloat(zoom)))
            XCTAssertEqual(canvas.bounds.size, pixelSize,
                           "bounds drifted at z=\(zoom): \(canvas.bounds.size)")
            XCTAssertEqual(canvas.frame.size,
                           NSSize(width: pixelSize.width * CGFloat(zoom),
                                  height: pixelSize.height * CGFloat(zoom)))
        }
    }

    func testCornersMapToTheImageCornersAtEveryZoomStep() {
        let canvas = makeCanvas()
        // One host for every step: `convert(_:from:)` needs a real ancestor
        // relationship, and rebuilding it per iteration would leave the canvas
        // parented to a stale view.
        let host = NSView(frame: CGRect(x: 0, y: 0, width: 4000, height: 4000))
        host.addSubview(canvas)

        for zoom in [1, 2, 4, 8] {
            let scale = CGFloat(zoom)
            canvas.frame = CGRect(x: 0, y: 0,
                                  width: pixelSize.width * scale,
                                  height: pixelSize.height * scale)

            let topLeft = canvas.convert(CGPoint(x: 0, y: canvas.frame.maxY), from: host)
            let bottomRight = canvas.convert(CGPoint(x: canvas.frame.maxX, y: 0), from: host)

            XCTAssertEqual(topLeft.x, 0, accuracy: 0.001, "z=\(zoom)")
            XCTAssertEqual(topLeft.y, 0, accuracy: 0.001, "z=\(zoom) (flipped: top is y=0)")
            XCTAssertEqual(bottomRight.x, pixelSize.width, accuracy: 0.001, "z=\(zoom)")
            XCTAssertEqual(bottomRight.y, pixelSize.height, accuracy: 0.001, "z=\(zoom)")
        }
    }

    func testViewportIsBitIdenticalAcrossZoomChanges() {
        let canvas = makeCanvas()
        let atOne = canvas.viewport
        canvas.setFrameSize(NSSize(width: 1600, height: 640))
        XCTAssertEqual(canvas.viewport, atOne,
                       "the viewport must not depend on the display scale")
    }

    func testCanvasIsFlipped() {
        // Supplies the Y flip. `setBoundsSize` cannot express one, so this is the
        // only thing standing between stored geometry and a mirrored export.
        XCTAssertTrue(makeCanvas().isFlipped)
    }

    /// The preview panel sets `isMovableByWindowBackground`, and AppKit consults
    /// `mouseDownCanMoveWindow` before it dispatches `mouseDown(with:)`. NSView's
    /// default returns true for a non-opaque view, so every drag on the canvas
    /// moved the window and drew nothing.
    func testCanvasNeverDragsTheHostWindow() {
        XCTAssertFalse(makeCanvas().mouseDownCanMoveWindow)
    }

    /// Frozen is the state during Apply. It must still swallow the drag rather
    /// than fall through to a window move.
    func testCanvasStillRefusesToDragTheWindowWhileFrozen() {
        let canvas = makeCanvas()
        canvas.isInputEnabled = false
        XCTAssertFalse(canvas.mouseDownCanMoveWindow)
    }

    func testArrowIsTheUnmodifiedAShortcut() {
        // Plain Command-A is Select All in the comment field, so `A` alone is the
        // arrow tool and Shift-Command-A is the annotation entry.
        XCTAssertEqual(AnnotationCanvasNSView.tool(forShortcut: "a"), .arrow)
        XCTAssertEqual(AnnotationCanvasNSView.tool(forShortcut: "v"), .select)
        XCTAssertNil(AnnotationCanvasNSView.tool(forShortcut: "q"))
    }

    /// Chrome is measured from the STAGE scale, not from the viewport.
    ///
    /// The canvas pins `bounds` to `pixelSize` on every path, so the viewport's
    /// scale is identically 1 and chrome derived from it never changed with zoom:
    /// the hit tolerance stayed 6 source pixels, which at 4x is 1.5 points on
    /// screen.
    func testChromeShrinksInSourcePixelsAsTheStageGrows() {
        let atOne = ChromeMetrics.make(stageScale: CGSize(width: 1, height: 1))
        let atFour = ChromeMetrics.make(stageScale: CGSize(width: 4, height: 4))

        XCTAssertEqual(atOne.hitTolerance, 6, accuracy: 0.001)
        XCTAssertEqual(atFour.hitTolerance, 1.5, accuracy: 0.001,
                       "6 on-screen points is 1.5 source pixels once the stage is 4x")
        XCTAssertLessThan(atFour.handleRadius, atOne.handleRadius)
    }

    func testChromeTracksTheCanvasFrameToBoundsRatio() {
        let canvas = makeCanvas()
        XCTAssertEqual(canvas.stageScale.width, 1, accuracy: 0.001)
        canvas.setFrameSize(NSSize(width: pixelSize.width * 4, height: pixelSize.height * 4))
        XCTAssertEqual(canvas.stageScale.width, 4, accuracy: 0.001)
        XCTAssertEqual(canvas.stageScale.height, 4, accuracy: 0.001)
        XCTAssertEqual(canvas.chrome.hitTolerance, 1.5, accuracy: 0.001)
    }
}

// MARK: - Fixtures

enum TestImages {
    static func solid(width: Int, height: Int,
                      red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// RGBA at a top-left-origin pixel coordinate.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var px: [UInt8] = [0, 0, 0, 0]
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: &px, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return px }
        // Shift the image so (x, y) lands on the single-pixel context. CGContext is
        // bottom-left origin, so the Y coordinate is mirrored.
        ctx.draw(image, in: CGRect(x: CGFloat(-x),
                                   y: CGFloat(y - image.height + 1),
                                   width: CGFloat(image.width),
                                   height: CGFloat(image.height)))
        return px
    }
}
