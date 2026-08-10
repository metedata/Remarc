import XCTest
@testable import RemarcFeature

final class PluginInstallDetectorTests: XCTestCase {
    func testDetectsBothRemarcPluginsInListJSON() throws {
        // Real `claude plugin list --json` output uses `id` of the form
        // `<plugin>@<marketplace>`. Verified against live CLI.
        let sample = """
        [
          { "id": "remarc@remarc",       "version": "abc", "scope": "user", "enabled": true,  "installPath": "/x/remarc" },
          { "id": "remarc-hooks@remarc", "version": "abc", "scope": "user", "enabled": false, "installPath": "/x/remarc-hooks" },
          { "id": "other@somewhere",     "version": "1.0", "scope": "user", "enabled": true,  "installPath": "/x/other" }
        ]
        """.data(using: .utf8)!

        let state = try PluginInstallDetector.parse(jsonOutput: sample)

        XCTAssertTrue(state.remarcInstalled)
        XCTAssertTrue(state.remarcEnabled)
        XCTAssertTrue(state.remarcHooksInstalled)
        XCTAssertFalse(state.remarcHooksEnabled)
    }

    func testDetectsOnlyMainRemarcWhenHooksNotInstalled() throws {
        let sample = """
        [{ "id": "remarc@remarc", "version": "abc", "scope": "user", "enabled": true, "installPath": "/x" }]
        """.data(using: .utf8)!

        let state = try PluginInstallDetector.parse(jsonOutput: sample)

        XCTAssertTrue(state.remarcInstalled)
        XCTAssertFalse(state.remarcHooksInstalled)
    }

    func testIgnoresOtherMarketplacePluginsWithMatchingNames() throws {
        // Defense against name collision: only `remarc@remarc` should match,
        // not e.g. `remarc@someoneelse`.
        let sample = """
        [{ "id": "remarc@impostor", "version": "abc", "scope": "user", "enabled": true, "installPath": "/x" }]
        """.data(using: .utf8)!

        let state = try PluginInstallDetector.parse(jsonOutput: sample)

        XCTAssertFalse(state.remarcInstalled)
    }

    func testReturnsZeroOnInvalidJSON() throws {
        let state = try PluginInstallDetector.parse(jsonOutput: Data("not json".utf8))
        XCTAssertEqual(state, .zero)
    }

    func testReturnsZeroOnEmptyArray() throws {
        let state = try PluginInstallDetector.parse(jsonOutput: Data("[]".utf8))
        XCTAssertEqual(state, .zero)
    }
}
