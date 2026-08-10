import XCTest
@testable import RemarcFeature

final class LegacyInstallCleanupTests: XCTestCase {
    func testIsRemarcHookMatchesCommandPrefix() {
        let hook: [String: Any] = [
            "type": "command",
            "command": "REMARC_CLI_PATH='/x/cli.js' REMARC_NODE_PATH='/usr/local/bin/node' '/x/scripts/hooks/remarc-session-start.sh'"
        ]
        XCTAssertTrue(LegacyInstallCleanup.isRemarcHook(hook))
    }

    func testIsRemarcHookMatchesScriptPath() {
        let hook: [String: Any] = [
            "type": "command",
            "command": "/some/path/scripts/hooks/remarc-prompt-submit.sh"
        ]
        XCTAssertTrue(LegacyInstallCleanup.isRemarcHook(hook))
    }

    func testIsRemarcHookDoesNotMatchPluginProvidedHooks() {
        // Plugin-provided hooks use ${CLAUDE_PLUGIN_ROOT} which doesn't match
        // either marker. They should survive cleanup.
        let pluginHook: [String: Any] = [
            "type": "command",
            "command": "node",
            "args": ["${CLAUDE_PLUGIN_ROOT}/cli/dist/hook.js", "session-start"]
        ]
        XCTAssertFalse(LegacyInstallCleanup.isRemarcHook(pluginHook))
    }

    func testIsRemarcHookDoesNotMatchUnrelatedHooks() {
        let other: [String: Any] = [
            "type": "command",
            "command": "/usr/local/bin/some-other-tool.sh"
        ]
        XCTAssertFalse(LegacyInstallCleanup.isRemarcHook(other))
    }

    func testIsRemarcHookMatchesExecFormWithArgs() {
        let execHook: [String: Any] = [
            "type": "command",
            "command": "node",
            "args": ["/x/scripts/hooks/remarc-session-end.sh"]
        ]
        XCTAssertTrue(LegacyInstallCleanup.isRemarcHook(execHook))
    }

    // MARK: - Post-completion recheck (the flag must un-latch when a legacy
    // build or a live claude session restores artifacts after cleanup ran)

    func testDetectsUserScopeRemarcMCPInClaudeConfig() throws {
        let json = """
        { "mcpServers": { "remarc": { "command": "node", "args": ["/x/mcp/dist/index.js"] } },
          "projects": {} }
        """.data(using: .utf8)!
        XCTAssertTrue(LegacyInstallCleanup.hasUserScopeRemarcMCP(claudeConfigJSON: json))
    }

    func testIgnoresOtherUserScopeServers() throws {
        let json = """
        { "mcpServers": { "context7": { "command": "npx" } } }
        """.data(using: .utf8)!
        XCTAssertFalse(LegacyInstallCleanup.hasUserScopeRemarcMCP(claudeConfigJSON: json))
    }

    func testIgnoresProjectScopeRemarcServers() throws {
        // Project-scope registrations (from a repo's .mcp.json) are not the
        // legacy user-scope artifact - only top-level mcpServers counts.
        let json = """
        { "mcpServers": {},
          "projects": { "/Users/x/Developer/Remarc": { "mcpServers": { "remarc": { "command": "node" } } } } }
        """.data(using: .utf8)!
        XCTAssertFalse(LegacyInstallCleanup.hasUserScopeRemarcMCP(claudeConfigJSON: json))
    }

    func testMalformedClaudeConfigReportsNoLegacyMCP() {
        let json = "not json at all".data(using: .utf8)!
        XCTAssertFalse(LegacyInstallCleanup.hasUserScopeRemarcMCP(claudeConfigJSON: json))
    }

    func testCustomServerSharingTheNameIsNotOurs() {
        // A user's own server that merely reuses the name `remarc` must never
        // be treated as the legacy artifact - deleting it would destroy
        // deliberate user config on every launch.
        let json = """
        { "mcpServers": { "remarc": { "command": "/usr/local/bin/my-custom-server", "args": ["--port", "9000"] } } }
        """.data(using: .utf8)!
        XCTAssertFalse(LegacyInstallCleanup.hasUserScopeRemarcMCP(claudeConfigJSON: json))
    }

    func testLegacySignatureMatchesBothInstallLayouts() {
        // Dev layout (repo checkout) and end-user layout (stable app support
        // path) both end in mcp/dist/index.js.
        XCTAssertTrue(LegacyInstallCleanup.legacyMCPSignatureMatches(
            ["command": "/opt/homebrew/bin/node", "args": ["/Users/x/Developer/Remarc/mcp/dist/index.js"]]
        ))
        XCTAssertTrue(LegacyInstallCleanup.legacyMCPSignatureMatches(
            ["command": "node", "args": ["/Users/x/Library/Application Support/Remarc/mcp/dist/index.js"]]
        ))
        XCTAssertFalse(LegacyInstallCleanup.legacyMCPSignatureMatches(
            ["command": "python3", "args": ["/opt/tools/remarc-like/server.py"]]
        ))
    }

    func testUnrelatedEnvSettingDoesNotTripHookMarkers() {
        // The recheck marker must stay exactly as broad as isRemarcHook - a
        // bare REMARC_CLI_PATH env key (no equals sign) is not removable by
        // hook cleanup and must not un-latch the migration forever.
        XCTAssertFalse(LegacyInstallCleanup.settingsContainLegacyHookMarkers(
            #"{"env":{"REMARC_CLI_PATH":"/custom"}}"#
        ))
    }

    func testSettingsMarkerScanMatchesLegacyMarkers() {
        XCTAssertTrue(LegacyInstallCleanup.settingsContainLegacyHookMarkers(
            #"{"hooks":{"SessionStart":[{"hooks":[{"command":"REMARC_CLI_PATH=/x node /y"}]}]}}"#
        ))
        XCTAssertTrue(LegacyInstallCleanup.settingsContainLegacyHookMarkers(
            #"{"hooks":{"SessionEnd":[{"hooks":[{"command":"/x/scripts/hooks/remarc-session-end.sh"}]}]}}"#
        ))
    }

    func testSettingsMarkerScanIgnoresPluginEntries() {
        XCTAssertFalse(LegacyInstallCleanup.settingsContainLegacyHookMarkers(
            #"{"enabledPlugins":["remarc@remarc","remarc-hooks@remarc"],"extraKnownMarketplaces":{"remarc":{"source":"metedata/remarc-agent-plugins"}}}"#
        ))
    }
}
