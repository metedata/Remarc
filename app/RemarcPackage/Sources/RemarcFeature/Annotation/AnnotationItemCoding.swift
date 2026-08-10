import Foundation
import CoreGraphics

// MARK: - Wire shapes
//
// CGPoint and CGRect do conform to Codable, but they encode as an UNKEYED
// container of bare numbers. That is an implementation detail of Foundation,
// not a format a file on the user's disk should depend on. These pin the stored
// shape to named fields, so a saved mark stays readable and stays loadable no
// matter what Foundation does later.

private struct PointWire: Codable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }

    var cg: CGPoint { CGPoint(x: x, y: y) }
}

private struct RectWire: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }

    var cg: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

// MARK: - Ink

extension AnnotationInk: Codable {
    private enum CodingKeys: String, CodingKey { case red, green, blue, alpha }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(red: CGFloat(try container.decode(Double.self, forKey: .red)),
                  green: CGFloat(try container.decode(Double.self, forKey: .green)),
                  blue: CGFloat(try container.decode(Double.self, forKey: .blue)),
                  // Absent means opaque: alpha is the only field with a default
                  // in the initialiser, and files written by hand omit it.
                  alpha: CGFloat(try container.decodeIfPresent(Double.self, forKey: .alpha) ?? 1))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Double(red), forKey: .red)
        try container.encode(Double(green), forKey: .green)
        try container.encode(Double(blue), forKey: .blue)
        try container.encode(Double(alpha), forKey: .alpha)
    }
}

extension AnnotationArrowStyle: Codable {}

// MARK: - Payload

extension AnnotationPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, from, to, style, rect, points, text, at, pointSize, number, radius
    }

    /// The discriminator. Its raw values are a FILE FORMAT: renaming a case
    /// orphans every mark already on disk.
    private enum Kind: String, Codable {
        case arrow, line, rect, oval, freehand, highlighter, text, counter, blur, pixelate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        func rect() throws -> CGRect {
            try container.decode(RectWire.self, forKey: .rect).cg
        }
        func points() throws -> [CGPoint] {
            try container.decode([PointWire].self, forKey: .points).map(\.cg)
        }

        switch kind {
        case .arrow:
            self = .arrow(from: try container.decode(PointWire.self, forKey: .from).cg,
                          to: try container.decode(PointWire.self, forKey: .to).cg,
                          style: try container.decode(AnnotationArrowStyle.self, forKey: .style))
        case .line:
            self = .line(from: try container.decode(PointWire.self, forKey: .from).cg,
                         to: try container.decode(PointWire.self, forKey: .to).cg)
        case .rect:
            self = .rect(try rect())
        case .oval:
            self = .oval(try rect())
        case .freehand:
            self = .freehand(points: try points())
        case .highlighter:
            self = .highlighter(points: try points())
        case .text:
            self = .text(try container.decode(String.self, forKey: .text),
                         at: try container.decode(PointWire.self, forKey: .at).cg,
                         pointSize: CGFloat(try container.decode(Double.self, forKey: .pointSize)))
        case .counter:
            self = .counter(try container.decode(Int.self, forKey: .number),
                            at: try container.decode(PointWire.self, forKey: .at).cg,
                            radius: CGFloat(try container.decode(Double.self, forKey: .radius)))
        case .blur:
            self = .blur(try rect())
        case .pixelate:
            self = .pixelate(try rect())
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .arrow(from, to, style):
            try container.encode(Kind.arrow, forKey: .kind)
            try container.encode(PointWire(from), forKey: .from)
            try container.encode(PointWire(to), forKey: .to)
            try container.encode(style, forKey: .style)
        case let .line(from, to):
            try container.encode(Kind.line, forKey: .kind)
            try container.encode(PointWire(from), forKey: .from)
            try container.encode(PointWire(to), forKey: .to)
        case let .rect(r):
            try container.encode(Kind.rect, forKey: .kind)
            try container.encode(RectWire(r), forKey: .rect)
        case let .oval(r):
            try container.encode(Kind.oval, forKey: .kind)
            try container.encode(RectWire(r), forKey: .rect)
        case let .freehand(points):
            try container.encode(Kind.freehand, forKey: .kind)
            try container.encode(points.map(PointWire.init), forKey: .points)
        case let .highlighter(points):
            try container.encode(Kind.highlighter, forKey: .kind)
            try container.encode(points.map(PointWire.init), forKey: .points)
        case let .text(string, at, pointSize):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(string, forKey: .text)
            try container.encode(PointWire(at), forKey: .at)
            try container.encode(Double(pointSize), forKey: .pointSize)
        case let .counter(number, at, radius):
            try container.encode(Kind.counter, forKey: .kind)
            try container.encode(number, forKey: .number)
            try container.encode(PointWire(at), forKey: .at)
            try container.encode(Double(radius), forKey: .radius)
        case let .blur(r):
            try container.encode(Kind.blur, forKey: .kind)
            try container.encode(RectWire(r), forKey: .rect)
        case let .pixelate(r):
            try container.encode(Kind.pixelate, forKey: .kind)
            try container.encode(RectWire(r), forKey: .rect)
        }
    }

    /// Whether this mark obscures pixels rather than drawing over them.
    ///
    /// The split that makes redaction permanent: these flatten into the stored
    /// base on Apply and are never written to the sidecar, so the pixels under
    /// them do not survive anywhere on disk.
    public var isRedaction: Bool {
        switch self {
        case .blur, .pixelate: return true
        default: return false
        }
    }
}

// MARK: - Item

extension AnnotationItem: Codable {
    private enum CodingKeys: String, CodingKey { case id, payload, ink, strokeWidth }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  payload: try container.decode(AnnotationPayload.self, forKey: .payload),
                  ink: try container.decode(AnnotationInk.self, forKey: .ink),
                  strokeWidth: CGFloat(try container.decode(Double.self, forKey: .strokeWidth)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(payload, forKey: .payload)
        try container.encode(ink, forKey: .ink)
        try container.encode(Double(strokeWidth), forKey: .strokeWidth)
    }
}
