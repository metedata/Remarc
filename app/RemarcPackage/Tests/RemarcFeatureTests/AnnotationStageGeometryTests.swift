import XCTest
@testable import RemarcFeature

/// Capture-time magnification geometry. All rects are RegionSelectionView-local
/// points: unflipped, bottom-left origin, 0-based.
final class AnnotationStageGeometryTests: XCTestCase {

    private let allowanceRect = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func selection(_ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: 200, y: 200, width: w, height: h)
    }

    // MARK: - Allowance

    func testAllowanceReservesPanelOnTheDockedSideAndToolbarBelow() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 900)
        let a = AnnotationStageGeometry.allowance(
            visible: visible, edge: .leading, panelReserve: 352, toolbarReserveBelow: 60, edgePad: 8
        )
        // Only the edge pad on the toolbar-free side. The toolbar is a wide
        // horizontal bar docked BELOW, so reserving its width here would cost
        // hundreds of points for something that is not there.
        XCTAssertEqual(a?.minX, 8)
        XCTAssertEqual(a?.maxX, 1512 - 352)
        XCTAssertEqual(a?.minY, 68, "edge pad plus the toolbar's own height")
        XCTAssertEqual(a?.maxY, 892)
    }

    func testAllowanceMirrorsForTrailingDock() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 900)
        let a = AnnotationStageGeometry.allowance(
            visible: visible, edge: .trailing, panelReserve: 352, toolbarReserveBelow: 60, edgePad: 8
        )
        XCTAssertEqual(a?.minX, 352)
        XCTAssertEqual(a?.maxX, 1512 - 8)
        XCTAssertEqual(a?.minY, 68)
    }

    func testVerticalDocksDisableMagnification() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 900)
        XCTAssertNil(AnnotationStageGeometry.allowance(
            visible: visible, edge: .top, panelReserve: 352, toolbarReserveBelow: 60, edgePad: 8))
        XCTAssertNil(AnnotationStageGeometry.allowance(
            visible: visible, edge: .bottom, panelReserve: 352, toolbarReserveBelow: 60, edgePad: 8))
    }

    /// A selection drawn on the LEFT of the screen must still display near where
    /// the user drew it. This is the regression the on-device run caught.
    func testALeftSideSelectionIsNotShovedAcrossTheScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 900)
        let allowance = AnnotationStageGeometry.allowance(
            visible: visible, edge: .leading, panelReserve: 352,
            toolbarReserveBelow: 60, edgePad: 8)!
        let s = CGRect(x: 500, y: 500, width: 200, height: 80)   // centre x = 600
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: 4, allowance: allowance, backingScale: 2)
        XCTAssertEqual(r.effectiveZoom, 4)
        XCTAssertEqual(r.rect.midX, s.midX, accuracy: 0.5,
                       "growth must stay centred on the selection, not clamp to a phantom reserve")
    }

    // MARK: - Zoom ladder

    func testAutoZoomMatchesTheSpecTable() {
        func auto(_ w: CGFloat, _ h: CGFloat) -> Int {
            let s = selection(w, h)
            let maxZ = AnnotationStageGeometry.resolvedMaxZoom(
                selection: s, allowance: allowanceRect, backingScale: 2, hardCap: 8)
            return AnnotationStageGeometry.autoZoom(selection: s.size, maxZoom: maxZ, comfortEdge: 320)
        }
        XCTAssertEqual(auto(200, 80), 4, "the motivating case")
        XCTAssertEqual(auto(40, 40), 8, "favicon, capped by hardCap")
        XCTAssertEqual(auto(400, 300), 2, "mild help")
        XCTAssertEqual(auto(900, 600), 1, "inert")
        XCTAssertEqual(auto(1200, 30), 1, "long thin strip, fit floors to 1")
    }

    func testZoomOfOneReturnsTheSelectionExactly() {
        let s = selection(200, 80)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: 1, allowance: allowanceRect, backingScale: 2)
        XCTAssertEqual(r.effectiveZoom, 1)
        XCTAssertEqual(r.rect, s, "z == 1 must be byte-identical to today's geometry")
    }

    func testEffectiveZoomAlwaysMatchesTheRectItReturns() {
        let s = selection(200, 80)
        for z in 1...8 {
            let r = AnnotationStageGeometry.displayRect(
                selection: s, requestedZoom: z, allowance: allowanceRect, backingScale: 2)
            XCTAssertEqual(r.rect.width / s.width, CGFloat(r.effectiveZoom), accuracy: 0.0001,
                           "requested \(z) reported \(r.effectiveZoom) but the rect disagrees")
        }
    }

    /// Centred in the allowance, so growth is never clamped and the assertions are
    /// about alignment rather than about hitting an edge.
    private func centredSelection(_ w: CGFloat, _ h: CGFloat, offset: CGFloat = 0) -> CGRect {
        CGRect(x: allowanceRect.midX - w / 2 + offset,
               y: allowanceRect.midY - h / 2 + offset,
               width: w, height: h)
    }

    func testAlignmentMovesOriginOnlyNeverSize() {
        let s = centredSelection(200, 80, offset: 0.3)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: 4, allowance: allowanceRect, backingScale: 2)
        XCTAssertEqual(r.rect.width, 800, accuracy: 0.0001)
        XCTAssertEqual(r.rect.height, 320, accuracy: 0.0001)
        XCTAssertEqual((r.rect.minX * 2).rounded(), r.rect.minX * 2, accuracy: 0.0001,
                       "origin must sit on the backing grid")
        XCTAssertEqual((r.rect.minY * 2).rounded(), r.rect.minY * 2, accuracy: 0.0001)
    }

    func testEmptyAlignedIntervalReducesZoom() {
        // An allowance barely wider than 2x forces a reduction from 3x.
        let s = CGRect(x: 0, y: 0, width: 100, height: 100)
        let tight = CGRect(x: 0, y: 0, width: 250, height: 250)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: 3, allowance: tight, backingScale: 2)
        XCTAssertLessThan(r.effectiveZoom, 3)
        XCTAssertEqual(r.rect.width / s.width, CGFloat(r.effectiveZoom), accuracy: 0.0001)
    }

    func testResolvedMaxZoomIsAchievable() {
        // Whatever zMax says, requesting it must actually deliver it. Otherwise the
        // stepper sits enabled and inert.
        let s = selection(200, 80)
        let maxZ = AnnotationStageGeometry.resolvedMaxZoom(
            selection: s, allowance: allowanceRect, backingScale: 2, hardCap: 8)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: maxZ, allowance: allowanceRect, backingScale: 2)
        XCTAssertEqual(r.effectiveZoom, maxZ)
    }

    func testDisplayRectAlwaysFitsInsideTheAllowanceAboveOneX() {
        let s = selection(200, 80)
        for z in 2...8 {
            let r = AnnotationStageGeometry.displayRect(
                selection: s, requestedZoom: z, allowance: allowanceRect, backingScale: 2)
            guard r.effectiveZoom > 1 else { continue }
            XCTAssertTrue(allowanceRect.insetBy(dx: -0.5, dy: -0.5).contains(r.rect),
                          "z=\(z) escaped the allowance: \(r.rect)")
        }
    }

    func testCentredGrowthKeepsTheMidpointWithinOneDevicePixel() {
        // Must be centred in the allowance: a selection near an edge is legitimately
        // translated by the clamp, and the invariant is explicitly scoped to the
        // unclamped case.
        let s = centredSelection(200, 80)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: 4, allowance: allowanceRect, backingScale: 2)
        XCTAssertEqual(r.rect.midX, s.midX, accuracy: 0.5)
        XCTAssertEqual(r.rect.midY, s.midY, accuracy: 0.5)
    }

    func testSelectionNearAnEdgeIsTranslatedNotResized() {
        let s = CGRect(x: 4, y: 4, width: 200, height: 80)
        let r = AnnotationStageGeometry.displayRect(
            selection: s, requestedZoom: 4, allowance: allowanceRect, backingScale: 2)
        XCTAssertEqual(r.rect.width, 800, accuracy: 0.0001, "the clamp translates, never resizes")
        XCTAssertGreaterThanOrEqual(r.rect.minX, allowanceRect.minX - 0.5)
        XCTAssertGreaterThanOrEqual(r.rect.minY, allowanceRect.minY - 0.5)
    }
}
