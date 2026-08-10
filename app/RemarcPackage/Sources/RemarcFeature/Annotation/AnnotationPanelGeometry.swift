import Foundation
import CoreGraphics

/// The comment panel's dock/flip/clamp math, lifted out of the private
/// `screenshotPanelOrigin` so it can be tested directly.
///
/// With `forcedEdge == nil` this reproduces the shipped behavior exactly, which
/// matters because the Chrome element-grab path shares the same function.
public enum AnnotationPanelGeometry {

    public static func origin(
        captureRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat,
        clampInset: CGFloat,
        forcedEdge: StageDockEdge? = nil
    ) -> (origin: CGPoint, edge: StageDockEdge, isAbove: Bool) {

        var origin: CGPoint
        var edge: StageDockEdge
        var isAbove: Bool

        func placeLeading() {
            origin = CGPoint(x: captureRect.maxX + margin,
                             y: captureRect.midY - panelSize.height / 2)
            edge = .leading
            isAbove = false
        }
        func placeTrailing() {
            origin = CGPoint(x: captureRect.minX - margin - panelSize.width,
                             y: captureRect.midY - panelSize.height / 2)
            edge = .trailing
            isAbove = false
        }
        func placeBottom() {   // panel ABOVE the selection
            origin = CGPoint(x: captureRect.midX - panelSize.width / 2,
                             y: captureRect.maxY + margin)
            edge = .bottom
            isAbove = true
        }
        func placeTop() {      // panel BELOW the selection
            origin = CGPoint(x: captureRect.midX - panelSize.width / 2,
                             y: captureRect.minY - panelSize.height - margin)
            edge = .top
            isAbove = false
        }

        origin = .zero; edge = .leading; isAbove = false

        if let forcedEdge {
            switch forcedEdge {
            case .leading: placeLeading()
            case .trailing: placeTrailing()
            case .bottom: placeBottom()
            case .top: placeTop()
            }
        } else if captureRect.maxX + margin + panelSize.width <= visibleFrame.maxX {
            placeLeading()
        } else if captureRect.minX - margin - panelSize.width >= visibleFrame.minX {
            placeTrailing()
        } else if captureRect.maxY + margin + panelSize.height <= visibleFrame.maxY {
            placeBottom()
        } else {
            placeTop()
        }

        origin.x = max(visibleFrame.minX + clampInset,
                       min(origin.x, visibleFrame.maxX - panelSize.width - clampInset))
        origin.y = max(visibleFrame.minY + clampInset,
                       min(origin.y, visibleFrame.maxY - panelSize.height - clampInset))

        return (origin, edge, isAbove)
    }
}
