import XCTest
@testable import RemarcFeature

/// The wake button must reflect which harness is actually running, not which
/// plugin happens to be installed. Codex sessions cannot be woken.
final class WakeReachabilityTests: XCTestCase {
    private struct OMPLeaseContractFixture: Decodable {
        let fixtureVersion: Int
        let now: String
        let requestedRemarcSessionId: UUID
        let cases: [OMPLeaseContractCase]
    }

    private struct OMPLeaseContractCase: Decodable {
        let name: String
        let ownerAlive: Bool
        let expectedReachable: Bool
        let marker: [String: JSONValue]
    }

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

    private func isLive(
        pairedTo session: UUID?,
        now: Date,
        processIsLive: (Int32) -> Bool
    ) -> Bool {
        WakeReachability.liveWakeCapableSessionExists(
            pairedTo: session,
            in: dir,
            now: now,
            processIsLive: processIsLive
        )
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
        transcriptPath: String? = nil
    ) throws {
        var raw: [String: Any] = ["remarcSessionId": "S1", "wakeCapable": wakeCapable]
        if let transcriptPath { raw["transcriptPath"] = transcriptPath }
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

    private func validOMPMarker(now: Date) -> [String: Any] {
        [
            "remarcSessionId": pairedSession.uuidString,
            "wakeCapable": true,
            "protocolVersion": 1,
            "harness": "omp",
            "ownerPid": 4_242,
            "ownerToken": "0123456789abcdef0123456789abcdef",
            "leaseHeartbeatAt": nodeISOString(now),
        ]
    }

    private func writeRawMarker(_ name: String, raw: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: raw)
            .write(to: dir.appending(path: "test-\(name).json"))
    }

    private func loadOMPLeaseContractFixture() throws -> (OMPLeaseContractFixture, Date) {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "omp-lease-v1",
                withExtension: "json",
                subdirectory: "Fixtures"
            ),
            "cross-language OMP lease fixture is not bundled"
        )
        let fixture = try JSONDecoder().decode(
            OMPLeaseContractFixture.self,
            from: Data(contentsOf: url)
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = try XCTUnwrap(formatter.date(from: fixture.now), "invalid fixture now")
        return (fixture, now)
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

    func testLiveOMPLeaseIsReachable() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try writeRawMarker("omp-live", raw: validOMPMarker(now: now))

        XCTAssertTrue(
            isLive(pairedTo: pairedSession, now: now, processIsLive: { $0 == 4_242 })
        )
    }

    func testOMPLeaseV1MatchesCrossLanguageFixture() throws {
        let (fixture, now) = try loadOMPLeaseContractFixture()
        XCTAssertEqual(fixture.fixtureVersion, 1)
        XCTAssertEqual(fixture.requestedRemarcSessionId, pairedSession)

        for (index, contractCase) in fixture.cases.enumerated() {
            let markerData = try JSONEncoder().encode(contractCase.marker)
            let raw = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: markerData) as? [String: Any],
                contractCase.name
            )
            let markerName = "omp-contract-\(index)"
            try writeRawMarker(markerName, raw: raw)

            let reachable = isLive(
                pairedTo: fixture.requestedRemarcSessionId,
                now: now,
                processIsLive: { _ in contractCase.ownerAlive }
            )
            XCTAssertEqual(
                reachable,
                contractCase.expectedReachable,
                "cross-language OMP lease case: \(contractCase.name)"
            )
            try FileManager.default.removeItem(
                at: dir.appending(path: "test-\(markerName).json")
            )
        }
    }

    func testOMPLeaseRequiresALiveOwnerProcess() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try writeRawMarker("omp-dead-owner", raw: validOMPMarker(now: now))

        XCTAssertFalse(
            isLive(pairedTo: pairedSession, now: now, processIsLive: { _ in false })
        )
    }

    func testOMPLeaseHeartbeatBoundariesAreInclusive() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var oldest = validOMPMarker(now: now)
        oldest["leaseHeartbeatAt"] = nodeISOString(now.addingTimeInterval(-60))
        try writeRawMarker("omp-oldest-live", raw: oldest)

        XCTAssertTrue(
            isLive(pairedTo: pairedSession, now: now, processIsLive: { _ in true })
        )
        try FileManager.default.removeItem(at: dir.appending(path: "test-omp-oldest-live.json"))

        var furthestFuture = validOMPMarker(now: now)
        furthestFuture["leaseHeartbeatAt"] = nodeISOString(now.addingTimeInterval(30))
        try writeRawMarker("omp-future-live", raw: furthestFuture)

        XCTAssertTrue(
            isLive(pairedTo: pairedSession, now: now, processIsLive: { _ in true })
        )
    }

    func testStaleOMPHeartbeatIsNotReachable() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var raw = validOMPMarker(now: now)
        raw["leaseHeartbeatAt"] = nodeISOString(now.addingTimeInterval(-61))
        try writeRawMarker("omp-stale", raw: raw)

        XCTAssertFalse(
            isLive(pairedTo: pairedSession, now: now, processIsLive: { _ in true })
        )
    }

    func testFarFutureOMPHeartbeatIsNotReachable() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var raw = validOMPMarker(now: now)
        raw["leaseHeartbeatAt"] = nodeISOString(now.addingTimeInterval(31))
        try writeRawMarker("omp-far-future", raw: raw)

        XCTAssertFalse(
            isLive(pairedTo: pairedSession, now: now, processIsLive: { _ in true })
        )
    }

    func testOMPLeaseRequiresEveryVersionedOwnershipField() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for key in ["protocolVersion", "ownerPid", "ownerToken", "leaseHeartbeatAt"] {
            var raw = validOMPMarker(now: now)
            raw.removeValue(forKey: key)
            try writeRawMarker("omp-missing-\(key)", raw: raw)
        }

        XCTAssertFalse(
            isLive(pairedTo: pairedSession, now: now, processIsLive: { _ in true })
        )
    }

    func testOMPLeaseRejectsWrongHarnessAndUnknownProtocol() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let transcript = dir.appending(path: "wrong-harness-live-looking.jsonl")
        try Data("{}".utf8).write(to: transcript)
        var wrongHarness = validOMPMarker(now: now)
        wrongHarness["harness"] = "claudeCode"
        wrongHarness["lastActivity"] = nodeISOString(now)
        wrongHarness["transcriptPath"] = transcript.path
        try writeRawMarker("omp-wrong-harness", raw: wrongHarness)

        var unknownVersion = validOMPMarker(now: now)
        unknownVersion["protocolVersion"] = 2
        try writeRawMarker("omp-unknown-version", raw: unknownVersion)

        XCTAssertFalse(
            isLive(pairedTo: pairedSession, now: now, processIsLive: { _ in true })
        )
    }

    func testOMPLeaseRejectsMalformedNumericAndTokenFields() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var numericWakeCapability = validOMPMarker(now: now)
        numericWakeCapability["wakeCapable"] = 1
        try writeRawMarker("omp-numeric-wake-capability", raw: numericWakeCapability)

        var booleanVersion = validOMPMarker(now: now)
        booleanVersion["protocolVersion"] = true
        try writeRawMarker("omp-boolean-version", raw: booleanVersion)

        var fractionalPID = validOMPMarker(now: now)
        fractionalPID["ownerPid"] = 4_242.5
        try writeRawMarker("omp-fractional-pid", raw: fractionalPID)

        var blankToken = validOMPMarker(now: now)
        blankToken["ownerToken"] = "   "
        try writeRawMarker("omp-blank-token", raw: blankToken)

        XCTAssertFalse(
            isLive(pairedTo: pairedSession, now: now, processIsLive: { _ in true })
        )
    }

    func testOMPMarkerCannotFallBackToLegacyActivityOrTranscript() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let transcript = dir.appending(path: "omp-live-looking.jsonl")
        try Data("{}".utf8).write(to: transcript)

        var raw = validOMPMarker(now: now)
        raw.removeValue(forKey: "ownerToken")
        raw["lastActivity"] = nodeISOString(now)
        raw["transcriptPath"] = transcript.path
        try writeRawMarker("omp-no-legacy-fallback", raw: raw)

        XCTAssertFalse(
            isLive(pairedTo: pairedSession, now: now, processIsLive: { _ in true })
        )

        var missingHarness = validOMPMarker(now: now)
        missingHarness.removeValue(forKey: "harness")
        missingHarness["lastActivity"] = nodeISOString(now)
        missingHarness["transcriptPath"] = transcript.path
        try writeRawMarker("omp-missing-harness", raw: missingHarness)

        XCTAssertFalse(
            isLive(pairedTo: pairedSession, now: now, processIsLive: { _ in false })
        )
    }

    func testOMPReachabilityIsScopedToTheRequestedRemarcSession() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try writeRawMarker("omp-other-session", raw: validOMPMarker(now: now))

        XCTAssertFalse(
            isLive(pairedTo: otherSession, now: now, processIsLive: { _ in true })
        )
    }

    func testCurrentProcessSatisfiesDefaultOMPProcessProbe() throws {
        let now = Date.now
        var raw = validOMPMarker(now: now)
        raw["ownerPid"] = ProcessInfo.processInfo.processIdentifier
        try writeRawMarker("omp-current-process", raw: raw)

        XCTAssertTrue(
            WakeReachability.liveWakeCapableSessionExists(
                pairedTo: pairedSession,
                in: dir,
                now: now
            )
        )
    }

    func testMalformedMarkerIsIgnored() throws {
        try Data("not json".utf8).write(to: dir.appending(path: "test-broken.json"))
        try writeMarker("claude", wakeCapable: true, lastActivity: Date())
        XCTAssertTrue(isLive())
    }
}
