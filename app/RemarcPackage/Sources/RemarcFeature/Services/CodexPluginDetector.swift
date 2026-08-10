import Foundation

public struct CodexPluginState: Equatable, Sendable {
    public let remarcInstalled: Bool
    public let remarcEnabled: Bool
    /// Codex's version string for the installed plugin. `"local"` marks a
    /// stale pre-semver install (Codex prefers a `local` version dir over
    /// numeric ones, shadowing every future update); nil when not installed
    /// or the field is missing.
    public let remarcVersion: String?

    public static let zero = CodexPluginState(remarcInstalled: false, remarcEnabled: false, remarcVersion: nil)
}

/// Reads installed Codex plugins via `codex plugin list --json` (documented,
/// scriptable CLI surface). Mirrors PluginInstallDetector for Claude Code.
public final class CodexPluginDetector: Sendable {
    public init() {}

    /// Public for testing. Output shape verified against codex-cli 0.146.1:
    /// { "installed": [ { "pluginId": "remarc@remarc", "enabled": true, ... } ], "available": [...] }
    public static func parse(jsonOutput: Data) throws -> CodexPluginState {
        guard let root = (try? JSONSerialization.jsonObject(with: jsonOutput)) as? [String: Any],
              let installed = root["installed"] as? [[String: Any]]
        else { return .zero }
        let remarc = installed.first { ($0["pluginId"] as? String) == CodexPluginInstaller.pluginId }
        return CodexPluginState(
            remarcInstalled: remarc != nil,
            remarcEnabled: (remarc?["enabled"] as? Bool) ?? false,
            remarcVersion: remarc?["version"] as? String
        )
    }

    public func read() async -> CodexPluginState {
        guard let codex = await ShellResolver.resolveBinaryPath("codex") else { return .zero }
        // runCollectingResult, NOT runCapture: runCapture sends SIGTERM on
        // timeout and never escalates to SIGKILL, so a codex process that
        // traps or ignores it would hang detection forever. This path runs
        // on the Preferences .task and after every install, so it must be
        // bounded. mergeStderr: false because codex warns on stderr and
        // that would corrupt the JSON.
        guard let result = await ProcessRunner.runCollectingResult(
            codex, arguments: ["plugin", "list", "--json"],
            timeoutSeconds: 10, mergeStderr: false
        ), !result.timedOut, result.exitCode == 0 else { return .zero }
        let data = Data(result.output.utf8)
        guard !data.isEmpty else { return .zero }
        return (try? Self.parse(jsonOutput: data)) ?? .zero
    }
}
