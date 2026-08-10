import XCTest
@testable import RemarcFeature

/// `comments.json` is written by the app, the MCP server, and the hooks plugin,
/// on two release schedules. Whoever ships a field first, everyone else is
/// briefly an older reader of it - and a closed `CodingKeys` set drops what it
/// does not name. `contracts.md` claimed both serializers round-tripped
/// unmodelled fields; the Swift half did not exist until these tests did.
final class UnknownFieldPreservationTests: XCTestCase {
    private func roundTrip(_ json: String) throws -> [String: Any] {
        let state = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        let out = try JSONEncoder().encode(state)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: out) as? [String: Any]
        )
    }

    func testDocumentLevelUnknownFieldSurvives() throws {
        let raw = try roundTrip("""
        {
          "sessions": [], "comments": [], "totalCommentsCreated": 0,
          "schemaVersion": 2,
          "somethingShippedLater": { "nested": ["a", 1, true, null] }
        }
        """)
        XCTAssertEqual(raw["schemaVersion"] as? Int, 2)
        let nested = try XCTUnwrap(raw["somethingShippedLater"] as? [String: Any])
        XCTAssertEqual((nested["nested"] as? [Any])?.count, 4)
    }

    func testSessionLevelUnknownFieldSurvives() throws {
        let raw = try roundTrip("""
        {
          "sessions": [{
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "proj", "createdAt": 807824960.0,
            "isDeleted": false, "isAutoDismissed": false,
            "workspacePath": "/Users/m/proj"
          }],
          "comments": [], "totalCommentsCreated": 0
        }
        """)
        let session = try XCTUnwrap((raw["sessions"] as? [[String: Any]])?.first)
        XCTAssertEqual(session["workspacePath"] as? String, "/Users/m/proj")
    }

    /// The concrete regression: an earlier plugin build deleted these two
    /// arrays outright on every write.
    func testModelledArraysAreNotDroppedWhenPresent() throws {
        let raw = try roundTrip("""
        {
          "sessions": [], "comments": [], "totalCommentsCreated": 3,
          "transcriptions": [], "orphanedImages": []
        }
        """)
        XCTAssertEqual(raw["totalCommentsCreated"] as? Int, 3)
    }

    /// A harness this build has never heard of must keep its own name. Decoding
    /// it as `.manual` and writing `manual` back would relabel someone else's
    /// session - silently, and permanently.
    func testUnknownSessionOriginRoundTripsAsItself() throws {
        let raw = try roundTrip("""
        {
          "sessions": [{
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "proj", "createdAt": 807824960.0,
            "isDeleted": false, "isAutoDismissed": false,
            "origin": "someFutureHarness"
          }],
          "comments": [], "totalCommentsCreated": 0
        }
        """)
        let session = try XCTUnwrap((raw["sessions"] as? [[String: Any]])?.first)
        XCTAssertEqual(session["origin"] as? String, "someFutureHarness")
    }

    func testKnownOriginsStillEncodeNormally() throws {
        for origin in ["manual", "claudeCode", "codex"] {
            let raw = try roundTrip("""
            {
              "sessions": [{
                "id": "11111111-1111-1111-1111-111111111111",
                "name": "proj", "createdAt": 807824960.0,
                "isDeleted": false, "isAutoDismissed": false,
                "origin": "\(origin)"
              }],
              "comments": [], "totalCommentsCreated": 0
            }
            """)
            let session = try XCTUnwrap((raw["sessions"] as? [[String: Any]])?.first)
            XCTAssertEqual(session["origin"] as? String, origin)
        }
    }

    /// A field this build models is the authority for its own key: a preserved
    /// copy must never shadow it.
    func testPreservedFieldsCannotOverwriteModelledOnes() throws {
        var state = AppState(totalCommentsCreated: 7)
        state.unknownFields["totalCommentsCreated"] = .number(999)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(state))
                as? [String: Any]
        )
        XCTAssertEqual(raw["totalCommentsCreated"] as? Int, 7)
    }
}
