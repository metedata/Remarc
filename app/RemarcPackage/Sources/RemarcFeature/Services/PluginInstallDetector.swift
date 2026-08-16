import Foundation

/// State of the two Remarc Claude Code plugins.
public struct PluginInstallState: Equatable, Sendable {
    public let remarcInstalled: Bool
    public let remarcEnabled: Bool
    public let remarcHooksInstalled: Bool
    public let remarcHooksEnabled: Bool
    /// The installed `remarc` plugin's version string (e.g. "0.13.0"), or nil
    /// when not installed or the CLI omitted it. Compared against the version
    /// this app vendored to tell whether an update is available.
    public let remarcVersion: String?

    public init(
        remarcInstalled: Bool,
        remarcEnabled: Bool,
        remarcHooksInstalled: Bool,
        remarcHooksEnabled: Bool,
        remarcVersion: String? = nil
    ) {
        self.remarcInstalled = remarcInstalled
        self.remarcEnabled = remarcEnabled
        self.remarcHooksInstalled = remarcHooksInstalled
        self.remarcHooksEnabled = remarcHooksEnabled
        self.remarcVersion = remarcVersion
    }

    public static let zero = PluginInstallState(
        remarcInstalled: false,
        remarcEnabled: false,
        remarcHooksInstalled: false,
        remarcHooksEnabled: false
    )
}

/// Reads installed plugins via `claude plugin list --json` (documented CLI
/// surface, not the internal `installed_plugins.json` file).
///
/// The actual JSON output uses an `id` field of the form `<plugin>@<marketplace>`
/// - verified against live CLI output. Each entry also carries `version`,
/// `scope`, `enabled`, `installPath`, `installedAt`, `lastUpdated`, plus
/// `mcpServers` and `errors` for plugins that have them.
public final class PluginInstallDetector: Sendable {
    public init() {}

    /// Public for testing.
    public static func parse(jsonOutput: Data) throws -> PluginInstallState {
        guard let array = (try? JSONSerialization.jsonObject(with: jsonOutput)) as? [[String: Any]] else {
            return .zero
        }
        let remarc      = array.first { ($0["id"] as? String) == "remarc@remarc" }
        let remarcHooks = array.first { ($0["id"] as? String) == "remarc-hooks@remarc" }
        return PluginInstallState(
            remarcInstalled:      remarc != nil,
            remarcEnabled:        (remarc?["enabled"] as? Bool) ?? false,
            remarcHooksInstalled: remarcHooks != nil,
            remarcHooksEnabled:   (remarcHooks?["enabled"] as? Bool) ?? false,
            remarcVersion:        remarc?["version"] as? String
        )
    }

    public func read() async -> PluginInstallState {
        guard let claude = await ShellResolver.resolveBinaryPath("claude") else { return .zero }
        // Anything short of a clean, timely, zero-exit run means "unknown /
        // not detected". Callers gate destructive actions on positive
        // detection, so reporting all-false is the safe direction.
        //
        // runCollectingResult, NOT runCapture: runCapture sends SIGTERM on
        // timeout and never escalates to SIGKILL, so a claude process that
        // traps or ignores it hangs this call forever. That matters because
        // this runs on the Preferences .task, where a hang leaves the row
        // stuck on "Checking" for the life of the window. mergeStderr:
        // false keeps the JSON free of anything claude writes to stderr,
        // matching runCapture's old stdout-only behavior.
        guard let result = await ProcessRunner.runCollectingResult(
            claude, arguments: ["plugin", "list", "--json"],
            timeoutSeconds: 5, mergeStderr: false
        ), !result.timedOut, result.exitCode == 0 else { return .zero }
        let data = Data(result.output.utf8)
        guard !data.isEmpty else { return .zero }
        return (try? Self.parse(jsonOutput: data)) ?? .zero
    }
}
