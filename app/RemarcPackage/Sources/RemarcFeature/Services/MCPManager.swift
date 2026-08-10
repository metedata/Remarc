import Foundation

/// Reports whether Claude Code can reach the Remarc MCP server (marketplace
/// plugin first, legacy user-scoped registration as fallback) and manages
/// that legacy registration.
@MainActor
public final class MCPManager: ObservableObject {
    public static let shared = MCPManager()

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var nodeStatus: DependencyStatus = .unchecked
    @Published public private(set) var claudeStatus: DependencyStatus = .unchecked

    public enum DependencyStatus: Equatable {
        case unchecked
        case found(path: String)
        case notFound
    }

    public var hasDependencyError: Bool {
        nodeStatus == .notFound || claudeStatus == .notFound
    }

    /// The resolved node binary path, if found.
    public var resolvedNodePath: String? { nodePath }

    /// The resolved MCP server script path, if found.
    public private(set) var resolvedMCPPath: String?

    private var nodePath: String?
    private var claudePath: String?

    private init() {}

    // MARK: - Dependency Detection

    public func checkDependencies() {
        Task {
            await refreshDependencies()

            // Report availability; never create it.
            //
            // This used to auto-register on any launch that found no entry,
            // via `claude mcp add-json --scope user`. That is precisely the
            // registration `LegacyInstallCleanup` exists to remove, and
            // `checkDependencies()` runs from `.onAppear` - so cleanup deleted
            // it at launch and merely opening Preferences put it back, pointing
            // at the app's own server alongside the marketplace plugin's. Two
            // servers named `remarc`, one of them stale, and the user chose
            // neither. Claude Code installs the plugin now; the app has no
            // business writing into its config uninvited.
            //
            // Since the migration that plugin registers as
            // `plugin:remarc:remarc`, a name `claude mcp get remarc` cannot
            // see, which left this check permanently reporting "not
            // connected". Ask the plugin first; probe the legacy user-scoped
            // registration only when the plugin does not answer (and only
            // with node present, since the legacy server cannot run without
            // it).
            guard claudePath != nil else { return }

            let plugin = await PluginInstallDetector().read()
            let pluginActive = plugin.remarcInstalled && plugin.remarcEnabled
            let legacy = (!pluginActive && nodePath != nil) ? await checkMCPRegistered() : false
            self.isEnabled = Self.resolveEnabled(pluginState: plugin, legacyRegistered: legacy)
            debugLog("MCPManager: status pluginInstalled=\(plugin.remarcInstalled) pluginEnabled=\(plugin.remarcEnabled) legacyRegistered=\(legacy) -> isEnabled=\(self.isEnabled)")
        }
    }

    public func refreshDependencies() async {
        async let node = ShellResolver.resolveBinaryPath("node")
        async let claude = ShellResolver.resolveBinaryPath("claude")
        let (nodePath, claudePath) = await (node, claude)

        self.nodePath = nodePath
        self.claudePath = claudePath
        self.nodeStatus = nodePath != nil ? .found(path: nodePath!) : .notFound
        self.claudeStatus = claudePath != nil ? .found(path: claudePath!) : .notFound
        self.resolvedMCPPath = self.stableMCPServerPath()
    }

    /// Public for testing. Pure decision behind the status dot: the server is
    /// reachable when the marketplace plugin is installed and enabled, or when
    /// the legacy user-scoped registration still exists.
    nonisolated public static func resolveEnabled(
        pluginState: PluginInstallState,
        legacyRegistered: Bool
    ) -> Bool {
        (pluginState.remarcInstalled && pluginState.remarcEnabled) || legacyRegistered
    }

    // MARK: - Enable / Disable

    public func enable() async -> Bool {
        if nodePath == nil || claudePath == nil {
            await refreshDependencies()
        }

        guard let nodePath, let claudePath else { return false }

        guard let mcpPath = resolvedMCPPath ?? stableMCPServerPath() else {
            debugLog("MCPManager: Could not resolve stable MCP server path")
            return false
        }
        self.resolvedMCPPath = mcpPath

        let config = #"{"command":"\#(nodePath)","args":["\#(mcpPath)"]}"#

        let success = await runProcess(
            claudePath,
            arguments: ["mcp", "add-json", "--scope", "user", "remarc", config]
        )

        if success {
            isEnabled = true
            SettingsManager.shared.mcpUserDisabled = false
            debugLog("MCPManager: MCP server registered with Claude Code")
        } else {
            debugLog("MCPManager: Failed to register MCP server")
        }
        return success
    }

    public func disable() async -> Bool {
        guard let claudePath else { return false }

        let success = await runProcess(
            claudePath,
            arguments: ["mcp", "remove", "--scope", "user", "remarc"]
        )

        if success {
            isEnabled = false
            SettingsManager.shared.mcpUserDisabled = true
            debugLog("MCPManager: MCP server unregistered from Claude Code")
        } else {
            debugLog("MCPManager: Failed to unregister MCP server")
        }
        return success
    }

    // MARK: - Private Helpers

    private func stableMCPServerPath() -> String? {
        let path = ScriptInstaller.resolvedPath(source: "mcp/vendor/remarc-mcp.js", bundleName: "remarc-mcp", bundleExt: "js")
        if let path { debugLog("MCPManager: Resolved MCP path: \(path)") }
        return path
    }

    private func checkMCPRegistered() async -> Bool {
        guard let claudePath else { return false }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = ["mcp", "get", "remarc"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    @discardableResult
    private func runProcess(_ path: String, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
