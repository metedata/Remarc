import XCTest
@testable import RemarcFeature

/// Probe points are deliberately ASYMMETRIC. A symmetric fixture passes even with
/// the vertical flip inverted, and a wrong flip is a silently mirrored export.
final class AnnotationViewportTests: XCTestCase {

    func testIdentityWhenCanvasBoundsEqualPixelSize() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 400, height: 160),
                                   canvasBounds: CGRect(x: 0, y: 0, width: 400, height: 160))
        XCTAssertEqual(v.scaleX, 1, accuracy: 0.0001)
        XCTAssertEqual(v.scaleY, 1, accuracy: 0.0001)
        let p = v.pixel(fromCanvas: CGPoint(x: 37, y: 11))
        XCTAssertEqual(p.x, 37, accuracy: 0.0001)
        XCTAssertEqual(p.y, 11, accuracy: 0.0001)
    }

    func testIndependentAxisScales() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 400, height: 160),
                                   canvasBounds: CGRect(x: 0, y: 0, width: 200, height: 40))
        XCTAssertEqual(v.scaleX, 2, accuracy: 0.0001)
        XCTAssertEqual(v.scaleY, 4, accuracy: 0.0001)
        let p = v.pixel(fromCanvas: CGPoint(x: 10, y: 10))
        XCTAssertEqual(p.x, 20, accuracy: 0.0001)
        XCTAssertEqual(p.y, 40, accuracy: 0.0001)
    }

    func testRoundTripIsStableOnAsymmetricPoints() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 1792, height: 1520),
                                   canvasBounds: CGRect(x: 0, y: 0, width: 448, height: 380))
        for point in [CGPoint(x: 3, y: 371), CGPoint(x: 445, y: 7), CGPoint(x: 101, y: 289)] {
            let round = v.canvas(fromPixel: v.pixel(fromCanvas: point))
            XCTAssertEqual(round.x, point.x, accuracy: 0.001)
            XCTAssertEqual(round.y, point.y, accuracy: 0.001)
        }
    }

    func testInputIsClippedToTheImage() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 400, height: 160),
                                   canvasBounds: CGRect(x: 0, y: 0, width: 400, height: 160))
        let low = v.pixel(fromCanvas: CGPoint(x: -50, y: -10))
        XCTAssertEqual(low.x, 0, accuracy: 0.0001)
        XCTAssertEqual(low.y, 0, accuracy: 0.0001)
        let high = v.pixel(fromCanvas: CGPoint(x: 9_999, y: 9_999))
        XCTAssertEqual(high.x, 400, accuracy: 0.0001)
        XCTAssertEqual(high.y, 160, accuracy: 0.0001)
    }

    func testOddPixelDimensions() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 401, height: 161),
                                   canvasBounds: CGRect(x: 0, y: 0, width: 401, height: 161))
        let p = v.pixel(fromCanvas: CGPoint(x: 400, y: 160))
        XCTAssertEqual(p.x, 400, accuracy: 0.0001)
        XCTAssertEqual(p.y, 160, accuracy: 0.0001)
    }

    func testDegenerateBoundsDoNotDivideByZero() {
        let v = AnnotationViewport(pixelSize: CGSize(width: 400, height: 160),
                                   canvasBounds: .zero)
        let p = v.pixel(fromCanvas: CGPoint(x: 10, y: 10))
        XCTAssertTrue(p.x.isFinite && p.y.isFinite)
    }
}
