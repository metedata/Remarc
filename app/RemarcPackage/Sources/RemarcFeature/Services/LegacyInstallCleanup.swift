import Foundation
import Darwin  // for flock

/// One-time cleanup of the legacy in-app install artifacts (skill file, hooks
/// merged into ~/.claude/settings.json, MCP server registered via
/// `claude mcp add-json`). Runs on every launch until both:
///   1. Cleanup steps verified, AND
///   2. The new `remarc` plugin is detected installed.
///
/// The retry-until-installed semantics intentionally handle the rollout race
/// where a user installs the plugin BEFORE upgrading the app — without this,
/// the old settings.json hooks would coexist with plugin hooks, causing
/// duplicate session creation and double context injection.
@MainActor
public final class LegacyInstallCleanup {
    public static let shared = LegacyInstallCleanup()

    private static let lockPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.remarc-migration.lock")

    public func runIfNeeded() async {
        if SettingsManager.shared.pluginMigrationCompleted {
            // The one-shot flag is not trustworthy on its own: a legacy build
            // run after completion (downgrade, stale copy) reinstalls the old
            // artifacts, and a claude session that was alive during cleanup
            // can flush the removed user-scope MCP entry back into
            // ~/.claude.json. These spawn-free local checks un-latch the flag
            // so the full pass runs again. (Observed for real: flag latched
            // 2026-05-18 during branch testing, artifacts reinstalled by the
            // then-still-legacy app for months afterward.)
            guard legacyArtifactsDetected() else { return }
            debugLog("LegacyInstallCleanup: legacy artifacts reappeared after completion — re-running")
            SettingsManager.shared.pluginMigrationCompleted = false
        }

        // Advisory lock handles "old app and new app both launched" race.
        // Non-blocking — if another instance holds the lock, we skip and try
        // again next launch.
        guard acquireLock() else {
            debugLog("LegacyInstallCleanup: another instance holds the lock — retry next launch")
            return
        }
        defer { releaseLock() }

        // Detect BEFORE destroying: a user who upgraded the app without
        // installing the plugin yet must keep the working legacy integration
        // until the plugin is actually installed and enabled. Only the
        // removal of duplicates once the plugin exists is our job.
        let pluginState = await PluginInstallDetector().read()
        guard pluginState.remarcInstalled && pluginState.remarcEnabled else {
            debugLog("LegacyInstallCleanup: plugin not installed+enabled yet — keeping legacy integration")
            return
        }

        let skillOK = removeOldSkillFile()
        let hooksOK = removeRemarcHooksFromAllEvents()
        let mcpOK   = await unregisterOldMCP()

        let isClean = skillOK && hooksOK && mcpOK && verifyClean()

        if isClean {
            SettingsManager.shared.pluginMigrationCompleted = true
            debugLog("LegacyInstallCleanup: complete, verified, plugin detected — flag set")
        } else {
            debugLog("LegacyInstallCleanup: not yet final (clean=\(isClean)) — will retry next launch")
        }
    }

    // MARK: - Cleanup steps

    private func removeOldSkillFile() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/remarc/SKILL.md")
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            debugLog("removeOldSkillFile failed: \(error)")
            return false
        }
    }

    private func removeRemarcHooksFromAllEvents() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return true }

        // Defensive read — bail out cleanly on JSONC / corrupt input rather than
        // overwriting whatever the user edited by hand.
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data),
              var settings = root as? [String: Any]
        else {
            debugLog("removeRemarcHooks: settings.json unparseable, leaving untouched")
            return false
        }

        guard var hooks = settings["hooks"] as? [String: Any] else { return true }
        var changed = false

        // Snapshot keys to avoid mutation-during-iteration. Track `changed`
        // per inner-hook removal — earlier versions only flagged changes when
        // an entry was fully dropped, missing the case where one Remarc inner
        // hook was removed but the entry kept others.
        for eventName in Array(hooks.keys) {
            guard let entries = hooks[eventName] as? [[String: Any]] else { continue }
            var newEntries: [[String: Any]] = []
            for entry in entries {
                guard var inner = entry["hooks"] as? [[String: Any]] else {
                    newEntries.append(entry)
                    continue
                }
                let originalInnerCount = inner.count
                inner.removeAll { isRemarcHook($0) }
                if inner.count != originalInnerCount { changed = true }
                if inner.isEmpty {
                    continue  // entry fully drained, drop it
                }
                var newEntry = entry
                newEntry["hooks"] = inner
                newEntries.append(newEntry)
            }
            if newEntries.isEmpty {
                hooks.removeValue(forKey: eventName)
                changed = true
            } else {
                hooks[eventName] = newEntries
            }
        }

        if !changed { return true }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") }
        else             { settings["hooks"] = hooks }

        // Atomic write with backup
        let backupURL = url.appendingPathExtension("remarc-bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: url, to: backupURL)
        do {
            let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: .atomic)
            try? FileManager.default.removeItem(at: backupURL)
            return true
        } catch {
            debugLog("removeRemarcHooks: write failed: \(error)")
            // An .atomic write that throws leaves the original file intact,
            // so never delete `url` here - doing so when the backup copy had
            // silently failed (e.g. full disk) would destroy settings.json
            // outright. Just drop the backup and retry next launch.
            try? FileManager.default.removeItem(at: backupURL)
            return false
        }
    }

    /// Match by stable markers: env var the old install always set, or path
    /// substring of the old install layout.
    nonisolated static func isRemarcHook(_ hook: [String: Any]) -> Bool {
        let command = (hook["command"] as? String) ?? ""
        // Old install always shelled with `REMARC_CLI_PATH=...` prefix
        if command.contains("REMARC_CLI_PATH=") { return true }
        // Old install referenced scripts/hooks/remarc-* in the command
        if command.contains("scripts/hooks/remarc-") { return true }
        // Also check args[] for exec-form hooks (future-proofing — old install
        // used shell form, but plugin spec allows both)
        if let args = hook["args"] as? [String] {
            return args.contains { $0.contains("scripts/hooks/remarc-") || $0.contains("remarc-cli") }
        }
        return false
    }

    /// Wrapper so removeRemarcHooksFromAllEvents() can call the nonisolated form.
    private func isRemarcHook(_ hook: [String: Any]) -> Bool {
        Self.isRemarcHook(hook)
    }

    private func unregisterOldMCP() async -> Bool {
        // Gate on ~/.claude.json directly instead of `claude mcp list`: list
        // health-checks every configured server and can exceed any sane
        // timeout when one is slow or the machine is offline, which would
        // permanently block cleanup. The config read is also what lets us
        // check provenance - only a registration pointing at Remarc's own
        // server layout is ours to delete; a user's custom server that merely
        // shares the name is left alone.
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: configURL) else {
            return true  // no config, nothing registered
        }
        guard Self.hasUserScopeRemarcMCP(claudeConfigJSON: data) else {
            return true  // nothing legacy to remove (absent, or not ours)
        }

        guard let claude = await ShellResolver.resolveBinaryPath("claude") else {
            debugLog("LegacyInstallCleanup: legacy MCP present but claude CLI not found — retry next launch")
            return false
        }

        // Legacy registration confirmed. Return the actual exit code of the
        // removal so silent failures don't get masked. `mcp remove` does not
        // health-check servers, so a short timeout is safe here.
        return await ProcessRunner.run(claude, arguments: ["mcp", "remove", "--scope", "user", "remarc"])
    }

    /// Re-read all three artifacts and confirm we're clean. Belt-and-suspenders
    /// against partial cleanups.
    private func verifyClean() -> Bool {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser

        let skillURL = homeURL.appendingPathComponent(".claude/skills/remarc/SKILL.md")
        if FileManager.default.fileExists(atPath: skillURL.path) { return false }

        let settingsURL = homeURL.appendingPathComponent(".claude/settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path),
           let data = try? Data(contentsOf: settingsURL),
           let s = String(data: data, encoding: .utf8),
           Self.settingsContainLegacyHookMarkers(s) {
            return false
        }
        return true
    }

    /// Spawn-free dirty check used once the completion flag is set. Reads the
    /// same three artifacts the cleanup targets, but without shelling out to
    /// the claude CLI (the user-scope MCP registration is read straight from
    /// ~/.claude.json instead of `claude mcp list`).
    private func legacyArtifactsDetected() -> Bool {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser

        let skillURL = homeURL.appendingPathComponent(".claude/skills/remarc/SKILL.md")
        if FileManager.default.fileExists(atPath: skillURL.path) { return true }

        let settingsURL = homeURL.appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let s = String(data: data, encoding: .utf8),
           Self.settingsContainLegacyHookMarkers(s) {
            return true
        }

        let configURL = homeURL.appendingPathComponent(".claude.json")
        if let data = try? Data(contentsOf: configURL),
           Self.hasUserScopeRemarcMCP(claudeConfigJSON: data) {
            return true
        }
        return false
    }

    /// A top-level `mcpServers.remarc` entry in ~/.claude.json counts as the
    /// legacy registration only when its provenance matches what Remarc's own
    /// installers ever wrote: node invoking a `.../mcp/dist/index.js` script.
    /// A user's unrelated server that merely shares the name is not ours to
    /// delete. (Plugin-provided servers come from the plugin manifest and
    /// project-scope registrations live under `projects.<path>.mcpServers`,
    /// so neither appears here.) Malformed input reports false - if
    /// ~/.claude.json is unreadable, claude itself is broken and there is
    /// nothing useful to un-latch for.
    nonisolated static func hasUserScopeRemarcMCP(claudeConfigJSON: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: claudeConfigJSON)) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let remarc = servers["remarc"] as? [String: Any]
        else { return false }
        return legacyMCPSignatureMatches(remarc)
    }

    /// Provenance signature shared by every registration the app ever wrote
    /// (dev layout `.../Remarc/mcp/dist/index.js` and the bundled stable
    /// path both end the same way).
    nonisolated static func legacyMCPSignatureMatches(_ server: [String: Any]) -> Bool {
        var haystack = [(server["command"] as? String) ?? ""]
        haystack.append(contentsOf: (server["args"] as? [String]) ?? [])
        return haystack.contains { $0.hasSuffix("mcp/dist/index.js") }
    }

    /// Marker scan shared by verifyClean() and the post-completion recheck.
    /// Matches only the legacy install's stable markers, never the plugin's
    /// entries (those use ${CLAUDE_PLUGIN_ROOT} paths and plugin ids).
    /// `REMARC_CLI_PATH=` keeps the equals sign so this stays exactly as
    /// broad as `isRemarcHook` - a wider scan would un-latch on content the
    /// hook cleanup cannot remove (e.g. an unrelated `env` setting), looping
    /// forever.
    nonisolated static func settingsContainLegacyHookMarkers(_ contents: String) -> Bool {
        contents.contains("REMARC_CLI_PATH=") || contents.contains("scripts/hooks/remarc-")
    }

    // MARK: - Advisory lock

    private var lockFD: Int32?

    private func acquireLock() -> Bool {
        let path = Self.lockPath.path
        try? FileManager.default.createDirectory(at: Self.lockPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }

    private func releaseLock() {
        if let fd = lockFD {
            flock(fd, LOCK_UN)
            close(fd)
            lockFD = nil
        }
        try? FileManager.default.removeItem(at: Self.lockPath)
    }
}
