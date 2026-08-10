import Foundation
import CoreGraphics

/// Fixed sRGB ink. Deliberately NOT a `remarc*` appearance token: those adapt to
/// light and dark mode, which would make exported pixels depend on the appearance
/// the editor happened to be in. Brand tokens style the toolbar chrome only.
public struct AnnotationInk: Equatable, Sendable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public static let presets: [AnnotationInk] = [
        AnnotationInk(red: 0.90, green: 0.16, blue: 0.22),   // red
        AnnotationInk(red: 0.99, green: 0.69, blue: 0.11),   // amber
        AnnotationInk(red: 0.16, green: 0.71, blue: 0.42),   // green
        AnnotationInk(red: 0.15, green: 0.47, blue: 0.95),   // blue
        AnnotationInk(red: 0.10, green: 0.10, blue: 0.11),   // near-black
        AnnotationInk(red: 1.00, green: 1.00, blue: 1.00)    // white
    ]

    public static let highlighter = AnnotationInk(red: 0.99, green: 0.90, blue: 0.20, alpha: 0.4)
}

public enum AnnotationTool: String, CaseIterable, Sendable {
    case select, arrow, line, rect, oval, freehand, highlighter, text, counter, blur, pixelate
}

/// How an arrow is drawn. Geometry stays the two endpoints; the style only
/// changes the path between and the heads on it, so switching style never moves
/// an existing arrow.
public enum AnnotationArrowStyle: String, CaseIterable, Sendable {
    /// Straight shaft, one filled head.
    case straight
    /// Quadratic curve bowed to one side, head along the tangent. Reads better
    /// when the arrow has to come in from the side of a crowded screenshot.
    case curved
    /// Filled heads at both ends.
    case double
    /// Straight shaft, dashed, one filled head.
    case dashed

    public var label: String {
        switch self {
        case .straight: return "Arrow"
        case .curved: return "Curved arrow"
        case .double: return "Double-headed arrow"
        case .dashed: return "Dashed arrow"
        }
    }

    public var systemImage: String {
        switch self {
        case .straight: return "arrow.up.right"
        case .curved: return "arrow.turn.up.right"
        case .double: return "arrow.left.and.right"
        case .dashed: return "arrow.up.right.circle"
        }
    }

    /// How far the curve bows from the straight line, as a fraction of its length.
    public var bow: CGFloat { self == .curved ? 0.22 : 0 }
}

/// One payload per tool. All geometry is in SOURCE-IMAGE PIXELS with a top-left
/// origin, never in view points, so zoom can never reach it.
public enum AnnotationPayload: Equatable, Sendable {
    case arrow(from: CGPoint, to: CGPoint, style: AnnotationArrowStyle)
    case line(from: CGPoint, to: CGPoint)
    case rect(CGRect)
    case oval(CGRect)
    case freehand(points: [CGPoint])
    case highlighter(points: [CGPoint])
    case text(String, at: CGPoint, pointSize: CGFloat)
    case counter(Int, at: CGPoint, radius: CGFloat)
    case blur(CGRect)
    case pixelate(CGRect)
}

public struct AnnotationItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var payload: AnnotationPayload
    public var ink: AnnotationInk
    public var strokeWidth: CGFloat

    public init(id: UUID = UUID(), payload: AnnotationPayload, ink: AnnotationInk, strokeWidth: CGFloat) {
        self.id = id
        self.payload = payload
        self.ink = ink
        self.strokeWidth = strokeWidth
    }

    /// Tight geometric bounds in source pixels, before stroke width. The compositor
    /// widens this by the stroke when computing a dirty rect.
    public var bounds: CGRect {
        switch payload {
        case let .arrow(from, to, style):
            // A curved arrow bulges past the segment, so its control point has to
            // be inside the bounds or the dirty rect clips the curve.
            return Self.box(covering: [from, to, Self.controlPoint(from: from, to: to, style: style)])
        case let .line(from, to):
            return Self.box(covering: [from, to])
        case let .rect(r), let .oval(r), let .blur(r), let .pixelate(r):
            return r.standardized
        case let .freehand(points), let .highlighter(points):
            return Self.box(covering: points)
        case let .text(string, at, pointSize):
            // Width has to come from layout. Returning 0 made the item nearly
            // unhittable (select only worked within the hit tolerance of a
            // zero-width box) and gave the compositor a dirty rect that did not
            // cover the glyphs it had just drawn.
            let measured = AnnotationRenderer.textBounds(string, pointSize: pointSize)
            return CGRect(x: at.x, y: at.y,
                          width: max(measured.width, 1),
                          height: max(measured.height, pointSize))
        case let .counter(_, at, radius):
            return CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    /// Quadratic control point for an arrow, perpendicular to its midpoint.
    /// Shared by the bounds calculation and the renderer so they cannot drift.
    public static func controlPoint(from: CGPoint, to: CGPoint,
                                    style: AnnotationArrowStyle) -> CGPoint {
        let bow = style.bow
        guard bow != 0 else { return CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2) }
        let dx = to.x - from.x, dy = to.y - from.y
        let mid = CGPoint(x: from.x + dx / 2, y: from.y + dy / 2)
        return CGPoint(x: mid.x - dy * bow, y: mid.y + dx * bow)
    }

    private static func box(covering points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
