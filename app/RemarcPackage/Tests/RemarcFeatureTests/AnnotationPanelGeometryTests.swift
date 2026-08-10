import XCTest
@testable import RemarcFeature

/// Mirrors `CommentInputWindowController.screenshotPanelOrigin` exactly: three room
/// tests (right, left, above) then an unconditional below fallback, then a clamp.
final class AnnotationPanelGeometryTests: XCTestCase {

    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 900)
    private let panel = CGSize(width: 340, height: 180)

    private func origin(_ rect: CGRect, forced: StageDockEdge? = nil)
        -> (origin: CGPoint, edge: StageDockEdge, isAbove: Bool) {
        AnnotationPanelGeometry.origin(
            captureRect: rect, panelSize: panel, visibleFrame: visible,
            margin: 8, clampInset: 4, forcedEdge: forced)
    }

    func testPrefersRightDock() {
        let r = CGRect(x: 200, y: 400, width: 200, height: 80)
        let o = origin(r)
        XCTAssertEqual(o.edge, .leading)
        XCTAssertEqual(o.origin.x, r.maxX + 8)
        XCTAssertEqual(o.origin.y, r.midY - panel.height / 2)
        XCTAssertFalse(o.isAbove)
    }

    func testFallsBackToLeftWhenRightHasNoRoom() {
        let r = CGRect(x: 1200, y: 400, width: 200, height: 80)
        let o = origin(r)
        XCTAssertEqual(o.edge, .trailing)
        XCTAssertEqual(o.origin.x, r.minX - 8 - panel.width)
    }

    func testFallsBackToAboveWhenNeitherSideFits() {
        // Spans the width, so neither side has 348pt.
        let r = CGRect(x: 100, y: 100, width: 1300, height: 80)
        let o = origin(r)
        XCTAssertEqual(o.edge, .bottom)
        XCTAssertTrue(o.isAbove)
        XCTAssertEqual(o.origin.y, r.maxY + 8)
    }

    func testUnconditionalBelowFallback() {
        let r = CGRect(x: 100, y: 700, width: 1300, height: 150)
        let o = origin(r)
        XCTAssertEqual(o.edge, .top)
        XCTAssertFalse(o.isAbove)
    }

    func testClampKeepsThePanelOnScreen() {
        let r = CGRect(x: 200, y: 870, width: 200, height: 25)
        let o = origin(r)
        XCTAssertGreaterThanOrEqual(o.origin.y, visible.minY + 4)
        XCTAssertLessThanOrEqual(o.origin.y, visible.maxY - panel.height - 4)
    }

    func testForcedEdgeSkipsTheRoomTests() {
        // A magnified rect that would normally flip to a vertical dock keeps its
        // original side when the edge is forced.
        let magnified = CGRect(x: 100, y: 300, width: 1300, height: 320)
        let natural = origin(magnified)
        XCTAssertNotEqual(natural.edge, .leading, "precondition: this rect naturally flips")

        let forced = origin(magnified, forced: .leading)
        XCTAssertEqual(forced.edge, .leading)
        XCTAssertEqual(forced.origin.y, magnified.midY - panel.height / 2)
    }

    func testNilForcedEdgeIsIdenticalToTheUnforcedForm() {
        for rect in [CGRect(x: 200, y: 400, width: 200, height: 80),
                     CGRect(x: 1200, y: 400, width: 200, height: 80),
                     CGRect(x: 100, y: 100, width: 1300, height: 80),
                     CGRect(x: 100, y: 700, width: 1300, height: 150)] {
            let a = origin(rect)
            let b = origin(rect, forced: nil)
            XCTAssertEqual(a.origin, b.origin)
            XCTAssertEqual(a.edge, b.edge)
            XCTAssertEqual(a.isAbove, b.isAbove)
        }
    }
}
