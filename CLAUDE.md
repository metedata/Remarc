# Remarc

macOS menu bar app (SwiftUI + AppKit) for contextual commenting on text selections.

- Bundle ID: `com.metepolat.Remarc`
- Min macOS: 14.0 (`MACOSX_DEPLOYMENT_TARGET` in `app/Config/Shared.xcconfig` is the source of truth), Swift 6.0+, LSUIElement (no dock icon)
- Debug log: `/tmp/remarc_debug.log`
- Data: `~/Library/Application Support/Remarc/comments.json` (legacy fallback: `data.json`)

## Agent integrations

Three harnesses, two different delivery models. Do not assume they work the same way.

**Claude Code and Codex: plugin-based.** Both install from the marketplace at https://github.com/metedata/remarc-agent-plugins, which is not built into the app. Two plugins:

- `remarc@remarc` - required. MCP server + skill.
- `remarc-hooks@remarc` - optional, experimental. Session-lifecycle hooks (off by default; user must `/plugin install remarc-hooks@remarc` explicitly).

**Cursor: still fully app-managed.** The app writes `~/.cursor/mcp.json` and `~/.cursor/skills/remarc/SKILL.md` via `HarnessIntegrationManager` / `CursorMCPInstaller` / `SkillInstaller`, driven by the Enable toggle in Preferences. Cursor's repo marketplaces are Teams/Enterprise-only, so there is no plugin path for individual users. Deliberately deferred, not overlooked - see `docs/superpowers/plans/2026-08-06-codex-cursor-plugin-migration.md`.

### Per-harness plugin manifests (important)

The plugin repo ships THREE manifests over one shared payload, because the harnesses disagree about paths:

- `.claude-plugin/plugin.json` + root `.mcp.json` using `${CLAUDE_PLUGIN_ROOT}`. Claude Code substitutes it.
- `.codex-plugin/plugin.json` -> `codex-mcp.json` using `"args": ["mcp/dist/index.js"], "cwd": "."`. **Codex does NOT substitute `${CLAUDE_PLUGIN_ROOT}`** (nor `${PLUGIN_ROOT}` / `${CODEX_PLUGIN_ROOT}`) in plugin MCP args, and sets no plugin-root env var - it passes the literal string through, so the server never starts. A relative `cwd`, resolved against the installed plugin root, is the documented replacement (openai/codex#19582, discussion #28145). Codex prefers `.codex-plugin` over `.claude-plugin` when both exist, which is what keeps Claude Code unaffected.
- `.cursor-plugin/plugin.json` - groundwork for a future Cursor Marketplace listing only. No app code consumes it.

Verifying a harness "has" the plugin is not the same as verifying it works: `plugin list` and `mcp list` report metadata even when the server fails to spawn. The only real check is running a tool, e.g. `echo "" | codex exec --skip-git-repo-check "call mcp__remarc__remarc_list_sessions"`.

### Cleanup latches

Only Claude Code has one. `LegacyInstallCleanup` runs at startup until both:
1. The old `~/.claude/skills/remarc/SKILL.md`, settings.json hooks, and user-scoped `claude mcp add-json` registration are removed, AND
2. The new `remarc` plugin is detected installed (via `claude plugin list --json`).

It retries every launch until both hold, then sets `defaults` key `pluginMigrationCompleted=1`. Even after the flag is set, each launch runs cheap spawn-free artifact checks and un-latches if a legacy build or a live claude session restored anything. It holds an advisory `flock` while doing destructive work.

**Codex is install-only: there is no cleanup, no latch, no durable flag, and it deletes nothing.** The app simply stopped writing `[mcp_servers.remarc]` into `~/.codex/config.toml`. Anyone carrying that table from an older build removes it by hand. This was a deliberate scope decision made because there were no existing Codex users to migrate, and because every serious defect across four review rounds lived in migration machinery rather than in installing.

Both detectors (`PluginInstallDetector`, `CodexPluginDetector`) must use `ProcessRunner.runCollectingResult(..., mergeStderr: false)` and reject timeout and nonzero exit. Never `runCapture` here: it sends SIGTERM without escalating to SIGKILL, so a trapping CLI hangs the Preferences row on "Checking" for the life of the window.

### Repo ownership

**The plugin repo owns the MCP server outright.** There is one implementation, at `plugins/remarc/mcp/`. The app repo no longer has a copy - it vendors the built artifact:

- `mcp/vendor/remarc-mcp.js` - built output, committed
- `mcp/vendor/PROVENANCE.json` - source commit, plugin version, sha256
- Refresh with `scripts/sync-mcp-vendor.sh`, which refuses to vendor from a dirty plugin checkout

The Xcode phase verifies the recorded sha256 before copying and fails the build on a mismatch, so a hand-edited vendor cannot ship. It also no longer builds anything: the artifact is committed, so a clean checkout builds the same bytes as this machine.

Why: the server was written twice and synced by hand, which never happened. The app shipped a build with none of the document transaction, unknown-field passthrough, or status compare-and-set for months, and the harness-origin fix had to be written in three places. Editing twice was the bug; distributing twice is fine.

The plugin repo also owns hook orchestration (`remarc-hooks`) and `plugins/remarc/mcp/src/data.ts` is a symlink to `plugins/shared/data.ts`. SKILL.md still lives here at `mcp/skill/` and is synced outward.

The app's `remarc-cli.js` and `scripts/hooks/*.sh` are gone, along with `ClaudeCodeManager`, which was dead code that installed the very `settings.json` hooks `LegacyInstallCleanup` deletes.

The app-to-plugin contract is documented at `plugins/shared/contracts.md` in the plugin repo. Schema-breaking changes to `comments.json` require coordinated app + plugin releases.

## Build & Relaunch

Build: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"`

**MANDATORY: After every successful build, relaunch Remarc.** The user cannot verify changes otherwise.
`pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`

Always use `"$(pwd)/DerivedData"` (command substitution), never `"$PWD/DerivedData"` — `$PWD` resolves incorrectly in subshells and worktree contexts.

## Git Worktrees — MANDATORY

**All code changes MUST be made in a git worktree, not on main.** Only exceptions: root config files (CLAUDE.md, scripts/, .claude/).

Worktrees go in `.worktrees/` (gitignored). Use `git worktree add .worktrees/<name> -b <branch>`.

## UI Work

When the user describes a UI bug, confirm WHICH specific component/view they mean before editing. Ask clarifying questions if ambiguous.

## Microphone / TCC Permissions

Building from worktrees (or nuking DerivedData) fragments macOS TCC mic permissions. Audio tap silently produces 0 buffers. **Fix:**

```bash
rm -rf app/DerivedData
# rebuild...
tccutil reset Microphone com.metepolat.Remarc
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

User must grant mic access when prompted. Do this whenever audio capture stops working.

## Color System

Colors/gradients defined in `Views/Colors.swift`. Use `remarc*` tokens (`remarcPrimary`, `remarcSecondary`, `remarcAccent`, etc.) — never hardcode hex values. All tokens take `colorScheme` for light/dark adaptation.

## Copy Style

Never use em dashes (—) in **user-facing text** - UI strings, marketing copy, release notes, anything a user reads. Use hyphens (-) instead.

This rule does NOT extend to developer-facing writing: code comments, these docs, plan and spec files, and commit messages may use em dashes freely.

## Research

When brainstorming or planning, **always do online research** (WebSearch, WebFetch) and **check Context7 docs** for Apple frameworks before proposing approaches. Don't rely on training data alone.
