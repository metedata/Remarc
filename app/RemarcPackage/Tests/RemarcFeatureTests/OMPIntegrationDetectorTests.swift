import Foundation
import XCTest
@testable import RemarcFeature

final class OMPIntegrationDetectorTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("omp-detector-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    func testDefaultProfileReportsCompleteMCPAndWakeInstall() throws {
        let agent = root.appendingPathComponent("agent", isDirectory: true)
        try installMCP(in: agent)
        try installWake(in: agent)

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertEqual(state.remarcProfiles, ["Default"])
        XCTAssertEqual(state.wakeProfiles, ["Default"])
        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.hasWakeArtifacts)
    }

    func testDefaultProfileReportsCompleteInstallThroughInstallerSymlinks() throws {
        let agent = defaultAgent()
        try installSymlinkedMCP(in: agent)
        try installSymlinkedWake(in: agent)

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertEqual(state.remarcProfiles, ["Default"])
        XCTAssertEqual(state.wakeProfiles, ["Default"])
        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.hasWakeArtifacts)
    }

    func testCompleteNamedProfileReportsItsOwnConfiguration() throws {
        let agent = namedAgent("work")
        try installMCP(in: agent)
        try installWake(in: agent)

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertEqual(state.remarcProfiles, ["work"])
        XCTAssertEqual(state.wakeProfiles, ["work"])
    }

    func testMultipleConfiguredProfilesAreSortedWithDefaultFirst() throws {
        for name in ["zulu", "alpha", "Default"] {
            let agent = name == "Default" ? defaultAgent() : namedAgent(name)
            try installMCP(in: agent)
            try installWake(in: agent)
        }

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertEqual(state.profiles.map(\.name), ["Default", "alpha", "zulu"])
        XCTAssertEqual(state.remarcProfiles, ["Default", "alpha", "zulu"])
        XCTAssertEqual(state.wakeProfiles, ["Default", "alpha", "zulu"])
    }

    func testProfilesDoNotCombineRemarcAndWakeArtifacts() throws {
        try installMCP(in: namedAgent("work"))
        try installWake(in: namedAgent("personal"))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertEqual(state.remarcProfiles, ["work"])
        XCTAssertTrue(state.wakeProfiles.isEmpty)
        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.hasWakeArtifacts)
    }

    func testPartialRemarcInstallNeedsSetupWhenGenericSkillIsMissing() throws {
        let agent = defaultAgent()
        try writeMCP(in: agent)

        let state = OMPIntegrationDetector.read(ompDirectory: root)
        let profile = try XCTUnwrap(state.profiles.first)

        XCTAssertTrue(profile.hasRemarcArtifacts)
        XCTAssertFalse(profile.remarcConfigured)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testPartialRemarcInstallNeedsSetupWhenMCPServerIsMissing() throws {
        let agent = defaultAgent()
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)
        let profile = try XCTUnwrap(state.profiles.first)

        XCTAssertTrue(profile.hasRemarcArtifacts)
        XCTAssertFalse(profile.remarcConfigured)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testDisabledRemarcServerNeedsSetup() throws {
        let agent = defaultAgent()
        try writeMCP(in: agent, disabledServers: ["remarc"])
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testDisabledRemarcServerNeedsSetupWhenEnabledFlagIsFalse() throws {
        let agent = defaultAgent()
        try writeMCP(in: agent, enabled: false)
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testWrongRemarcBundlePathNeedsSetup() throws {
        let agent = defaultAgent()
        try writeMCP(in: agent, args: ["/opt/not-remarc.js"])
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testNonStdioRemarcServerNeedsSetup() throws {
        let agent = defaultAgent()
        try writeMCP(in: agent, type: "http")
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testNonNodeRemarcServerNeedsSetup() throws {
        let agent = defaultAgent()
        try writeMCP(in: agent, command: "bun")
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testRemarcBundleOnlyInLaterArgumentNeedsSetup() throws {
        let agent = defaultAgent()
        try writeMCP(in: agent, args: ["--config", "/opt/remarc-mcp.js"])
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testExtraRemarcArgumentNeedsSetup() throws {
        let agent = defaultAgent()
        try writeMCP(in: agent, args: ["/opt/remarc-mcp.js", "--verbose"])
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testInvalidEnabledTypeNeedsSetup() throws {
        let agent = defaultAgent()
        try writeMCP(in: agent, enabled: "yes")
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testInvalidDisabledServersTypeNeedsSetup() throws {
        let agent = defaultAgent()
        try writeMCP(in: agent, disabledServers: "remarc")
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testRegularFileAtRemarcSkillPathNeedsSetup() throws {
        let agent = defaultAgent()
        try createDirectory(agent.appendingPathComponent("skills", isDirectory: true))
        try Data("not a directory".utf8)
            .write(to: agent.appendingPathComponent("skills/remarc"))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testRegularFileAtReviewSkillPathNeedsSetup() throws {
        let agent = defaultAgent()
        try installMCP(in: agent)
        try createDirectory(agent.appendingPathComponent("extensions/remarc-wake", isDirectory: true))
        try Data("export default {}".utf8)
            .write(to: agent.appendingPathComponent("extensions/remarc-wake/index.ts"))
        try Data("not a directory".utf8)
            .write(to: agent.appendingPathComponent("skills/remarc-review"))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasWakeArtifacts)
        XCTAssertTrue(state.wakeProfiles.isEmpty)
    }

    func testBrokenSkillSymlinkNeedsSetup() throws {
        let agent = defaultAgent()
        try createDirectory(agent)
        try createSymlink(
            at: agent.appendingPathComponent("skills/remarc", isDirectory: true),
            to: root.appendingPathComponent("missing/remarc", isDirectory: true)
        )

        let state = OMPIntegrationDetector.read(ompDirectory: root)
        let profile = try XCTUnwrap(state.profiles.first)

        XCTAssertFalse(profile.hasRemarcArtifacts)
        XCTAssertFalse(profile.remarcConfigured)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testSymlinksToWrongTargetTypesNeedSetup() throws {
        let agent = defaultAgent()
        try writeMCP(in: agent)

        let remarcTarget = root.appendingPathComponent("installer-targets/remarc-skill")
        try createDirectory(remarcTarget.deletingLastPathComponent())
        try Data("not a directory".utf8).write(to: remarcTarget)
        try createSymlink(
            at: agent.appendingPathComponent("skills/remarc", isDirectory: true),
            to: remarcTarget
        )

        let extensionTarget = root.appendingPathComponent("installer-targets/remarc-wake-index", isDirectory: true)
        try createDirectory(extensionTarget)
        try createSymlink(
            at: agent.appendingPathComponent("extensions/remarc-wake/index.ts"),
            to: extensionTarget
        )

        let reviewTarget = root.appendingPathComponent("installer-targets/remarc-review")
        try Data("not a directory".utf8).write(to: reviewTarget)
        try createSymlink(
            at: agent.appendingPathComponent("skills/remarc-review", isDirectory: true),
            to: reviewTarget
        )

        let state = OMPIntegrationDetector.read(ompDirectory: root)
        let profile = try XCTUnwrap(state.profiles.first)

        XCTAssertTrue(profile.hasRemarcArtifacts)
        XCTAssertTrue(profile.hasWakeArtifacts)
        XCTAssertFalse(profile.remarcConfigured)
        XCTAssertFalse(profile.wakeConfigured)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
        XCTAssertTrue(state.wakeProfiles.isEmpty)
    }

    func testDirectoryAtWakeExtensionIndexPathNeedsSetup() throws {
        let agent = defaultAgent()
        try installMCP(in: agent)
        try createDirectory(agent.appendingPathComponent("extensions/remarc-wake/index.ts", isDirectory: true))
        try createDirectory(agent.appendingPathComponent("skills/remarc-review", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasWakeArtifacts)
        XCTAssertTrue(state.wakeProfiles.isEmpty)
    }

    func testPartialWakeInstallNeedsSetupWhenReviewSkillIsMissing() throws {
        let agent = defaultAgent()
        try installMCP(in: agent)
        try createDirectory(agent.appendingPathComponent("extensions/remarc-wake", isDirectory: true))
        try Data("export default {}".utf8)
            .write(to: agent.appendingPathComponent("extensions/remarc-wake/index.ts"))

        let state = OMPIntegrationDetector.read(ompDirectory: root)
        let profile = try XCTUnwrap(state.profiles.first)

        XCTAssertTrue(profile.hasWakeArtifacts)
        XCTAssertFalse(profile.wakeConfigured)
        XCTAssertTrue(state.wakeProfiles.isEmpty)
    }

    func testPartialWakeInstallNeedsSetupWhenExtensionIsMissing() throws {
        let agent = defaultAgent()
        try installMCP(in: agent)
        try createDirectory(agent.appendingPathComponent("skills/remarc-review", isDirectory: true))

        let state = OMPIntegrationDetector.read(ompDirectory: root)
        let profile = try XCTUnwrap(state.profiles.first)

        XCTAssertTrue(profile.hasWakeArtifacts)
        XCTAssertFalse(profile.wakeConfigured)
        XCTAssertTrue(state.wakeProfiles.isEmpty)
    }

    func testMalformedMCPNeedsSetupWithoutDiscardingArtifactStatus() throws {
        let agent = defaultAgent()
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))
        try Data("{".utf8).write(to: agent.appendingPathComponent("mcp.json"))

        let state = OMPIntegrationDetector.read(ompDirectory: root)

        XCTAssertTrue(state.hasRemarcArtifacts)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
    }

    func testAbsentOMPDirectoryReportsNoProfilesOrArtifacts() throws {
        let state = OMPIntegrationDetector.read(
            ompDirectory: root.appendingPathComponent("missing", isDirectory: true)
        )

        XCTAssertTrue(state.profiles.isEmpty)
        XCTAssertTrue(state.remarcProfiles.isEmpty)
        XCTAssertTrue(state.wakeProfiles.isEmpty)
        XCTAssertFalse(state.hasRemarcArtifacts)
        XCTAssertFalse(state.hasWakeArtifacts)
        XCTAssertNil(state.remarcProfileSummary)
        XCTAssertNil(state.wakeProfileSummary)
    }

    func testProfileSummariesUseDefaultThenNamedProfiles() {
        let state = OMPIntegrationState(profiles: [
            .init(
                name: "work",
                hasRemarcArtifacts: true,
                remarcConfigured: true,
                hasWakeArtifacts: true,
                wakeConfigured: true
            ),
            .init(
                name: "Default",
                hasRemarcArtifacts: true,
                remarcConfigured: true,
                hasWakeArtifacts: true,
                wakeConfigured: true
            )
        ])

        XCTAssertEqual(state.remarcProfileSummary, "Default, work")
        XCTAssertEqual(state.wakeProfileSummary, "Default, work")
    }

    private func defaultAgent() -> URL {
        root.appendingPathComponent("agent", isDirectory: true)
    }

    private func namedAgent(_ name: String) -> URL {
        root.appendingPathComponent("profiles", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
    }

    private func installMCP(in agent: URL) throws {
        try writeMCP(in: agent)
        try createDirectory(agent.appendingPathComponent("skills/remarc", isDirectory: true))
    }

    private func installWake(in agent: URL) throws {
        try createDirectory(agent.appendingPathComponent("extensions/remarc-wake", isDirectory: true))
        try Data("export default {}".utf8)
            .write(to: agent.appendingPathComponent("extensions/remarc-wake/index.ts"))
        try createDirectory(agent.appendingPathComponent("skills/remarc-review", isDirectory: true))
    }

    private func installSymlinkedMCP(in agent: URL) throws {
        try writeMCP(in: agent)
        let target = root.appendingPathComponent("installer-targets/skills/remarc", isDirectory: true)
        try createDirectory(target)
        try createSymlink(
            at: agent.appendingPathComponent("skills/remarc", isDirectory: true),
            to: target
        )
    }

    private func installSymlinkedWake(in agent: URL) throws {
        let extensionTarget = root.appendingPathComponent(
            "installer-targets/extensions/remarc-wake/index.ts"
        )
        try createDirectory(extensionTarget.deletingLastPathComponent())
        try Data("export default {}".utf8).write(to: extensionTarget)
        try createSymlink(
            at: agent.appendingPathComponent("extensions/remarc-wake/index.ts"),
            to: extensionTarget
        )

        let reviewTarget = root.appendingPathComponent(
            "installer-targets/skills/remarc-review",
            isDirectory: true
        )
        try createDirectory(reviewTarget)
        try createSymlink(
            at: agent.appendingPathComponent("skills/remarc-review", isDirectory: true),
            to: reviewTarget
        )
    }

    private func writeMCP(
        in agent: URL,
        type: String = "stdio",
        command: String = "node",
        args: [Any] = ["/opt/remarc-mcp.js"],
        enabled: Any = true,
        disabledServers: Any = [String]()
    ) throws {
        try createDirectory(agent)
        let config: [String: Any] = [
            "mcpServers": [
                "remarc": [
                    "type": type,
                    "command": command,
                    "args": args,
                    "enabled": enabled
                ]
            ],
            "disabledServers": disabledServers
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try data.write(to: agent.appendingPathComponent("mcp.json"))
    }

    private func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func createSymlink(at url: URL, to target: URL) throws {
        try createDirectory(url.deletingLastPathComponent())
        try fileManager.createSymbolicLink(
            atPath: url.path,
            withDestinationPath: target.path
        )
    }
}
