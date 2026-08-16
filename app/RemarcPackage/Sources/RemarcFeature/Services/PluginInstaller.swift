import Foundation

/// Installs the Remarc Claude Code plugins by shelling out to the documented
/// `claude plugin` CLI, which runs non-interactively when invoked from a
/// script. The app never writes into `~/.claude/` itself - Claude Code owns
/// its own plugin registry, config, and update lifecycle.
public enum PluginInstaller {
    public static let marketplaceSlug = "metedata/remarc-agent-plugins"
    public static let marketplaceName = "remarc"

    /// Marketplace add clones a git repo; install copies from the local clone.
    /// Both get a generous timeout because the first depends on the network.
    static let commandTimeoutSeconds: Double = 90

    public enum Outcome: Equatable, Sendable {
        case success
        case claudeNotFound
        case failed(String)
    }

    public static var marketplaceArguments: [String] {
        ["plugin", "marketplace", "add", marketplaceSlug]
    }

    public static func installArguments(plugin: String) -> [String] {
        ["plugin", "install", "\(plugin)@\(marketplaceName)"]
    }

    /// The exact commands the Install button runs, in copy-pasteable shell
    /// form. Shown next to the button and used by the copy fallback.
    public static func manualCommands(plugin: String) -> String {
        """
        claude plugin marketplace add \(marketplaceSlug)
        claude plugin install \(plugin)@\(marketplaceName)
        """
    }

    /// The command that updates an installed plugin to the marketplace's latest.
    /// Copy-only in the UI: the app never runs plugin lifecycle commands for
    /// Claude Code, which owns its own registry and update lifecycle.
    public static func updateCommand(plugin: String) -> String {
        "claude plugin update \(plugin)@\(marketplaceName)"
    }

    /// True when `version` is a dotted numeric string (e.g. "0.13.0"), not a
    /// placeholder like "local" or an empty value. Only numeric versions can be
    /// ordered, so the update nudge is suppressed for anything else.
    public static func isNumericVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return !version.isEmpty && parts.allSatisfy { Int($0) != nil }
    }

    /// Order two dotted numeric versions: -1 if lhs < rhs, 0 if equal, 1 if
    /// lhs > rhs. Missing trailing components count as 0, so "0.13" == "0.13.0".
    public static func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<Swift.max(l.count, r.count) {
            let a = index < l.count ? l[index] : 0
            let b = index < r.count ? r[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    /// Whether an installed plugin at `installedVersion` is older than the
    /// version this app vendored (`bundledVersion`). False when either version
    /// is missing or non-numeric, so a "local"/dev install never nags.
    public static func updateAvailable(installedVersion: String?, bundledVersion: String) -> Bool {
        guard let installedVersion,
              isNumericVersion(installedVersion),
              isNumericVersion(bundledVersion) else { return false }
        return compareVersions(installedVersion, bundledVersion) < 0
    }

    /// Pure decision core (unit-tested). `marketplace add` legitimately fails
    /// when the marketplace is already registered, so only the `plugin install`
    /// result decides the outcome. When install also failed with no output of
    /// its own, the marketplace output usually names the shared cause (e.g. no
    /// network while cloning), so it becomes the fallback message.
    public static func outcome(
        install: ProcessRunner.CommandResult?,
        marketplace: ProcessRunner.CommandResult?
    ) -> Outcome {
        guard let install else {
            return .failed("Could not run the claude CLI. Try the commands manually.")
        }
        // Timeout wins over exit code: a terminated process that traps the
        // signal and exits 0 must not read as a completed install.
        if install.timedOut {
            return .failed("Timed out. Check your network and try again, or run the commands manually.")
        }
        if install.exitCode == 0 { return .success }

        var message = install.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty, let marketplace, marketplace.exitCode != 0 {
            message = marketplace.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if message.isEmpty {
            message = "Install failed. Run the commands manually."
        }
        return .failed(String(message.prefix(300)))
    }

    /// Whether the marketplace named `remarc` on this machine is actually
    /// ours. `marketplace add` fails softly when a marketplace with the same
    /// name already exists, so without this check the follow-up
    /// `plugin install remarc@remarc` would install from whatever repo that
    /// pre-existing marketplace points at.
    public enum MarketplaceProvenance: Equatable, Sendable {
        case ours
        case foreign(String)
        case absent
    }

    /// Pure parse core (unit-tested) for `claude plugin marketplace list --json`:
    /// an array of { "name", "source", "repo", "installLocation" }.
    public static func marketplaceProvenance(listJSON: Data) -> MarketplaceProvenance {
        guard let entries = (try? JSONSerialization.jsonObject(with: listJSON)) as? [[String: Any]] else {
            return .absent
        }
        guard let remarc = entries.first(where: { ($0["name"] as? String) == marketplaceName }) else {
            return .absent
        }
        if (remarc["repo"] as? String) == marketplaceSlug { return .ours }
        let described = (remarc["repo"] as? String)
            ?? (remarc["installLocation"] as? String)
            ?? (remarc["source"] as? String)
            ?? "unknown source"
        return .foreign(described)
    }

    public static func install(plugin: String) async -> Outcome {
        guard let claude = await ShellResolver.resolveBinaryPath("claude") else {
            return .claudeNotFound
        }
        let marketplace = await ProcessRunner.runCollectingResult(
            claude,
            arguments: marketplaceArguments,
            timeoutSeconds: commandTimeoutSeconds
        )

        // Fail closed if we cannot prove the `remarc` marketplace points at
        // our repo - installing from a look-alike marketplace would execute
        // someone else's code.
        guard let listOutput = await ProcessRunner.runCollectingResult(
            claude,
            arguments: ["plugin", "marketplace", "list", "--json"],
            timeoutSeconds: commandTimeoutSeconds,
            mergeStderr: false
        ), listOutput.exitCode == 0, !listOutput.timedOut else {
            return .failed("Could not verify the plugin marketplace. Run the commands manually.")
        }
        switch marketplaceProvenance(listJSON: Data(listOutput.output.utf8)) {
        case .ours:
            break
        case .foreign(let source):
            return .failed("A different plugin marketplace named \"remarc\" already exists (\(String(source.prefix(120)))). Remove it with: claude plugin marketplace remove remarc - then try again.")
        case .absent:
            return .failed("The remarc marketplace could not be added. Run the commands manually.")
        }

        let install = await ProcessRunner.runCollectingResult(
            claude,
            arguments: installArguments(plugin: plugin),
            timeoutSeconds: commandTimeoutSeconds
        )
        return outcome(install: install, marketplace: marketplace)
    }
}
