import Foundation

/// Installs the Remarc Codex plugin by shelling out to the scriptable
/// `codex plugin` CLI (all subcommands support --json and run
/// non-interactively). The app never edits ~/.codex/config.toml for MCP
/// registration anymore - Codex owns its own plugin state.
public enum CodexPluginInstaller {
    public static let marketplaceSlug = "metedata/remarc-agent-plugins"
    public static let marketplaceName = "remarc"
    public static let pluginId = "remarc@remarc"

    static let commandTimeoutSeconds: Double = 90

    public enum Outcome: Equatable, Sendable {
        case success
        case codexNotFound
        case failed(String)
    }

    public static var marketplaceArguments: [String] {
        ["plugin", "marketplace", "add", marketplaceSlug]
    }

    public static var installArguments: [String] {
        ["plugin", "add", pluginId]
    }

    /// Shown in Preferences and used as the failure-path advice. These must
    /// be NON-DESTRUCTIVE and must refresh the snapshot: `plugin add` on an
    /// installed plugin re-resolves and replaces the cache dir (verified
    /// live), so telling a user to remove first would risk leaving them with
    /// nothing if the re-add then fails. The upgrade line is what makes a
    /// stale snapshot recoverable at all.
    public static func manualCommands() -> String {
        """
        codex plugin marketplace add \(marketplaceSlug)
        codex plugin marketplace upgrade \(marketplaceName)
        codex plugin add \(pluginId)
        """
    }

    /// Pure decision core (unit-tested). Marketplace add is tolerated as a
    /// failure source only when install itself succeeded - same contract as
    /// PluginInstaller.outcome for Claude Code.
    public static func outcome(
        install: ProcessRunner.CommandResult?,
        marketplace: ProcessRunner.CommandResult?
    ) -> Outcome {
        guard let install else {
            return .failed("Could not run the codex CLI. Try the commands manually.")
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

    /// A pre-existing Codex marketplace named `remarc` pointing elsewhere
    /// must never satisfy the install (same hijack class the Claude Code
    /// installer guards against) - see `install()` for how the pre-add and
    /// post-add checks enforce this. Envelope verified live on codex-cli
    /// 0.146.1: {"marketplaces":[{"name":...,"root":...,
    /// "marketplaceSource":{"sourceType":"git"|"local","source":...}}]}.
    public enum MarketplaceProvenance: Equatable, Sendable {
        case ours
        case foreign(String)
        case absent
    }

    public static func marketplaceProvenance(listJSON: Data) -> MarketplaceProvenance {
        guard let root = (try? JSONSerialization.jsonObject(with: listJSON)) as? [String: Any],
              let entries = root["marketplaces"] as? [[String: Any]]
        else { return .absent }
        guard let remarc = entries.first(where: { ($0["name"] as? String) == marketplaceName }) else { return .absent }
        let sourceObj = remarc["marketplaceSource"] as? [String: Any]
        let sourceType = (sourceObj?["sourceType"] as? String) ?? ""
        let source = (sourceObj?["source"] as? String) ?? ""
        // Exact equality against the canonical forms - NEVER substring
        // matching, which /tmp/metedata/remarc-agent-plugins-evil would
        // satisfy. Require the git source type too; a local-source
        // marketplace is foreign even if its path echoes our slug.
        let canonical: Set<String> = [
            marketplaceSlug,
            "https://github.com/\(marketplaceSlug)",
            "https://github.com/\(marketplaceSlug).git",
        ]
        if sourceType == "git" && canonical.contains(source) { return .ours }
        let described = source.isEmpty ? ((remarc["root"] as? String) ?? "unknown source") : source
        return .foreign(String(described.prefix(120)))
    }

    /// Pure decision core (unit-tested) for the check that runs BEFORE
    /// `marketplace add`. Only `.foreign` blocks: a foreign marketplace must
    /// never reach the add, which would silently overwrite it. `.absent` is
    /// the normal first-run case (no marketplace yet) and `.ours` is already
    /// fine, so both fall through with a nil result.
    static func preAddOutcome(provenance: MarketplaceProvenance) -> Outcome? {
        guard case .foreign(let source) = provenance else { return nil }
        return .failed("A different Codex marketplace named \"\(marketplaceName)\" already exists (\(source)). Remove it with: codex plugin marketplace remove \(marketplaceName) - then try again.")
    }

    /// Pure decision core (unit-tested) for the check that runs AFTER
    /// `marketplace add` and `upgrade`. Only `.ours` may proceed to install:
    /// `.absent` here means the add itself silently failed, and `.foreign`
    /// means something replaced the marketplace between the two checks.
    static func postAddOutcome(provenance: MarketplaceProvenance) -> Outcome? {
        switch provenance {
        case .ours:
            return nil
        case .foreign(let source):
            return .failed("A different Codex marketplace named \"\(marketplaceName)\" already exists (\(source)). Remove it with: codex plugin marketplace remove \(marketplaceName) - then try again.")
        case .absent:
            return .failed("The \(marketplaceName) marketplace could not be added. Run the commands manually.")
        }
    }

    /// Order matters here: `codex plugin marketplace add` SILENTLY
    /// OVERWRITES an existing marketplace named `remarc` (verified live -
    /// exits 0, no warning). A provenance check that ran only after the add,
    /// as this used to, would therefore always see `.ours`, no matter what
    /// was there a moment before - the `.foreign` branch was unreachable
    /// except when the add itself failed outright. Provenance is now checked
    /// BEFORE the add (bailing on `.foreign`, continuing on `.absent`/`.ours`
    /// since first-run has no marketplace yet) and re-checked AFTER the add
    /// and upgrade, requiring `.ours` before install runs.
    public static func install() async -> Outcome {
        guard let codex = await ShellResolver.resolveBinaryPath("codex") else {
            return .codexNotFound
        }

        // JSON must come from stdout only - codex prints warnings to stderr.
        guard let preAddList = await ProcessRunner.runCollectingResult(
            codex, arguments: ["plugin", "marketplace", "list", "--json"],
            timeoutSeconds: commandTimeoutSeconds, mergeStderr: false
        ), preAddList.exitCode == 0, !preAddList.timedOut else {
            return .failed("Could not verify the plugin marketplace. Run the commands manually.")
        }
        if let bail = preAddOutcome(provenance: marketplaceProvenance(listJSON: Data(preAddList.output.utf8))) {
            return bail
        }

        let marketplace = await ProcessRunner.runCollectingResult(
            codex, arguments: marketplaceArguments, timeoutSeconds: commandTimeoutSeconds
        )

        // `marketplace add` on an existing marketplace does NOT refresh its
        // snapshot - upgrade explicitly so existing users never install from
        // a stale pre-semver state. Failure here is nonfatal (offline users
        // still install from their snapshot); the version gate below is what
        // makes staleness fail loudly instead of silently.
        _ = await ProcessRunner.runCollectingResult(
            codex, arguments: ["plugin", "marketplace", "upgrade", marketplaceName],
            timeoutSeconds: commandTimeoutSeconds
        )

        // Re-verify provenance now that the add and upgrade have run: this
        // is what actually proves the marketplace we are about to install
        // from is ours, since the pre-add check only ruled out a hijack
        // that existed before this call started.
        guard let postAddList = await ProcessRunner.runCollectingResult(
            codex, arguments: ["plugin", "marketplace", "list", "--json"],
            timeoutSeconds: commandTimeoutSeconds, mergeStderr: false
        ), postAddList.exitCode == 0, !postAddList.timedOut else {
            return .failed("Could not verify the plugin marketplace. Run the commands manually.")
        }
        if let bail = postAddOutcome(provenance: marketplaceProvenance(listJSON: Data(postAddList.output.utf8))) {
            return bail
        }

        let install = await ProcessRunner.runCollectingResult(
            codex, arguments: installArguments, timeoutSeconds: commandTimeoutSeconds
        )
        let cliOutcome = outcome(install: install, marketplace: marketplace)
        guard cliOutcome == .success else { return cliOutcome }

        // Exit-zero is not proof: require the detector to actually see the
        // plugin installed and enabled before reporting success.
        let state = await CodexPluginDetector().read()
        guard state.remarcInstalled && state.remarcEnabled else {
            return .failed("Install reported success but the plugin is not active. Run codex plugin list to inspect, or run the commands manually.")
        }
        // Version gate: this is what makes the upgrade step consequential.
        // A "local" version means the install came from a stale pre-semver
        // marketplace snapshot; Codex prefers a "local" version dir over
        // numeric ones, so leaving it in place would shadow every future
        // update. Fail loudly instead of reporting a poisoned success.
        //
        // Gate on a POSITIVE property (parses as semver), never on
        // `!= "local"`: remarcVersion is optional, so a missing version
        // field would sail through an inequality check and latch an
        // unverified install. Reviewers disagreed on whether nil is
        // reachable against today's CLI - it is closed here because the
        // cost is one line and the failure mode is destroying a working
        // legacy integration.
        guard let version = state.remarcVersion, Self.isNumericVersion(version) else {
            let reported = state.remarcVersion ?? "none"
            return .failed("Installed from a stale marketplace snapshot (version \"\(reported)\"). Run: codex plugin marketplace upgrade \(marketplaceName) && codex plugin add \(pluginId)")
        }
        return .success
    }

    /// Leading-numeric dotted version, e.g. "0.5.0" or "26.721.81911".
    /// Deliberately permissive about suffixes and strict about the shape:
    /// "local", "" and nil must all fail.
    static func isNumericVersion(_ version: String) -> Bool {
        let core = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
