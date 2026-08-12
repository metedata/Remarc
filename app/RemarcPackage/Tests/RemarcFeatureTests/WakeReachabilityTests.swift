import XCTest
@testable import RemarcFeature

/// The wake button must reflect which harness is actually running, not which
/// plugin happens to be installed. Codex sessions cannot be woken.
final class WakeReachabilityTests: XCTestCase {
    private var dir: URL!

    /// A temp directory, never the real one. Reading the real markers directory
    /// made these tests depend on whichever agent sessions were running on the
    /// machine: one live Claude Code session with remarc-hooks turned every
    /// "not reachable" assertion into a failure.
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appending(path: "remarc-markers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Two fixed Remarc session ids, so a test can assert that reachability for
    /// one says nothing about the other.
    static let pairedSession = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let otherSession = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private var pairedSession: UUID { Self.pairedSession }
    private var otherSession: UUID { Self.otherSession }

    private func isLive() -> Bool {
        WakeReachability.anyWakeCapableSessionIsLive(in: dir)
    }

    private func isLive(pairedTo session: UUID?) -> Bool {
        WakeReachability.liveWakeCapableSessionExists(pairedTo: session, in: dir)
    }

    /// Exactly what JavaScript's `Date.prototype.toISOString()` produces, which
    /// is what the hooks plugin writes into every marker. Formatting these with
    /// `ISO8601DateFormatter` instead would silently drop the fractional
    /// seconds and test a string that never reaches disk.
    private func nodeISOString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: date)
    }

    private func writeMarker(
        _ name: String,
        wakeCapable: Bool,
        lastActivity: Date?,
        fractionalSeconds: Bool = true,
        transcriptPath: String? = nil,
        remarcSessionId: String = "S1",
        harness: String? = nil,
        ownerPid: Int32? = nil,
        ownerToken: String? = nil
    ) throws {
        var raw: [String: Any] = ["remarcSessionId": remarcSessionId, "wakeCapable": wakeCapable]
        if let harness { raw["harness"] = harness }
        if let transcriptPath { raw["transcriptPath"] = transcriptPath }
        if let ownerPid { raw["ownerPid"] = ownerPid }
        if let ownerToken { raw["ownerToken"] = ownerToken }
        if let lastActivity {
            raw["lastActivity"] = fractionalSeconds
                ? nodeISOString(lastActivity)
                : ISO8601DateFormatter().string(from: lastActivity)
        }
        try JSONSerialization.data(withJSONObject: raw)
            .write(to: dir.appending(path: "test-\(name).json"))
    }

    func testCodexSessionAloneIsNotReachable() throws {
        // A Codex session pairs and delivers comments, but has no rewake hook,
        // so the button must not promise instant delivery.
        try writeMarker("codex", wakeCapable: false, lastActivity: Date())
        XCTAssertFalse(isLive())
    }

    func testLiveClaudeCodeSessionIsReachable() throws {
        try writeMarker("claude", wakeCapable: true, lastActivity: Date())
        XCTAssertTrue(isLive())
    }

    func testStaleSessionIsNotReachable() throws {
        try writeMarker("old", wakeCapable: true, lastActivity: Date(timeIntervalSinceNow: -60 * 60 * 24))
        XCTAssertFalse(isLive())
    }

    func testOneLiveClaudeSessionAmongCodexSessionsIsEnough() throws {
        try writeMarker("codex1", wakeCapable: false, lastActivity: Date())
        try writeMarker("codex2", wakeCapable: false, lastActivity: Date())
        try writeMarker("claude", wakeCapable: true, lastActivity: Date())
        XCTAssertTrue(isLive())
    }

    /// The marker file is rewritten on every delivery, so its mtime is always
    /// "now" and cannot stand in for session liveness. Only `lastActivity`
    /// distinguishes a session that is still working from one that is gone,
    /// which makes parsing it in the format Node writes load-bearing.
    func testStaleSessionIsNotReachableWithNodeFormattedTimestamps() throws {
        try writeMarker(
            "old-node", wakeCapable: true,
            lastActivity: Date(timeIntervalSinceNow: -60 * 60 * 24),
            fractionalSeconds: true
        )
        XCTAssertFalse(
            isLive(),
            "a day-old session read as live: the timestamp Node writes was not parsed"
        )
    }

    /// Markers written before the plugin used millisecond precision must keep
    /// working, so both spellings have to parse.
    func testStaleSessionIsNotReachableWithSecondPrecisionTimestamps() throws {
        try writeMarker(
            "old-plain", wakeCapable: true,
            lastActivity: Date(timeIntervalSinceNow: -60 * 60 * 24),
            fractionalSeconds: false
        )
        XCTAssertFalse(isLive())
    }

    func testLiveSessionWithNodeFormattedTimestampIsReachable() throws {
        try writeMarker("live-node", wakeCapable: true, lastActivity: Date(), fractionalSeconds: true)
        XCTAssertTrue(isLive())
    }


    func testLiveLeasedOMPSessionIgnoresStaleActivityTimestamp() throws {
        try writeMarker(
            "omp-live-stale",
            wakeCapable: true,
            lastActivity: Date(timeIntervalSinceNow: -60 * 60 * 5),
            ownerPid: ProcessInfo.processInfo.processIdentifier,
            ownerToken: UUID().uuidString
        )
        XCTAssertTrue(isLive())
    }

    func testDeadLeasedOMPSessionIgnoresFreshActivityTimestamp() throws {
        try writeMarker(
            "omp-dead-fresh",
            wakeCapable: true,
            lastActivity: Date(),
            ownerPid: 999_999_999,
            ownerToken: UUID().uuidString
        )
        XCTAssertFalse(isLive())
    }
    /// A marker with no usable timestamp at all must not be treated as live:
    /// an abandoned marker would otherwise offer a button that reaches nobody.
    func testMarkerWithNoTimestampIsNotReachable() throws {
        try writeMarker("no-time", wakeCapable: true, lastActivity: nil)
        XCTAssertFalse(isLive())
    }

    /// The app runs `claude plugin list --json` itself, at launch and from
    /// Preferences, to detect the plugin. That fires SessionStart, so the hook
    /// writes a wake-capable marker naming a transcript the invocation exits too
    /// fast to create - and `lastActivity` on it is always "now". Trusting the
    /// timestamp here meant the app read its own detector's exhaust as proof
    /// that a wakeable session existed, and offered a button wired to nothing.
    func testMarkerNamingATranscriptThatDoesNotExistIsNotReachable() throws {
        try writeMarker(
            "phantom", wakeCapable: true, lastActivity: Date(),
            transcriptPath: dir.appending(path: "never-created.jsonl").path
        )
        XCTAssertFalse(
            isLive(),
            "a session whose transcript was never written read as live"
        )
    }

    func testMarkerWithARecentlyTouchedTranscriptIsReachable() throws {
        let transcript = dir.appending(path: "live.jsonl")
        try Data("{}".utf8).write(to: transcript)
        try writeMarker(
            "real", wakeCapable: true, lastActivity: Date(),
            transcriptPath: transcript.path
        )
        XCTAssertTrue(isLive())
    }

    /// The transcript decides on its own once named: a session that stopped
    /// writing a day ago is gone, whatever the marker last stamped.
    func testMarkerWithAStaleTranscriptIsNotReachable() throws {
        let transcript = dir.appending(path: "stale.jsonl")
        try Data("{}".utf8).write(to: transcript)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60 * 60 * 24)],
            ofItemAtPath: transcript.path
        )
        try writeMarker(
            "stale-transcript", wakeCapable: true, lastActivity: Date(),
            transcriptPath: transcript.path
        )
        XCTAssertFalse(isLive())
    }

    /// A byte-for-byte marker as emitted by `remarc-hooks` SessionStart, with
    /// only the timestamp made relative. Every hand-built fixture above encodes
    /// this format by convention; this one encodes it by copy, so a change on
    /// the plugin side that the Swift parser cannot read fails here.
    private func writeRealHookMarker(
        _ name: String,
        lastActivity: Date,
        remarcSessionId: String = WakeReachabilityTests.pairedSession.uuidString
    ) throws {
        let json = """
        {
          "remarcSessionId": "\(remarcSessionId)",
          "dataFilePath": "",
          "transcriptPath": null,
          "lastActivity": "\(nodeISOString(lastActivity))",
          "wakeCapable": true,
          "deliveredIds": [],
          "wakedAt": {}
        }
        """
        try Data(json.utf8).write(to: dir.appending(path: "test-\(name).json"))
    }

    func testRealHookMarkerIsReadAsLive() throws {
        try writeRealHookMarker("real-live", lastActivity: Date())
        XCTAssertTrue(isLive())
    }

    func testRealHookMarkerGoesDeadAfterTheLiveWindow() throws {
        try writeRealHookMarker("real-dead", lastActivity: Date(timeIntervalSinceNow: -60 * 60 * 5))
        XCTAssertFalse(isLive())
    }

    /// SessionStart writes this shape whenever auto-create is off. The agent is
    /// running and could be interrupted, but nothing tells wake which comments
    /// are its own, so it is not a wake target and must not count as one.
    func testUnpairedAgentIsNotReachable() throws {
        try writeRealHookMarker("unpaired", lastActivity: Date(), remarcSessionId: "")
        XCTAssertFalse(isLive())
    }

    func testReachabilityIsScopedToTheSessionAsked() throws {
        try writeRealHookMarker("theirs", lastActivity: Date(), remarcSessionId: "\(otherSession)")
        XCTAssertTrue(isLive(), "any paired agent counts when no session is named")
        XCTAssertTrue(isLive(pairedTo: otherSession))
        XCTAssertFalse(
            isLive(pairedTo: pairedSession),
            "a comment filed elsewhere woke an agent that does not own it"
        )
    }

    /// Session ids round-trip through JSON as Foundation's uppercase UUID
    /// strings, but nothing enforces case on the way in.
    func testPairingMatchIsCaseInsensitive() throws {
        try writeRealHookMarker(
            "lower", lastActivity: Date(),
            remarcSessionId: pairedSession.uuidString.lowercased()
        )
        XCTAssertTrue(isLive(pairedTo: pairedSession))
    }

    func testMalformedMarkerIsIgnored() throws {
        try Data("not json".utf8).write(to: dir.appending(path: "test-broken.json"))
        try writeMarker("claude", wakeCapable: true, lastActivity: Date())
        XCTAssertTrue(isLive())
    }

    func testLiveOMPStatusRequiresOMPHarnessAndLiveLease() throws {
        let livePID = ProcessInfo.processInfo.processIdentifier

        try writeMarker(
            "claude-harness",
            wakeCapable: true,
            lastActivity: Date(),
            harness: "claude-code",
            ownerPid: livePID,
            ownerToken: UUID().uuidString
        )
        XCTAssertFalse(WakeReachability.anyLiveOMPPairingExists(in: dir))

        try removeMarkers()
        try writeMarker(
            "omp-no-lease",
            wakeCapable: true,
            lastActivity: Date(),
            harness: "omp"
        )
        XCTAssertFalse(WakeReachability.anyLiveOMPPairingExists(in: dir))

        try removeMarkers()
        try writeMarker(
            "omp-missing-pid",
            wakeCapable: true,
            lastActivity: Date(),
            harness: "omp",
            ownerToken: UUID().uuidString
        )
        XCTAssertFalse(WakeReachability.anyLiveOMPPairingExists(in: dir))

        try removeMarkers()
        try writeMarker(
            "omp-missing-token",
            wakeCapable: true,
            lastActivity: Date(),
            harness: "omp",
            ownerPid: livePID
        )
        XCTAssertFalse(WakeReachability.anyLiveOMPPairingExists(in: dir))

        try removeMarkers()
        try writeMarker(
            "omp-empty-token",
            wakeCapable: true,
            lastActivity: Date(),
            harness: "omp",
            ownerPid: livePID,
            ownerToken: ""
        )
        XCTAssertFalse(WakeReachability.anyLiveOMPPairingExists(in: dir))


        try removeMarkers()
        try writeMarker(
            "not-wake-capable",
            wakeCapable: false,
            lastActivity: Date(),
            harness: "omp",
            ownerPid: livePID,
            ownerToken: UUID().uuidString
        )
        XCTAssertFalse(WakeReachability.anyLiveOMPPairingExists(in: dir))

        try removeMarkers()
        try writeMarker(
            "unpaired-omp",
            wakeCapable: true,
            lastActivity: Date(),
            remarcSessionId: "",
            harness: "omp",
            ownerPid: livePID,
            ownerToken: UUID().uuidString
        )
        XCTAssertFalse(WakeReachability.anyLiveOMPPairingExists(in: dir))

        try removeMarkers()
        try writeMarker(
            "dead-omp-lease",
            wakeCapable: true,
            lastActivity: Date(),
            harness: "omp",
            ownerPid: 999_999_999,
            ownerToken: UUID().uuidString
        )
        XCTAssertFalse(WakeReachability.anyLiveOMPPairingExists(in: dir))

        try removeMarkers()
        try writeMarker(
            "live-omp",
            wakeCapable: true,
            lastActivity: Date(timeIntervalSinceNow: -60 * 60 * 5),
            harness: "omp",
            ownerPid: livePID,
            ownerToken: UUID().uuidString
        )
        XCTAssertTrue(WakeReachability.anyLiveOMPPairingExists(in: dir))
    }

    private func removeMarkers() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        )
        for entry in entries where entry.pathExtension == "json" {
            try FileManager.default.removeItem(at: entry)
        }
    }
}
