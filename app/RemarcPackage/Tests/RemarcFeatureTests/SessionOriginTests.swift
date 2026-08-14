import XCTest
@testable import RemarcFeature

/// `origin` names the harness that created a session, and harnesses arrive on
/// the plugin's release schedule rather than the app's - so the app is
/// routinely the older reader of a newer writer's file.
final class SessionOriginTests: XCTestCase {
    private func decodeSession(origin: String?) throws -> Session {
        let originField = origin.map { "\"origin\": \"\($0)\"," } ?? ""
        let json = """
        {
          "id": "9E1C2F4A-0000-4000-8000-000000000001",
          "name": "proj",
          "createdAt": 807824960.0,
          "isDeleted": false,
          "isAutoDismissed": false,
          \(originField)
          "claudeCodeSessionId": "abc-123"
        }
        """
        return try JSONDecoder().decode(Session.self, from: Data(json.utf8))
    }

    func testCodexOriginRoundTrips() throws {
        XCTAssertEqual(try decodeSession(origin: "codex").origin, .codex)
    }

    func testClaudeCodeOriginStillDecodes() throws {
        XCTAssertEqual(try decodeSession(origin: "claudeCode").origin, .claudeCode)
    }

    func testOMPOriginRoundTrips() throws {
        let session = try decodeSession(origin: "omp")
        XCTAssertEqual(session.origin, .omp)

        let data = try JSONEncoder().encode(session)
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(raw["origin"] as? String, "omp")
    }

    func testAbsentOriginFallsBackToManual() throws {
        XCTAssertEqual(try decodeSession(origin: nil).origin, .manual)
    }

    /// The regression that made this file exist. Decoding straight into the
    /// enum throws on any value it does not know, and the throw is not confined
    /// to the field - it fails the whole `Session`, and with it the decode of
    /// every session in `comments.json`. Adding `codex` on the plugin side
    /// would have bricked the session list of every app build that predates it.
    func testUnknownHarnessDecodesAsManualInsteadOfFailingTheFile() throws {
        let session = try decodeSession(origin: "somethingShippedLater")
        XCTAssertEqual(session.origin, .manual)
        XCTAssertEqual(session.name, "proj", "the rest of the session must survive")
    }

    func testEncodingKeepsTheRawHarnessName() throws {
        let data = try JSONEncoder().encode(Session(name: "s", origin: .codex))
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(raw["origin"] as? String, "codex")
    }
}
