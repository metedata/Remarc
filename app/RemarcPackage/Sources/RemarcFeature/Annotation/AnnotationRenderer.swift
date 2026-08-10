import Foundation
import CoreGraphics
import CoreText

/// Draws annotation items into a `CGContext` at exactly one context unit per
/// source pixel.
///
/// Neither surface draws committed vectors into its own display context. Once the
/// stage is magnified, AppKit rasterizes strokes, text, and antialiased edges at
/// the enlarged backing resolution while export rasterizes one output pixel per
/// source pixel, so the two would not match. Everything goes through here, at
/// source resolution, and the canvas blits the result.
///
/// The context is set up top-left origin, matching `AnnotationItem` geometry.
public enum AnnotationRenderer {

    /// Bytes for one BGRA raster of this size. Used by the compositor's budget.
    public static func rasterBytes(_ size: CGSize) -> Int {
        Int(size.width.rounded()) * Int(size.height.rounded()) * 4
    }

    public enum RenderError: Error, Equatable {
        case contextUnavailable
        case imageUnavailable
    }

    /// Full composite: base image, then every item in a single global z-order.
    ///
    /// There is no filters-first stratum. Each item, filter or vector, draws at its
    /// own z position, which is what preserves the z-order mutations undo records.
    /// - Parameter scale: output pixels per source pixel.
    ///
    ///   `1` is the **export** resolution and the only one that ever reaches a
    ///   file. A magnified editor uses the display's device-pixel ratio instead,
    ///   because rasterizing a stroke at source resolution and then blowing it up
    ///   4x makes every arrowhead and letter visibly jagged. The base image cannot
    ///   gain detail either way - it has the pixels it has - but the marks drawn
    ///   over it can be, and are, drawn at the resolution they will be displayed at.
    public static func render(
        base: CGImage,
        items: [AnnotationItem],
        pixelSize: CGSize,
        filters: AnnotationFilterCache,
        scale: CGFloat = 1
    ) throws -> CGImage {
        try renderRegion(base: base, items: items, pixelSize: pixelSize,
                         region: CGRect(origin: .zero, size: pixelSize),
                         filters: filters, scale: scale)
    }

    /// A sub-rect of the composite, at source resolution.
    ///
    /// This is the pending patch: an **opaque replacement** for `region`, rendered
    /// from the base plus every current item intersecting it. A transparent overlay
    /// could only express newly added marks - moving, deleting, restyling, and
    /// reordering a published item all need the old pixels gone, and a deletion has
    /// nothing to draw at all.
    public static func renderRegion(
        base: CGImage,
        items: [AnnotationItem],
        pixelSize: CGSize,
        region: CGRect,
        filters: AnnotationFilterCache,
        scale: CGFloat = 1
    ) throws -> CGImage {

        let clipped = region.integral.intersection(CGRect(origin: .zero, size: pixelSize))
        guard clipped.width >= 1, clipped.height >= 1 else { throw RenderError.imageUnavailable }

        let s = max(scale, 1)
        let width = Int((clipped.width * s).rounded())
        let height = Int((clipped.height * s).rounded())
        let space = base.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            // Some captured color spaces (indexed, exotic profiles) cannot back a
            // bitmap context. sRGB is the documented fallback.
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let fallback = CGContext(
                    data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw RenderError.contextUnavailable }
            return try paint(into: fallback, base: base, items: items,
                             pixelSize: pixelSize, region: clipped, filters: filters, scale: s)
        }

        return try paint(into: ctx, base: base, items: items,
                         pixelSize: pixelSize, region: clipped, filters: filters, scale: s)
    }

    private static func paint(
        into ctx: CGContext,
        base: CGImage,
        items: [AnnotationItem],
        pixelSize: CGSize,
        region: CGRect,
        filters: AnnotationFilterCache,
        scale: CGFloat
    ) throws -> CGImage {

        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)

        // Top-left origin, then scaled so ONE context unit is one source pixel
        // whatever the output resolution, then shifted so `region.origin` is the
        // context origin. Every item below therefore keeps drawing in plain source
        // coordinates and knows nothing about the display scale.
        ctx.translateBy(x: 0, y: region.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -region.minX, y: -region.minY)

        drawImage(base, in: CGRect(origin: .zero, size: pixelSize), ctx: ctx)

        for item in items where item.bounds.insetBy(dx: -item.strokeWidth, dy: -item.strokeWidth)
            .intersects(region) || isUnbounded(item) {
            draw(item, base: base, pixelSize: pixelSize, filters: filters, ctx: ctx)
        }

        guard let image = ctx.makeImage() else { throw RenderError.imageUnavailable }
        return image
    }

    /// Text bounds are only known after layout, so a text item is never skipped by
    /// the intersection test.
    private static func isUnbounded(_ item: AnnotationItem) -> Bool {
        if case .text = item.payload { return true }
        return false
    }

    // MARK: - Item drawing

    private static func draw(
        _ item: AnnotationItem,
        base: CGImage,
        pixelSize: CGSize,
        filters: AnnotationFilterCache,
        ctx: CGContext
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let ink = item.ink.cgColor
        ctx.setStrokeColor(ink)
        ctx.setFillColor(ink)
        ctx.setLineWidth(item.strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch item.payload {
        case let .line(from, to):
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()

        case let .arrow(from, to, style):
            drawArrow(from: from, to: to, style: style, width: item.strokeWidth, ctx: ctx)

        case let .rect(r):
            ctx.stroke(r.standardized.insetBy(dx: item.strokeWidth / 2, dy: item.strokeWidth / 2))

        case let .oval(r):
            ctx.strokeEllipse(in: r.standardized.insetBy(dx: item.strokeWidth / 2,
                                                         dy: item.strokeWidth / 2))

        case let .freehand(points):
            strokePolyline(points, ctx: ctx)

        case let .highlighter(points):
            // Multiply keeps the underlying content readable through the ink, the
            // way a physical highlighter behaves.
            ctx.setBlendMode(.multiply)
            ctx.setLineCap(.butt)
            strokePolyline(points, ctx: ctx)

        case let .text(string, at, pointSize):
            drawText(string, at: at, pointSize: pointSize, color: ink, ctx: ctx)

        case let .counter(number, at, radius):
            drawCounter(number, at: at, radius: radius, ink: ink, ctx: ctx)

        case let .blur(r):
            drawFilter(kind: .blur, rect: r, base: base, filters: filters, ctx: ctx)

        case let .pixelate(r):
            drawFilter(kind: .pixelate, rect: r, base: base, filters: filters, ctx: ctx)
        }
    }

    private static func strokePolyline(_ points: [CGPoint], ctx: CGContext) {
        guard let first = points.first else { return }
        if points.count == 1 {
            // A tap with the pen still leaves a dot.
            ctx.move(to: first); ctx.addLine(to: first); ctx.strokePath()
            return
        }
        ctx.move(to: first)
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }

    private static func drawArrow(from: CGPoint, to: CGPoint,
                                  style: AnnotationArrowStyle,
                                  width: CGFloat, ctx: CGContext) {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0.5 else { return }

        // Head size follows stroke width, in source pixels, so it never changes
        // with zoom.
        let head = max(width * 3.2, 8)
        let control = AnnotationItem.controlPoint(from: from, to: to, style: style)

        // Tangents at each end. For a straight arrow the control point is the
        // midpoint, so these reduce to the segment's own direction.
        let endAngle = atan2(to.y - control.y, to.x - control.x)
        let startAngle = atan2(from.y - control.y, from.x - control.x)

        // Stop the shaft short of each tip it terminates in, so the stroke does not
        // poke through the filled head.
        let inset = head * 0.55
        let shaftEnd = CGPoint(x: to.x - cos(endAngle) * inset,
                               y: to.y - sin(endAngle) * inset)
        let shaftStart = style == .double
            ? CGPoint(x: from.x - cos(startAngle) * inset, y: from.y - sin(startAngle) * inset)
            : from

        ctx.saveGState()
        if style == .dashed {
            ctx.setLineDash(phase: 0, lengths: [width * 2.2, width * 1.8])
        }
        ctx.move(to: shaftStart)
        if style.bow != 0 {
            ctx.addQuadCurve(to: shaftEnd, control: control)
        } else {
            ctx.addLine(to: shaftEnd)
        }
        ctx.strokePath()
        ctx.restoreGState()

        fillHead(at: to, angle: endAngle, size: head, ctx: ctx)
        if style == .double { fillHead(at: from, angle: startAngle, size: head, ctx: ctx) }
    }

    private static func fillHead(at tip: CGPoint, angle: CGFloat,
                                 size: CGFloat, ctx: CGContext) {
        let spread = CGFloat.pi / 7
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: tip.x - cos(angle - spread) * size,
                                y: tip.y - sin(angle - spread) * size))
        ctx.addLine(to: CGPoint(x: tip.x - cos(angle + spread) * size,
                                y: tip.y - sin(angle + spread) * size))
        ctx.closePath()
        ctx.fillPath()
    }

    private static func drawCounter(_ number: Int, at: CGPoint, radius: CGFloat,
                                    ink: CGColor, ctx: CGContext) {
        let circle = CGRect(x: at.x - radius, y: at.y - radius,
                            width: radius * 2, height: radius * 2)
        ctx.setFillColor(ink)
        ctx.fillEllipse(in: circle)

        let label = "\(number)"
        let size = radius * 1.25
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let bounds = textBounds(label, pointSize: size, bold: true)
        let origin = CGPoint(x: at.x - bounds.width / 2, y: at.y - bounds.height / 2)
        drawText(label, at: origin, pointSize: size, color: white, bold: true, ctx: ctx)
    }

    private static func drawFilter(kind: AnnotationFilterKey.Kind, rect: CGRect,
                                   base: CGImage, filters: AnnotationFilterCache,
                                   ctx: CGContext) {
        let standard = rect.standardized.integral
        guard standard.width >= 1, standard.height >= 1 else { return }
        let key = AnnotationFilterKey(kind: kind, rect: standard)
        guard let filtered = filters.image(for: key, base: base) else { return }
        drawImage(filtered, in: key.rect, ctx: ctx)
    }

    // MARK: - Primitives

    /// Draws a `CGImage` into a top-left-origin context without inverting it.
    private static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    /// Core Text rather than AppKit string drawing: this runs off the main actor,
    /// and `NSAttributedString.draw` needs an `NSGraphicsContext` bound to the
    /// current thread.
    private static func makeLine(_ string: String, pointSize: CGFloat,
                                 color: CGColor, bold: Bool) -> CTLine {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString,
                                        pointSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: string, attributes: attributes))
    }

    public static func textBounds(_ string: String, pointSize: CGFloat,
                                  bold: Bool = false) -> CGSize {
        let line = makeLine(string, pointSize: pointSize,
                            color: CGColor(gray: 0, alpha: 1), bold: bold)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return CGSize(width: width, height: ascent + descent + leading)
    }

    private static func drawText(_ string: String, at: CGPoint, pointSize: CGFloat,
                                 color: CGColor, bold: Bool = false, ctx: CGContext) {
        guard !string.isEmpty else { return }
        let line = makeLine(string, pointSize: pointSize, color: color, bold: bold)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        ctx.saveGState()
        // Counter-flip: Core Text draws in a bottom-left-origin space, and `at` is
        // the top-left corner of the text box.
        ctx.translateBy(x: at.x, y: at.y + ascent)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

extension AnnotationInk {
    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
