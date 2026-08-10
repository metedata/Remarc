import XCTest
import CoreGraphics
@testable import RemarcFeature

final class AnnotationRendererTests: XCTestCase {

    private let size = CGSize(width: 200, height: 100)
    private lazy var base = TestImages.solid(width: 200, height: 100, red: 1, green: 0, blue: 0)
    private lazy var filters = AnnotationFilterCache()

    private func blue(_ alpha: CGFloat = 1) -> AnnotationInk {
        AnnotationInk(red: 0, green: 0, blue: 1, alpha: alpha)
    }

    func testOutputIsAlwaysExactlyThePixelSize() throws {
        let image = try AnnotationRenderer.render(
            base: base, items: [], pixelSize: size, filters: filters)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 100)
    }

    func testAnEmptyItemListReproducesTheSource() throws {
        let image = try AnnotationRenderer.render(
            base: base, items: [], pixelSize: size, filters: filters)
        let px = TestImages.pixel(image, x: 100, y: 50)
        XCTAssertGreaterThan(px[0], 240)
        XCTAssertLessThan(px[1], 20)
    }

    /// Geometry is top-left origin. A filled mark in the TOP half must land in the
    /// top half of the output, not mirrored into the bottom.
    func testGeometryIsTopLeftOriginNotMirrored() throws {
        let item = AnnotationItem(payload: .rect(CGRect(x: 10, y: 5, width: 180, height: 20)),
                                  ink: blue(), strokeWidth: 10)
        let image = try AnnotationRenderer.render(
            base: base, items: [item], pixelSize: size, filters: filters)

        let nearTop = TestImages.pixel(image, x: 100, y: 8)
        let nearBottom = TestImages.pixel(image, x: 100, y: 92)
        XCTAssertGreaterThan(nearTop[2], 120, "the mark must be at the TOP")
        XCTAssertLessThan(nearBottom[2], 60, "the bottom must still be the red source")
    }

    func testGlobalZOrderIsListOrder() throws {
        // Two overlapping filled shapes: the later one wins where they overlap.
        let under = AnnotationItem(payload: .counter(1, at: CGPoint(x: 100, y: 50), radius: 30),
                                   ink: AnnotationInk(red: 0, green: 1, blue: 0), strokeWidth: 4)
        let over = AnnotationItem(payload: .counter(2, at: CGPoint(x: 100, y: 50), radius: 20),
                                  ink: blue(), strokeWidth: 4)

        let image = try AnnotationRenderer.render(
            base: base, items: [under, over], pixelSize: size, filters: filters)
        let centre = TestImages.pixel(image, x: 100, y: 62)
        XCTAssertGreaterThan(centre[2], 100, "the later item must draw on top")

        let reversed = try AnnotationRenderer.render(
            base: base, items: [over, under], pixelSize: size, filters: filters)
        let reversedCentre = TestImages.pixel(reversed, x: 100, y: 62)
        XCTAssertGreaterThan(reversedCentre[1], 100, "reversing the list reverses the z-order")
    }

    /// A filter placed ABOVE a vector must still sample the immutable base, not the
    /// already-annotated pixels, or it would smear the vector into the blur.
    func testFiltersSampleTheImmutableBaseNotAnnotatedPixels() throws {
        let mark = AnnotationItem(payload: .rect(CGRect(x: 0, y: 0, width: 200, height: 100)),
                                  ink: blue(), strokeWidth: 30)
        let pixelate = AnnotationItem(payload: .pixelate(CGRect(x: 60, y: 30, width: 80, height: 40)),
                                      ink: blue(), strokeWidth: 1)

        let image = try AnnotationRenderer.render(
            base: base, items: [mark, pixelate], pixelSize: size, filters: filters)

        // Inside the pixelated region: the base is uniform red everywhere, so a
        // filter sampling the base yields red. One sampling the annotated raster
        // would drag the thick blue border inward.
        let inside = TestImages.pixel(image, x: 100, y: 50)
        XCTAssertGreaterThan(inside[0], 200, "the filter sampled the base")
        XCTAssertLessThan(inside[2], 60)
    }

    func testFilterCacheKeysIgnoreZoomEntirely() {
        // A key that carried a zoom factor would let a redaction look opaque on a
        // magnified stage and under-redact in the file.
        let rect = CGRect(x: 10, y: 20, width: 60, height: 40)
        XCTAssertEqual(AnnotationFilterKey(kind: .blur, rect: rect),
                       AnnotationFilterKey(kind: .blur, rect: rect))
        XCTAssertNotEqual(AnnotationFilterKey(kind: .blur, rect: rect),
                          AnnotationFilterKey(kind: .pixelate, rect: rect))
        // Sub-pixel jitter during a drag must not produce a new entry per event.
        XCTAssertEqual(AnnotationFilterKey(kind: .blur, rect: rect),
                       AnnotationFilterKey(kind: .blur, rect: rect.insetBy(dx: 0.2, dy: 0.2)))
    }

    func testFilterRadiusDependsOnlyOnSourcePixels() {
        let small = CGRect(x: 0, y: 0, width: 40, height: 40)
        let large = CGRect(x: 0, y: 0, width: 400, height: 400)
        XCTAssertLessThan(AnnotationFilterCache.blurRadius(for: small),
                          AnnotationFilterCache.blurRadius(for: large))
        XCTAssertGreaterThanOrEqual(AnnotationFilterCache.blurRadius(for: small), 8,
                                    "a small redaction must still be unreadable")
    }

    /// The pending patch is an opaque replacement for its rect, rendered from the
    /// base plus every current item intersecting it.
    func testARegionPatchIsExactlyItsRectAndOpaque() throws {
        let region = CGRect(x: 40, y: 20, width: 60, height: 30)
        let patch = try AnnotationRenderer.renderRegion(
            base: base, items: [], pixelSize: size, region: region, filters: filters)
        XCTAssertEqual(patch.width, 60)
        XCTAssertEqual(patch.height, 30)
        let px = TestImages.pixel(patch, x: 30, y: 15)
        XCTAssertGreaterThan(px[0], 240, "the patch carries the base, not transparency")
        XCTAssertEqual(px[3], 255)
    }

    func testAPatchCarriesMarksThatIntersectItsRegion() throws {
        let item = AnnotationItem(payload: .rect(CGRect(x: 40, y: 20, width: 60, height: 30)),
                                  ink: blue(), strokeWidth: 12)
        let patch = try AnnotationRenderer.renderRegion(
            base: base, items: [item], pixelSize: size,
            region: CGRect(x: 40, y: 20, width: 60, height: 30), filters: filters)
        let edge = TestImages.pixel(patch, x: 30, y: 3)
        XCTAssertGreaterThan(edge[2], 100)
    }

    func testARegionOutsideTheImageIsRejectedRatherThanCrashing() {
        XCTAssertThrowsError(try AnnotationRenderer.renderRegion(
            base: base, items: [], pixelSize: size,
            region: CGRect(x: 900, y: 900, width: 50, height: 50), filters: filters))
    }

    func testTextRendersAndIsNotSkippedByTheIntersectionTest() throws {
        // Text bounds are only known after layout, so a text item must never be
        // culled by the bounds intersection.
        let item = AnnotationItem(payload: .text("HELLO", at: CGPoint(x: 10, y: 10),
                                                pointSize: 40),
                                  ink: blue(), strokeWidth: 4)
        let image = try AnnotationRenderer.render(
            base: base, items: [item], pixelSize: size, filters: filters)

        var foundInk = false
        for x in stride(from: 10, to: 120, by: 2) {
            for y in stride(from: 10, to: 50, by: 2) {
                if TestImages.pixel(image, x: x, y: y)[2] > 100 { foundInk = true; break }
            }
            if foundInk { break }
        }
        XCTAssertTrue(foundInk, "no text ink was rendered")
    }

    /// Marks must be rasterized at the resolution they are DISPLAYED at. Drawing
    /// them at source resolution and upscaling 4x is what made every arrowhead and
    /// letter look jagged on a magnified stage.
    func testRenderScaleMultipliesTheOutputAndKeepsGeometry() throws {
        let item = AnnotationItem(payload: .rect(CGRect(x: 50, y: 20, width: 100, height: 60)),
                                  ink: blue(), strokeWidth: 6)
        let atOne = try AnnotationRenderer.render(
            base: base, items: [item], pixelSize: size, filters: filters, scale: 1)
        let atFour = try AnnotationRenderer.render(
            base: base, items: [item], pixelSize: size, filters: filters, scale: 4)

        XCTAssertEqual(atOne.width, 200)
        XCTAssertEqual(atFour.width, 800)
        XCTAssertEqual(atFour.height, 400)

        // Same geometry in both: the mark's top edge sits at source y=20, which is
        // y=80 in the 4x raster.
        XCTAssertGreaterThan(TestImages.pixel(atOne, x: 100, y: 21)[2], 100)
        XCTAssertGreaterThan(TestImages.pixel(atFour, x: 400, y: 84)[2], 100)
    }

    func testAScaleBelowOneIsClampedRatherThanShrinkingTheOutput() throws {
        let image = try AnnotationRenderer.render(
            base: base, items: [], pixelSize: size, filters: filters, scale: 0.25)
        XCTAssertEqual(image.width, 200, "output must never fall below source resolution")
    }

    /// Each style has to put ink somewhere the others do not, or they are the same
    /// arrow with four names.
    func testEachArrowStyleRendersDistinctly() throws {
        let from = CGPoint(x: 20, y: 50), to = CGPoint(x: 180, y: 50)
        var signatures: [String: [UInt8]] = [:]
        for style in AnnotationArrowStyle.allCases {
            let item = AnnotationItem(payload: .arrow(from: from, to: to, style: style),
                                      ink: blue(), strokeWidth: 6)
            let image = try AnnotationRenderer.render(
                base: base, items: [item], pixelSize: size, filters: filters)
            // Fingerprint along the shaft's own line, which is where the styles
            // actually differ: dashed leaves gaps, curved leaves the line
            // altogether, double adds a head at the start.
            // Every pixel, not a stride: the dash period is 24pt here, so any step
            // that divides it samples the same phase every time and a dashed shaft
            // reads as solid.
            var probe: [UInt8] = []
            for x in 60..<140 {
                probe.append(TestImages.pixel(image, x: x, y: 50)[2])
            }
            // Inside the start head for THIS geometry: the head spans x 20..37 from
            // a tip at x=20, so at x=30 its half-height is about 4.8pt. A straight
            // arrow has only a 6pt shaft there, so y=54 is bare.
            probe.append(TestImages.pixel(image, x: 30, y: 54)[2])
            signatures[style.rawValue] = probe
        }
        XCTAssertEqual(signatures.count, 4)
        // Double puts a head at the START, where straight has only a thin shaft.
        XCTAssertNotEqual(signatures["straight"], signatures["double"])
        // Curved leaves the centre line entirely.
        XCTAssertNotEqual(signatures["straight"], signatures["curved"])
        // Dashed leaves gaps along the shaft.
        XCTAssertNotEqual(signatures["straight"], signatures["dashed"])
    }

    func testADoubleArrowPutsInkAtBothEnds() throws {
        let from = CGPoint(x: 30, y: 50), to = CGPoint(x: 170, y: 50)
        let item = AnnotationItem(payload: .arrow(from: from, to: to, style: .double),
                                  ink: blue(), strokeWidth: 6)
        let image = try AnnotationRenderer.render(
            base: base, items: [item], pixelSize: size, filters: filters)
        // A filled head is wider than the shaft, so sample off-axis inside each
        // triangle. Head length is max(strokeWidth * 3.2, 8) = 19.2 here, so at
        // 14pt back from a tip the half-height is about 6.7pt.
        XCTAssertGreaterThan(TestImages.pixel(image, x: 44, y: 54)[2], 100, "start head")
        XCTAssertGreaterThan(TestImages.pixel(image, x: 156, y: 54)[2], 100, "end head")
    }

    func testRasterByteEstimateMatchesBGRA() {
        XCTAssertEqual(AnnotationRenderer.rasterBytes(CGSize(width: 5120, height: 2880)),
                       5120 * 2880 * 4)
    }
}
