import Foundation
import CoreGraphics

/// Which side of the selection the comment panel is docked to. Mirrors the edge
/// `screenshotPanelOrigin` picks: `.leading` means the panel sits to the RIGHT of
/// the selection, `.trailing` to the left.
public enum StageDockEdge: Sendable {
    case leading, trailing, top, bottom
}

/// Pure geometry for capture-time magnification.
///
/// Every rect here is `RegionSelectionView`-local: unflipped, bottom-left origin,
/// 0-based, because `panel.contentView = regionView` discards the screen origin.
/// Converting to screen-global happens exactly once, outside this type.
public enum AnnotationStageGeometry {

    public static let hardCapDefault = 8
    public static let comfortEdgeDefault: CGFloat = 320
    public static let edgePadDefault: CGFloat = 8

    // MARK: - Allowance box

    /// The region the magnified image may occupy: the comment panel's footprint
    /// reserved on its docked side, and the toolbar's reserved BELOW.
    ///
    /// The toolbar is a wide horizontal bar and docks under the stage, so its
    /// footprint is vertical. An earlier form reserved its *width* on the side
    /// opposite the panel, which cost roughly 630pt of horizontal room for a
    /// toolbar that was never there: a selection drawn on the left of the screen
    /// was shoved most of the way across it, and wide selections lost a zoom step
    /// they could actually have had. Measured on device before the fix: a 200x80
    /// selection centred at x=600 displayed clamped to x=633.
    ///
    /// Returns nil for vertical docks, which only occur when neither side has room
    /// for the panel - meaning a selection roughly 800pt or wider, which is not a
    /// small area and does not need magnifying.
    public static func allowance(
        visible: CGRect,
        edge: StageDockEdge,
        panelReserve: CGFloat,
        toolbarReserveBelow: CGFloat,
        edgePad: CGFloat = edgePadDefault
    ) -> CGRect? {
        let minY = visible.minY + edgePad + toolbarReserveBelow
        let maxY = visible.maxY - edgePad
        guard maxY > minY else { return nil }

        let minX: CGFloat
        let maxX: CGFloat
        switch edge {
        case .leading:
            minX = visible.minX + edgePad
            maxX = visible.maxX - panelReserve
        case .trailing:
            minX = visible.minX + panelReserve
            maxX = visible.maxX - edgePad
        case .top, .bottom:
            return nil
        }
        guard maxX > minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Zoom ladder

    /// Largest uniform scale that fits, ignoring backing alignment.
    public static func fitZoom(selection: CGSize, allowance: CGRect) -> CGFloat {
        guard selection.width > 0, selection.height > 0 else { return 1 }
        return min(allowance.width / selection.width, allowance.height / selection.height)
    }

    /// Largest integer zoom that is actually ACHIEVABLE once the origin is
    /// backing-aligned. `floor(fitZoom)` can overstate it, which would leave the
    /// zoom stepper permanently enabled and permanently inert.
    public static func resolvedMaxZoom(
        selection: CGRect,
        allowance: CGRect,
        backingScale: CGFloat,
        hardCap: Int = hardCapDefault
    ) -> Int {
        let fit = fitZoom(selection: selection.size, allowance: allowance)
        let ceiling = max(1, min(Int(fit.rounded(.down)), hardCap))
        var z = ceiling
        while z > 1 {
            if displayRect(selection: selection, requestedZoom: z,
                           allowance: allowance, backingScale: backingScale).effectiveZoom == z {
                return z
            }
            z -= 1
        }
        return 1
    }

    /// Zoom applied automatically on entering annotation, so a small region is
    /// immediately big enough to draw on.
    public static func autoZoom(
        selection: CGSize,
        maxZoom: Int,
        comfortEdge: CGFloat = comfortEdgeDefault
    ) -> Int {
        let shortest = min(selection.width, selection.height)
        guard shortest > 0 else { return 1 }
        let needed = Int((comfortEdge / shortest).rounded(.up))
        return min(max(needed, 1), maxZoom)
    }

    // MARK: - Display rect

    /// The on-screen rect for a requested zoom, plus the zoom actually achieved.
    ///
    /// Callers must publish `effectiveZoom`, never the value they requested: when
    /// the backing-aligned origin interval is empty this reduces the zoom, and a
    /// stepper or label reading the request would lie.
    public static func displayRect(
        selection: CGRect,
        requestedZoom: Int,
        allowance: CGRect,
        backingScale: CGFloat
    ) -> (effectiveZoom: Int, rect: CGRect) {
        guard requestedZoom > 1 else { return (1, selection) }

        let scale = CGFloat(requestedZoom)
        let size = CGSize(width: selection.width * scale, height: selection.height * scale)
        let rawX = selection.midX - size.width / 2
        let rawY = selection.midY - size.height / 2

        // Align the permitted interval INWARD first. Clamping and then rounding can
        // push the rect back outside the allowance by up to one device pixel.
        let loX = alignUp(allowance.minX, backingScale)
        let hiX = alignDown(allowance.maxX - size.width, backingScale)
        let loY = alignUp(allowance.minY, backingScale)
        let hiY = alignDown(allowance.maxY - size.height, backingScale)

        guard loX <= hiX, loY <= hiY else {
            return displayRect(selection: selection, requestedZoom: requestedZoom - 1,
                               allowance: allowance, backingScale: backingScale)
        }

        let x = min(max(alignNearest(rawX, backingScale), loX), hiX)
        let y = min(max(alignNearest(rawY, backingScale), loY), hiY)
        return (requestedZoom, CGRect(x: x, y: y, width: size.width, height: size.height))
    }

    // MARK: - Backing alignment

    private static func alignUp(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded(.up) / scale
    }

    private static func alignDown(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded(.down) / scale
    }

    private static func alignNearest(_ value: CGFloat, _ scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return value }
        return (value * scale).rounded() / scale
    }
}
