import XCTest
@testable import RemarcFeature

/// Cross-language schema validation. The same `comments.sample.json` fixture is
/// validated against `plugins/shared/comments-schema.json` in the plugin repo
/// CI (TypeScript side). This test confirms the Swift `AppState` Codable struct
/// decodes the same fixture. If both pass, app and plugin agree on the schema.
///
/// Catches the v1 plan bug where I had `c.text` vs `c.commentText`: the
/// fixture's `commentText` field must round-trip through Swift's strict decoder.
final class CommentsSchemaFixtureTests: XCTestCase {
    func testCommentsSampleDecodesAgainstAppState() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "comments.sample", withExtension: "json", subdirectory: "Fixtures"),
            "fixture not bundled — check Package.swift testTarget resources"
        )
        let data = try Data(contentsOf: url)
        let state = try JSONDecoder().decode(AppState.self, from: data)

        XCTAssertGreaterThan(state.comments.count, 0, "fixture has comments")
        XCTAssertGreaterThan(state.sessions.count, 0, "fixture has sessions")
        XCTAssertTrue(state.sessions.contains(where: { $0.origin == .omp }), "fixture covers OMP origin")

        // A contextual record remains meaningful without a body. Pin both the
        // required String field and the semantic distinction from Quick Notes.
        let contextual = try XCTUnwrap(state.comments.first { comment in
            if case .comment = comment.type { return true }
            return false
        })
        XCTAssertEqual(contextual.commentText, "")
        XCTAssertFalse(contextual.hasMeaningfulCommentText)
        XCTAssertFalse(contextual.isStandaloneNote)

        // Quick Notes in the shared fixture remain meaningful; an empty Quick
        // Note is invalid input even though the schema stays backward-compatible
        // with String values (including the empty string).
        let quickNotes = state.comments.filter(\.isStandaloneNote)
        XCTAssertFalse(quickNotes.isEmpty, "fixture must exercise Quick Note semantics")
        XCTAssertTrue(
            quickNotes.allSatisfy(\.hasMeaningfulCommentText),
            "fixture Quick Notes must contain meaningful text"
        )

        let encoded = try JSONEncoder().encode(contextual)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["commentText"] as? String, "")
    }

    /// An origin this build has never heard of must not brick the document.
    ///
    /// `SessionOrigin` was a closed `String` enum, so decoding threw on any
    /// unknown value - and because sessions are decoded as part of one document,
    /// a single unrecognised origin made the whole of `comments.json` unreadable.
    /// Every durable save then failed and the app could not write at all.
    /// Measured on device: a branch open across the addition of `codex` was
    /// bricked by a file its own newer build had written.
    func testAnUnknownSessionOriginDoesNotMakeTheDocumentUnreadable() throws {
        let json = """
        {"sessions":[
           {"id":"\(UUID().uuidString)","name":"future","createdAt":0,
            "isDeleted":false,"isAutoDismissed":false,"origin":"teleportation"}],
         "comments":[],"totalCommentsCreated":0}
        """.data(using: .utf8)!

        let state = try JSONDecoder().decode(AppState.self, from: json)

        XCTAssertEqual(state.sessions.count, 1, "one unknown origin must not take the document down")
        // Unknown reads as `.manual` for behaviour, which is the safe default.
        // The original string is kept separately - see the round-trip below.
        XCTAssertEqual(state.sessions[0].origin, .manual)
    }

    /// And it must survive a save, rather than being rewritten to whatever this
    /// build decided it meant. An older app passing through a newer file has to
    /// leave the origin exactly as it found it, or it quietly relabels someone
    /// else's session.
    func testAnUnknownOriginRoundTripsUnchanged() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"future","createdAt":0,
         "isDeleted":false,"isAutoDismissed":false,"origin":"teleportation"}
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(Session.self, from: json)
        let reencoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(session)) as? [String: Any]

        XCTAssertEqual(reencoded?["origin"] as? String, "teleportation",
                       "an origin this build does not know must be written back untouched")
    }

    func testAKnownOriginStillEncodesAsItsOwnRawValue() throws {
        // These strings are the on-disk format. Changing one orphans every
        // session already written with it.
        XCTAssertEqual(SessionOrigin.manual.rawValue, "manual")
        XCTAssertEqual(SessionOrigin.claudeCode.rawValue, "claudeCode")
        XCTAssertEqual(SessionOrigin.codex.rawValue, "codex")
        XCTAssertEqual(SessionOrigin.omp.rawValue, "omp")

        let session = Session(name: "s", origin: .codex)
        let reencoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(session)) as? [String: Any]
        XCTAssertEqual(reencoded?["origin"] as? String, "codex")
    }
}
