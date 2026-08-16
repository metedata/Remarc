import XCTest
import Foundation
@testable import RemarcFeature

final class PluginUpdateNudgeTests: XCTestCase {
    // MARK: - Version ordering

    func testIsNumericVersion() {
        XCTAssertTrue(PluginInstaller.isNumericVersion("0.13.0"))
        XCTAssertTrue(PluginInstaller.isNumericVersion("1.2"))
        XCTAssertTrue(PluginInstaller.isNumericVersion("10"))
        XCTAssertFalse(PluginInstaller.isNumericVersion("local"))
        XCTAssertFalse(PluginInstaller.isNumericVersion(""))
        XCTAssertFalse(PluginInstaller.isNumericVersion("0.13.0-beta"))
        XCTAssertFalse(PluginInstaller.isNumericVersion("v1.0.0"))
    }

    func testCompareVersions() {
        XCTAssertEqual(PluginInstaller.compareVersions("0.10.0", "0.13.0"), -1)
        XCTAssertEqual(PluginInstaller.compareVersions("0.13.0", "0.13.0"), 0)
        XCTAssertEqual(PluginInstaller.compareVersions("0.13.1", "0.13.0"), 1)
        XCTAssertEqual(PluginInstaller.compareVersions("1.0.0", "0.99.99"), 1)
        // Missing trailing components count as zero.
        XCTAssertEqual(PluginInstaller.compareVersions("0.13", "0.13.0"), 0)
        XCTAssertEqual(PluginInstaller.compareVersions("0.13", "0.13.1"), -1)
    }

    // MARK: - updateAvailable

    func testUpdateAvailableWhenInstalledIsOlder() {
        XCTAssertTrue(PluginInstaller.updateAvailable(installedVersion: "0.10.0", bundledVersion: "0.13.0"))
    }

    func testNoUpdateWhenCurrentOrNewer() {
        XCTAssertFalse(PluginInstaller.updateAvailable(installedVersion: "0.13.0", bundledVersion: "0.13.0"))
        XCTAssertFalse(PluginInstaller.updateAvailable(installedVersion: "0.14.0", bundledVersion: "0.13.0"))
    }

    func testNoNagForMissingOrNonNumericVersion() {
        // A "local"/dev install or a missing version must never show "update available".
        XCTAssertFalse(PluginInstaller.updateAvailable(installedVersion: nil, bundledVersion: "0.13.0"))
        XCTAssertFalse(PluginInstaller.updateAvailable(installedVersion: "local", bundledVersion: "0.13.0"))
        XCTAssertFalse(PluginInstaller.updateAvailable(installedVersion: "0.10.0", bundledVersion: "local"))
    }

    // MARK: - Detector captures the installed version

    func testParseCapturesInstalledRemarcVersion() throws {
        let json = """
        [
          {"id": "remarc@remarc", "version": "0.10.0", "enabled": true},
          {"id": "remarc-hooks@remarc", "version": "0.10.0", "enabled": false}
        ]
        """
        let state = try PluginInstallDetector.parse(jsonOutput: Data(json.utf8))
        XCTAssertTrue(state.remarcInstalled)
        XCTAssertEqual(state.remarcVersion, "0.10.0")
        XCTAssertTrue(PluginInstaller.updateAvailable(
            installedVersion: state.remarcVersion,
            bundledVersion: "0.13.0"
        ))
    }

    func testParseVersionNilWhenNotInstalled() throws {
        let state = try PluginInstallDetector.parse(jsonOutput: Data("[]".utf8))
        XCTAssertFalse(state.remarcInstalled)
        XCTAssertNil(state.remarcVersion)
    }

    // MARK: - Drift guard

    func testBundledPluginVersionMatchesVendoredProvenance() throws {
        // The generated BundledPluginVersion.remarc and mcp/vendor/PROVENANCE.json
        // are both written from $VERSION by sync-mcp-vendor.sh; this catches a
        // hand-edit of one without the other.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let provenanceURL = root.appendingPathComponent("mcp/vendor/PROVENANCE.json")
        let data = try Data(contentsOf: provenanceURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pluginVersion = try XCTUnwrap(json["pluginVersion"] as? String)
        XCTAssertEqual(BundledPluginVersion.remarc, pluginVersion,
                       "BundledPluginVersion.remarc is stale - re-run scripts/sync-mcp-vendor.sh")
    }
}
