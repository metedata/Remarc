import XCTest
@testable import RemarcFeature

final class AnnotationItemTests: XCTestCase {

    func testEveryToolHasAStableRawValue() {
        // Raw values are used for tool shortcuts and toolbar state; renaming one
        // silently changes behavior.
        XCTAssertEqual(AnnotationTool.arrow.rawValue, "arrow")
        // select + arrow, line, rect, oval, freehand, highlighter, text, counter,
        // blur, pixelate. Blur and pixelate are separate tools because the spec
        // gives them distinct payloads and distinct redaction semantics.
        XCTAssertEqual(AnnotationTool.allCases.count, 11)
    }

    func testBoundsOfALineCoverBothEndpoints() {
        let item = AnnotationItem(
            payload: .line(from: CGPoint(x: 10, y: 90), to: CGPoint(x: 110, y: 20)),
            ink: .presets[0], strokeWidth: 4)
        XCTAssertEqual(item.bounds.minX, 10, accuracy: 0.0001)
        XCTAssertEqual(item.bounds.minY, 20, accuracy: 0.0001)
        XCTAssertEqual(item.bounds.maxX, 110, accuracy: 0.0001)
        XCTAssertEqual(item.bounds.maxY, 90, accuracy: 0.0001)
    }

    func testBoundsOfAFreehandCoverEveryPoint() {
        let item = AnnotationItem(
            payload: .freehand(points: [CGPoint(x: 5, y: 5),
                                        CGPoint(x: 80, y: 12),
                                        CGPoint(x: 33, y: 61)]),
            ink: .presets[0], strokeWidth: 2)
        XCTAssertEqual(item.bounds, CGRect(x: 5, y: 5, width: 75, height: 56))
    }

    func testFreehandWithNoPointsHasEmptyBounds() {
        let item = AnnotationItem(payload: .freehand(points: []), ink: .presets[0], strokeWidth: 2)
        XCTAssertTrue(item.bounds.isEmpty)
    }

    func testInkPresetsAreFixedAndOpaque() {
        // Exported ink must not vary with light/dark mode, so presets are literal
        // sRGB rather than appearance-adaptive tokens.
        XCTAssertFalse(AnnotationInk.presets.isEmpty)
        for ink in AnnotationInk.presets {
            XCTAssertEqual(ink.alpha, 1, accuracy: 0.0001)
        }
    }

    func testHighlighterInkIsTranslucent() {
        XCTAssertLessThan(AnnotationInk.highlighter.alpha, 1)
    }

    // MARK: - Arrow styles

    func testEveryArrowStyleIsDistinctAndLabelled() {
        XCTAssertEqual(AnnotationArrowStyle.allCases.count, 4)
        for style in AnnotationArrowStyle.allCases {
            XCTAssertFalse(style.label.isEmpty)
            XCTAssertFalse(style.systemImage.isEmpty)
        }
        XCTAssertEqual(Set(AnnotationArrowStyle.allCases.map(\.rawValue)).count, 4)
    }

    func testOnlyTheCurvedStyleBows() {
        for style in AnnotationArrowStyle.allCases {
            if style == .curved {
                XCTAssertGreaterThan(style.bow, 0)
            } else {
                XCTAssertEqual(style.bow, 0)
            }
        }
    }

    /// A curved arrow bulges past its endpoints, so the control point has to be
    /// inside the bounds or the dirty rect clips the curve.
    func testCurvedArrowBoundsCoverTheBulge() {
        let from = CGPoint(x: 0, y: 50), to = CGPoint(x: 100, y: 50)
        let straight = AnnotationItem(payload: .arrow(from: from, to: to, style: .straight),
                                      ink: .presets[0], strokeWidth: 4)
        let curved = AnnotationItem(payload: .arrow(from: from, to: to, style: .curved),
                                    ink: .presets[0], strokeWidth: 4)
        XCTAssertEqual(straight.bounds.height, 0, accuracy: 0.0001)
        XCTAssertGreaterThan(curved.bounds.height, 10,
                             "the bounds must contain the curve, not just the endpoints")
        // The control point is the extreme of the bulge, so it lands exactly ON the
        // bounds edge, and CGRect.contains excludes maxY. Assert the extent covers
        // it rather than strict containment.
        let control = AnnotationItem.controlPoint(from: from, to: to, style: .curved)
        XCTAssertGreaterThanOrEqual(curved.bounds.maxY, control.y)
        XCTAssertLessThanOrEqual(curved.bounds.minY, control.y)
    }

    func testStyleIsPartOfIdentityButNotOfGeometry() {
        let from = CGPoint(x: 10, y: 10), to = CGPoint(x: 90, y: 70)
        let a = AnnotationItem(payload: .arrow(from: from, to: to, style: .straight),
                               ink: .presets[0], strokeWidth: 4)
        let b = AnnotationItem(payload: .arrow(from: from, to: to, style: .double),
                               ink: .presets[0], strokeWidth: 4)
        XCTAssertNotEqual(a.payload, b.payload)
        // Neither style bows, so switching between them must not move the arrow.
        XCTAssertEqual(a.bounds, b.bounds)
    }

    func testItemsWithIdenticalContentAreEqualButHaveDistinctIDs() {
        let a = AnnotationItem(payload: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                               ink: .presets[0], strokeWidth: 2)
        let b = AnnotationItem(payload: .rect(CGRect(x: 0, y: 0, width: 10, height: 10)),
                               ink: .presets[0], strokeWidth: 2)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a.payload, b.payload)
    }
}
