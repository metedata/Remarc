import XCTest
@testable import RemarcFeature

final class CodexPluginDetectorTests: XCTestCase {
    // Envelope and field names captured from a real `codex plugin list --json`
    // run (codex-cli 0.146.1, 2026-08-06); the remarc entry is adapted to the
    // post-Task-1 semver state (the live test predated the version field and
    // reported version "local").
    private let realOutput = """
    { "installed": [
        { "pluginId": "browser@openai-bundled", "name": "browser", "marketplaceName": "openai-bundled", "version": "26.721.81911", "installed": true, "enabled": true },
        { "pluginId": "remarc@remarc", "name": "remarc", "marketplaceName": "remarc", "version": "0.5.0", "installed": true, "enabled": true }
      ],
      "available": [] }
    """.data(using: .utf8)!

    func testDetectsInstalledRemarcPlugin() throws {
        let state = try CodexPluginDetector.parse(jsonOutput: realOutput)
        XCTAssertTrue(state.remarcInstalled)
        XCTAssertTrue(state.remarcEnabled)
        XCTAssertEqual(state.remarcVersion, "0.5.0")
    }

    func testAbsentRemarcReportsNotInstalled() throws {
        let json = #"{ "installed": [{ "pluginId": "figma@openai-curated", "enabled": true }], "available": [] }"#.data(using: .utf8)!
        let state = try CodexPluginDetector.parse(jsonOutput: json)
        XCTAssertFalse(state.remarcInstalled)
        XCTAssertFalse(state.remarcEnabled)
        XCTAssertNil(state.remarcVersion)
    }

    func testStaleLocalVersionIsSurfaced() throws {
        // Pre-Task-1 installs report version "local" (no manifest version
        // field); Task 4's install gate and Task 6's status row key off it.
        let json = #"{ "installed": [{ "pluginId": "remarc@remarc", "enabled": true, "version": "local" }], "available": [] }"#.data(using: .utf8)!
        let state = try CodexPluginDetector.parse(jsonOutput: json)
        XCTAssertTrue(state.remarcInstalled)
        XCTAssertEqual(state.remarcVersion, "local")
    }

    func testDisabledRemarcReportsInstalledNotEnabled() throws {
        let json = #"{ "installed": [{ "pluginId": "remarc@remarc", "enabled": false }], "available": [] }"#.data(using: .utf8)!
        let state = try CodexPluginDetector.parse(jsonOutput: json)
        XCTAssertTrue(state.remarcInstalled)
        XCTAssertFalse(state.remarcEnabled)
    }

    func testMalformedJSONReportsZero() {
        let state = (try? CodexPluginDetector.parse(jsonOutput: "nope".data(using: .utf8)!)) ?? .zero
        XCTAssertEqual(state, .zero)
    }
}
