import XCTest
@testable import RemarcFeature

/// The stored form of a mark is a file format, so these guard the shape as much
/// as the round trip.
final class AnnotationItemCodingTests: XCTestCase {

    private func roundTrip(_ payload: AnnotationPayload,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let item = AnnotationItem(payload: payload,
                                  ink: AnnotationInk(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4),
                                  strokeWidth: 5.5)
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(AnnotationItem.self, from: data)

        XCTAssertEqual(decoded.payload, payload, file: file, line: line)
        XCTAssertEqual(decoded.id, item.id, "identity has to survive: undo and hit-testing key on it",
                       file: file, line: line)
        XCTAssertEqual(decoded.ink, item.ink, file: file, line: line)
        XCTAssertEqual(decoded.strokeWidth, item.strokeWidth, file: file, line: line)
    }

    /// One assertion per case. A `default` here would let a newly added payload
    /// ship with no coverage at all.
    func testEveryPayloadCaseRoundTrips() throws {
        let a = CGPoint(x: 1.5, y: 2.5)
        let b = CGPoint(x: 30.25, y: 40.75)
        let r = CGRect(x: 3, y: 4, width: 50, height: 60)

        for style in AnnotationArrowStyle.allCases {
            try roundTrip(.arrow(from: a, to: b, style: style))
        }
        try roundTrip(.line(from: a, to: b))
        try roundTrip(.rect(r))
        try roundTrip(.oval(r))
        try roundTrip(.freehand(points: [a, b, .zero]))
        try roundTrip(.highlighter(points: [a, b]))
        try roundTrip(.text("hello \u{1F600} world", at: a, pointSize: 17.5))
        try roundTrip(.counter(7, at: b, radius: 12.5))
        try roundTrip(.blur(r))
        try roundTrip(.pixelate(r))
    }

    /// Geometry is stored in source pixels and must come back bit-identical:
    /// a rounded coordinate would drift a mark every save.
    func testCoordinatesSurviveExactly() throws {
        let odd = CGRect(x: 0.1, y: 1234.5678, width: 9.87654321, height: 0.5)
        let data = try JSONEncoder().encode(
            AnnotationItem(payload: .rect(odd), ink: AnnotationInk.presets[0], strokeWidth: 1))
        let decoded = try JSONDecoder().decode(AnnotationItem.self, from: data)

        guard case let .rect(back) = decoded.payload else { return XCTFail("wrong case") }
        XCTAssertEqual(back, odd)
    }

    /// Named fields, not Foundation's unkeyed CGRect encoding. If this breaks,
    /// every mark already on disk is unreadable.
    func testTheStoredShapeUsesNamedFields() throws {
        let data = try JSONEncoder().encode(
            AnnotationItem(payload: .rect(CGRect(x: 3, y: 4, width: 5, height: 6)),
                           ink: AnnotationInk(red: 1, green: 0, blue: 0), strokeWidth: 2))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["kind"] as? String, "rect")
        let rect = try XCTUnwrap(payload["rect"] as? [String: Any])
        XCTAssertEqual(rect["x"] as? Double, 3)
        XCTAssertEqual(rect["width"] as? Double, 5)

        let ink = try XCTUnwrap(json["ink"] as? [String: Any])
        XCTAssertEqual(ink["red"] as? Double, 1)
    }

    /// A kind this build does not know must fail loudly. Silently dropping it
    /// would delete one of the user's marks on the next save.
    func testAnUnknownKindFailsRatherThanDroppingTheMark() {
        let json = """
        {"id":"\(UUID().uuidString)","strokeWidth":2,
         "ink":{"red":1,"green":0,"blue":0,"alpha":1},
         "payload":{"kind":"hologram"}}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(AnnotationItem.self, from: json))
    }

    func testRedactionsAreExactlyBlurAndPixelate() {
        XCTAssertTrue(AnnotationPayload.blur(.zero).isRedaction)
        XCTAssertTrue(AnnotationPayload.pixelate(.zero).isRedaction)

        XCTAssertFalse(AnnotationPayload.rect(.zero).isRedaction)
        XCTAssertFalse(AnnotationPayload.oval(.zero).isRedaction)
        XCTAssertFalse(AnnotationPayload.line(from: .zero, to: .zero).isRedaction)
        XCTAssertFalse(AnnotationPayload.arrow(from: .zero, to: .zero, style: .straight).isRedaction)
        XCTAssertFalse(AnnotationPayload.freehand(points: []).isRedaction)
        XCTAssertFalse(AnnotationPayload.highlighter(points: []).isRedaction)
        XCTAssertFalse(AnnotationPayload.text("x", at: .zero, pointSize: 12).isRedaction)
        XCTAssertFalse(AnnotationPayload.counter(1, at: .zero, radius: 8).isRedaction)
    }
}
