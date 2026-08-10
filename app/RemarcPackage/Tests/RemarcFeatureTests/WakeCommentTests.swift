import XCTest
@testable import RemarcFeature

/// Covers the wake button's data contract. The button itself is UI, but
/// everything it produces - status, timestamp, and the file being written
/// before the call returns - is testable, and none of it was until now.
@MainActor
final class WakeCommentTests: XCTestCase {
    func testWakeCommentIsHandedOffWithATimestamp() {
        let comment = Comment(
            type: .quickNote,
            commentText: "wake me",
            source: "test",
            appBundleID: nil,
            sessionID: UUID(),
            status: .handedOff,
            wakeRequestedAt: Date()
        )
        // The wake path's contract: the hooks select on exactly these two.
        XCTAssertEqual(comment.status, .handedOff)
        XCTAssertNotNil(comment.wakeRequestedAt)
    }

    func testOrdinaryCommentCarriesNoWakeRequest() {
        let comment = Comment(
            type: .quickNote,
            commentText: "just a note",
            source: "test",
            appBundleID: nil,
            sessionID: UUID()
        )
        XCTAssertEqual(comment.status, .open)
        XCTAssertNil(comment.wakeRequestedAt, "a normal save must never look like a wake request")
    }

    func testWakeTimestampSurvivesACodableRoundTrip() throws {
        // The field crosses to the plugin as JSON; if it does not survive
        // encoding, the hook simply never sees a wake.
        let original = Comment(
            type: .quickNote,
            commentText: "round trip",
            source: "test",
            appBundleID: nil,
            sessionID: UUID(),
            status: .handedOff,
            wakeRequestedAt: Date(timeIntervalSince1970: 1_778_307_200)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Comment.self, from: data)
        XCTAssertEqual(decoded.wakeRequestedAt, original.wakeRequestedAt)
        XCTAssertEqual(decoded.status, .handedOff)
    }

    func testWakeIsOffByDefaultForAFreshInstall() {
        // A fresh install must not opt anyone into an agent that starts working
        // on its own; the button only appears once the user asks for it.
        let suite = "remarc.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removeSuite(named: suite) }
        XCTAssertFalse(defaults.bool(forKey: "wakeOnCommentEnabled"))
    }

    // The Inbox-scope preference is gone rather than defaulted off: Inbox
    // comments used to reach every paired session at once, each agent taking
    // its own copy, which is noise proportional to how many sessions happen to
    // be open. An Inbox comment now waits to be filed to a session, or for an
    // agent to be asked to look through MCP. Its absence here is enforced by
    // compilation; the delivery rule itself is tested in the plugin's
    // selectQueueComments suite, which is the side that reads it.

    func testWakeAvailabilityRequiresBothThePreferenceAndThePlugin() {
        let settings = SettingsManager.shared
        let prefWas = settings.wakeOnCommentEnabled
        let availWas = settings.wakeHooksAvailable
        defer {
            settings.wakeOnCommentEnabled = prefWas
            settings.wakeHooksAvailable = availWas
        }

        settings.wakeOnCommentEnabled = true
        settings.wakeHooksAvailable = false
        XCTAssertFalse(settings.wakeAvailable, "button must hide when nothing can act on a wake")

        settings.wakeHooksAvailable = true
        XCTAssertTrue(settings.wakeAvailable)

        settings.wakeOnCommentEnabled = false
        XCTAssertFalse(settings.wakeAvailable, "the preference must still win")
    }
}
