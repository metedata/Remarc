# Codex Plugin Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The "project merge skill" referenced throughout is `.claude/skills/merge/SKILL.md` in this repo (invoked as /merge).

> # ✅ UNBLOCKED (2026-08-06) - the fix is verified end to end
>
> This plan was blocked for several hours because installing the plugin gave Codex a loaded skill and zero tools. The cause is real and is recorded below, because the plan's `.mcp.json` still has to change. **The fix is now proven on this machine with `.claude-plugin` left completely untouched**, so the shipped Claude Code integration cannot regress. See "The verified fix" after the diagnosis. Phase A gains one task (Task 1 now also ships a Codex manifest); Tasks 3, 4 and 6 are unaffected.
>
> ## The diagnosis
>
> **Installing the Remarc plugin in Codex does NOT, as the repo stands today, give Codex the Remarc MCP tools.** Verified end to end on codex-cli 0.146.1, not inferred:
>
> - The plugin installs and reports `enabled`; `codex mcp list` shows the `remarc` server as `enabled`; the MCP dist is present on disk and runs correctly when launched by hand (`Remarc MCP server running on stdio`).
> - But a real Codex session has **zero** remarc tools. Asked to list tools matching "remarc", it answers `NONE`.
> - Root cause: the plugin's `.mcp.json` uses `"args": ["${CLAUDE_PLUGIN_ROOT}/mcp/dist/index.js"]`. **Codex passes that string through literally.** `codex mcp get remarc` shows the unsubstituted value, and no such path exists, so node exits and the server never starts.
> - Confirmed by isolation: patching the installed cache copy to an absolute path makes all seven tools appear as `mcp__remarc__remarc_*`. Reverting to the variable makes them vanish again.
> - `${PLUGIN_ROOT}` and `${CODEX_PLUGIN_ROOT}` were also tested. Neither resolves. An env-dump probe in the spawned server confirms Codex sets **no** plugin-root environment variable at all.
> - The plugin's **skill does load** in Codex (confirmed: it reports the remarc skill and its description). So installing the plugin today gives Codex a skill that instructs it to call `remarc_*` tools which do not exist - arguably worse than not installing it.
>
> This invalidates the Global Constraints line claiming Codex "injects `CLAUDE_PLUGIN_ROOT` alongside `PLUGIN_ROOT` for hook/MCP compat". That may hold for hooks; it is demonstrably false for plugin MCP servers. Claude Code is unaffected - it does perform the substitution, which is why the shipped 0.5.x integration works.
>
> ## The verified fix
>
> **This is a known upstream issue with a documented, supported fix - and the fix is verified working.**
>
> Not a novel discovery: [openai/codex#19582](https://github.com/openai/codex/issues/19582) reports exactly this (`${CLAUDE_PLUGIN_ROOT}` passed through literally, breaking a plugin's MCP server), [#19372](https://github.com/openai/codex/issues/19372) covers Codex mirroring Claude Code marketplaces and failing the handshake for Claude-only plugins, [#22842](https://github.com/openai/codex/issues/22842) asks for plugin-root-relative paths, and [discussion #28145](https://github.com/openai/codex/discussions/28145) answers the question directly: Codex exposes no `CLAUDE_PLUGIN_ROOT` equivalent, and **a relative `cwd` is the native replacement** - Codex resolves it against the installed plugin root, and `args` are then resolved relative to it. `PLUGIN_ROOT` and `PLUGIN_DATA` are given to plugin HOOKS, not to MCP servers, which is consistent with the env-dump probe finding no plugin variables in the spawned server.
>
> **Verified working on this machine** (legacy table removed to isolate, plugin installed, cached `.mcp.json` replaced with the form below, then restored): all seven `mcp__remarc__remarc_*` tools appeared.
>
> ```json
> { "mcpServers": { "remarc": { "command": "node", "args": ["mcp/dist/index.js"], "cwd": "." } } }
> ```
>
> **Codex prefers its own manifest, so Claude Code never has to change. VERIFIED, not assumed.** The owed test was run: a `.codex-plugin/plugin.json` was added to the marketplace snapshot alongside the untouched `.claude-plugin/plugin.json`, pointing at its own `codex-mcp.json` with the relative-`cwd` form. Results:
>
> - `codex plugin add` reported `version: 0.5.0` - a value present ONLY in the `.codex-plugin` manifest, proving Codex read that one in preference to `.claude-plugin`.
> - `codex mcp get remarc` showed `args: ["mcp/dist/index.js"]` with `cwd` resolved to the absolute installed root, `~/.codex/plugins/cache/remarc/remarc/0.5.0/.` - so Codex used `codex-mcp.json`, and it does resolve a relative `cwd` against the plugin root exactly as documented.
> - A real Codex session listed all seven `mcp__remarc__remarc_*` tools.
> - Throughout, `.claude-plugin/plugin.json` and the root `.mcp.json` (still `${CLAUDE_PLUGIN_ROOT}`) were untouched.
>
> That is the design: **per-harness manifests, one shared payload.** `.claude-plugin` keeps `${CLAUDE_PLUGIN_ROOT}` and the shipped Claude Code path is not modified at all; `.codex-plugin` carries the relative-`cwd` config; `.cursor-plugin` (Task 2) is the same pattern for a future Cursor listing. Per OpenAI's plugin docs, only the manifest belongs in `.codex-plugin/` - `skills/`, `hooks/` and the mcp config files stay at the plugin root, and all three manifests share the single `mcp/dist/index.js` and `skills/remarc/SKILL.md` payload. Task 1 below now ships this.
>
> Publishing the server to npm and launching via `npx` also works and needs no path resolution anywhere, but it is a heavier change (a package to publish and version) and is not the recommendation now that a supported in-repo mechanism is confirmed working.
>
> Tasks 3, 4 and 6 below remain sound - they are about detecting and installing the plugin, which is unaffected by how its server is launched.
>
> Everything below this banner is unchanged and still accurate about the install mechanics. Do not execute it until the launch problem above is resolved.
>
> **Revision 6 (2026-08-06) - THERE ARE NO EXISTING USERS TO MIGRATE. This is an install plan, not a migration plan.** The product owner confirmed the pre-existing Codex user base can be treated as empty, which removes the entire reason the hardest parts of this plan existed. Deleted outright: Task 5 (`LegacyCodexInstallCleanup`, 454 lines) and Task 7 (its launch wiring). Gone with them: the completion latch and its un-latch detection, `ShippedSkillOwnership` and its historical hash set, the stale-install migration and its attempt ceiling, the advisory `flock` lock, and two `defaults` keys. The app simply stops writing the legacy `[mcp_servers.remarc]` table and never removes one.
>
> This matters because of where the defects were. Across four adversarial review rounds on two independent engines, essentially every blocking finding lived in cleanup and retirement machinery, not in installing the plugin: both "user ends up with neither integration" criticals, the crash windows, the lock identity race, the completion-latch race, the retry ceiling with no recovery path, and the skill-ownership compile error. All of it existed only to make an unattended launch-time migration survive crashes, races and downgrades. With no users, none of it is needed, and the remaining plan is the part that never failed review.
>
> Earlier revision notes, kept for provenance: **Revision 4** cut Cursor from the plan (Tasks 8-10 deleted; see "Why Cursor was cut"). **Revision 5** deferred the code-retirement task. Task numbering is deliberately NOT compacted, so surviving cross-references stay valid.

**Goal:** Give Codex users a first-class plugin install for Remarc, mirroring the shipped Claude Code experience: a one-click Preferences panel backed by the `metedata/remarc-agent-plugins` marketplace, and stop the app from hand-writing `~/.codex/config.toml`.

**Architecture:** Codex natively reads the existing Claude Code plugin repo (verified empirically on 2026-08-06: `codex plugin marketplace add metedata/remarc-agent-plugins` + `codex plugin add remarc@remarc` installs with zero repo changes), so the Codex side is just a detector plus an installer plus a Preferences panel, mirroring `PluginInstallDetector`/`PluginInstaller` and the shipped Claude Code section. There is no cleanup component and nothing runs at launch. The plugin repo also gains a `.cursor-plugin` manifest (Task 2), but purely so a future official Cursor Marketplace listing has something to publish - no app code consumes it.

**Scope boundary (revision 6):** this plan never deletes anything from a user's machine. It does not remove the legacy `[mcp_servers.remarc]` table, the legacy Codex skill file, or any Cursor artifact. The only behavioral subtraction is that `HarnessIntegrationManager` stops writing the Codex table on future launches (Task 6 Step 3). Anyone whose machine already has a legacy table - realistically just the developer - removes it by hand once; see the Final verification checklist.

**Tech Stack:** Swift 6 (RemarcFeature package), existing utilities `ProcessRunner.runCollectingResult` (the only ProcessRunner entry point this plan uses; `run` and `runCapture` remain in the package for the Claude Code paths) and `ShellResolver`. Note the test target uses BOTH frameworks: `MCPInstallerTests.swift` is swift-testing (`import Testing`, `@Suite`, `@Test`), while `LegacyInstallCleanupTests.swift` and `PluginInstallerTests.swift` are XCTest. New test files below are XCTest; do not add XCTest methods to the swift-testing suites.

## Why Cursor was cut

Decided 2026-08-06 after the third adversarial review round, on this evidence:

- **Risk concentration.** Of the fourteen findings in Codex round 3, roughly eight were Cursor-specific, including two of four criticals and five of eight highs. Both "user ends up with neither the plugin nor the legacy integration" data-loss paths involved the Cursor bundle.
- **Structural cause.** Claude Code and Codex each ship a CLI that owns its own plugin state, so the app shells out and detects. Cursor's repo marketplaces are Teams/Enterprise-only, so for individual users the app would have to become a package manager: write five files, refresh them on every app update, detect partial states, survive a crash mid-write, prompt for a reload, and clean up after itself. That machinery is what produced the criticals, and it existed for exactly one of the three harnesses.
- **No capability gain.** `~/.cursor/skills/` is a live convention (twenty third-party skills were installed there on the developer machine, including Cloudflare's official set), and `~/.cursor/mcp.json` is the documented MCP config. The legacy path can already deliver both the server and the skill. The bundle would have improved packaging hygiene, not function.
- **Known expiry.** The plan already defers the official Cursor Marketplace listing and states that a future release would prefer the marketplace install and delete the local bundle. The riskiest third of the work built something intended for deletion.
- **Unreproducible load-bearing claim.** Revision 2 recorded that Cursor 3.13.10's shipped source substitutes `${CURSOR_PLUGIN_ROOT}`, and the whole bundle design depended on it. Grepping the installed Cursor 3.13.10 bundle (including forcing text mode on minified files) finds no `CURSOR_PLUGIN_ROOT`, no `cursor-plugin` and no `SKILL.md`; the plugin runtime is evidently not in the Electron bundle. That is not proof the claim is false, but it is not re-derivable here.

Accepted cost: the legacy installer machinery stays. `HarnessIntegrationManager`, `CursorMCPInstaller` and `SkillInstaller` must remain alive for Cursor regardless, and revision 5 then deferred the code-retirement task altogether (see Phase D), so this plan removes no legacy code at all - it only stops Codex from using it.

Open item discovered during the decision, tracked separately from this plan: on the developer machine `~/.cursor/skills/remarc/` is an empty directory and `~/.cursor/mcp.json` contains `"mcpServers": {}`, so Remarc's Cursor integration is currently delivering nothing. Diagnose that before investing further in Cursor.

## Global Constraints

- All app code changes in a git worktree under `.worktrees/` (CLAUDE.md mandate). ALWAYS `git fetch origin` first and create worktrees from `origin/main` (`git worktree add .worktrees/<name> origin/main -b <branch>`) - local main can be behind (the release workflow pushes version bumps). Plugin-repo changes in a scratch clone of `github.com/metedata/remarc-agent-plugins`.
- Destructive verification drills (removing plugins, editing config files, mutating the Codex plugin cache) must back up the touched file/directory first and restore it after, as shown in Task 2 Step 3. Never `rm -rf` a path that existed before the drill without a backup.
- Build: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"`. Tests: `cd app/RemarcPackage && swift test`. Relaunch after every successful build: `pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`.
- Copy style: never em dashes, hyphens only. Colors via `remarc*` tokens with `colorScheme`. Tooltips via `.help()`. Every new button needs hover and click states (reuse `TextButton`/`CardActionButton`). One Preferences location per setting.
- Min macOS 14.4. Swift 6 strict concurrency (no `NSLock.lock()` in async contexts - use `withLock`; mark stateless service classes `Sendable`).
- Do not touch the Claude Code integration paths (`PluginInstaller`, `PluginInstallDetector`, `LegacyInstallCleanup`) except where a task explicitly says so.
- Do not touch the Cursor integration at all. `CursorMCPInstaller`, the Cursor branch of `HarnessIntegrationManager`, `SkillInstaller.Harness.cursor` and the Preferences Cursor section stay exactly as they are on main.
- There are no existing Codex users to migrate (revision 6). Never write code that removes, rewrites or repairs a user's pre-existing Codex state. If a task seems to need a cleanup latch, a durable flag, or a lock, that is a sign it has drifted out of scope.
- Empirical facts this plan relies on (verified 2026-08-06 against codex-cli 0.146.1):
  - `codex plugin marketplace add metedata/remarc-agent-plugins --json` -> `{"marketplaceName":"remarc","installedRoot":"~/.codex/.tmp/marketplaces/remarc","alreadyAdded":false}`; re-add reports `"alreadyAdded": true` and exits 0.
  - `codex plugin add remarc@remarc --json` -> `{"pluginId":"remarc@remarc","name":"remarc","marketplaceName":"remarc","version":"local","installedPath":"~/.codex/plugins/cache/remarc/remarc/local","authPolicy":"ON_INSTALL"}`.
  - `codex plugin list --json` -> `{"installed":[{"pluginId":"remarc@remarc","enabled":true,"version":"local",...}],"available":[...]}` (camelCase).
  - `version` is `"local"` because `plugin.json` lacks a `version` field. Task 1 adds semver so the version gate has something real to check and so `plugin list` reports a meaningful version. NOTE: revision 2 justified Task 1 by claiming a `"local"` dir would SHADOW numeric ones and poison future updates. That justification is not supported by the reinstall experiment below - `plugin add` replaces the cache directory outright - so treat Task 1 as correctness and reporting hygiene, not as rescue from a shadowing bug.
  - **Reinstall-over behavior (verified live 2026-08-06):** running `codex plugin add remarc@remarc` on an ALREADY-INSTALLED plugin exits 0, does not error, and RE-RESOLVES from the current marketplace snapshot. Proven end to end: installed at `version: "local"` (cache dir `~/.codex/plugins/cache/remarc/remarc/local`), then added a `"version": "0.5.0"` field to the snapshot manifest and re-ran `codex plugin add remarc@remarc` with no removal step. Result: `installedPath` became `.../remarc/remarc/0.5.0`, `codex plugin list --json` reported `0.5.0`, and the `local` directory was GONE - Codex replaced the install rather than leaving both. Consequence for this plan: the Install button is safe to press repeatedly and doubles as a Repair, and no code ever needs to remove a plugin first. Caveat on method: the semver was injected into the local snapshot manifest rather than pushed to the repo, because the mechanism under test is how `plugin add` reads the snapshot; a real Task 1 push exercises the identical path plus a `marketplace upgrade` to refresh the snapshot.
  - The registered marketplace reports `marketplaceSource: {"sourceType":"git","source":"https://github.com/metedata/remarc-agent-plugins.git"}` - the `.git` URL form, confirmed live. Task 4's provenance canonical set must include it (it does).
  - Codex discovers `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` natively, and DOES load the plugin's skill. It PREFERS `.codex-plugin/plugin.json` when both exist (verified: a version present only in the Codex manifest was the one reported by `plugin add`), and it resolves a relative `cwd` in a plugin MCP config against the installed plugin root, with `args` relative to that - which is the supported replacement for the missing variable. **It does NOT substitute `${CLAUDE_PLUGIN_ROOT}` (or `${PLUGIN_ROOT}`, or `${CODEX_PLUGIN_ROOT}`) in plugin MCP server args, and sets no plugin-root environment variable** - verified end to end 2026-08-06, see the BLOCKED banner at the top. Any earlier claim of hook/MCP variable compat is false for MCP servers.
  - Cursor rejects symlinks in `~/.cursor/plugins/local/` whose target is outside that directory ("rejected: symlink target ... is outside ..."). Task 2's optional local check must COPY the plugin directory, not symlink it.
  - `codex plugin marketplace list --json` returns `{"marketplaces":[{"name":...,"root":...,"marketplaceSource":{"sourceType":"local"|"git","source":...}}]}` - an object envelope with nested source, NOT a flat array (verified live). All JSON-parsing CLI calls must capture stdout only (`ProcessRunner.runCollectingResult(..., mergeStderr: false)`) - codex prints warnings to stderr that would corrupt merged output.
  - `codex plugin marketplace add` on an existing marketplace does NOT refresh its snapshot; `codex plugin marketplace upgrade remarc` does. The installer must upgrade after add to avoid installing from a stale pre-semver snapshot.

## Current legacy state being superseded

- Codex (SUPERSEDED, not removed): `HarnessIntegrationManager.installAll()`/`enable(.codex)` writes a marker-bracketed `[mcp_servers.remarc]` table into `~/.codex/config.toml` (marker `# Generated by Remarc - do not edit`, see [CodexMCPInstaller.swift](../../app/RemarcPackage/Sources/RemarcFeature/Services/CodexMCPInstaller.swift)) pointing node at `BundledMCP.mcpServerPath`, and installs `~/.codex/skills/remarc/SKILL.md` via `SkillInstaller`. After Task 6 the app stops writing these. It never deletes them - with no users to migrate, nothing on disk needs repairing.
- Cursor (RETAINED, out of scope): same pattern into `~/.cursor/mcp.json` (JSON) + `~/.cursor/skills/remarc/SKILL.md`, rendered by `harnessIntegrationSection(.cursor)` with an Enable toggle backed by `HarnessIntegrationManager`. Nothing in this plan changes it.
- Preferences currently renders Codex and Cursor via `harnessIntegrationSection(_:)`; Task 6 replaces the Codex one only.
- Duplicate-server note: a machine that already has the legacy table AND installs the plugin will expose two `remarc` MCP servers to Codex. That is the developer's machine only, and the checklist has a one-time manual removal step. It is deliberately not automated - automating it is precisely the work that failed four review rounds.

---

## Phase A: Plugin repo (metedata/remarc-agent-plugins)

Work in a scratch clone: `gh repo clone metedata/remarc-agent-plugins /tmp/remarc-plugins-work && cd /tmp/remarc-plugins-work`.

### Task 1: Semver version fields + the Codex manifest

**Files:**
- Modify: `plugins/remarc/.claude-plugin/plugin.json`
- Modify: `plugins/remarc-hooks/.claude-plugin/plugin.json`
- Create: `plugins/remarc/.codex-plugin/plugin.json`
- Create: `plugins/remarc/codex-mcp.json`
- NOT touched: `plugins/remarc/.mcp.json`. Claude Code depends on its `${CLAUDE_PLUGIN_ROOT}` form and it works today. Leave it exactly as it is.

**Interfaces:**
- Produces: `"version": "0.5.0"` in the manifests, live on GitHub, plus a Codex-specific manifest whose MCP server actually starts. Codex cache dirs become `~/.codex/plugins/cache/remarc/remarc/0.5.0/`. Task 3's detector surfaces the version as `remarcVersion`; Task 4's install gate rejects the pre-semver `"local"` this task eliminates. Phase B cannot report a successful install, and cannot deliver working tools, until this is pushed.

- [ ] **Step 1: Add version to both Claude manifests**

In `plugins/remarc/.claude-plugin/plugin.json` add after `"name"`:

```json
  "version": "0.5.0",
```

Same edit in `plugins/remarc-hooks/.claude-plugin/plugin.json`. Change nothing else in either file.

- [ ] **Step 1b: Add the Codex manifest and its MCP config**

Without this, Codex installs the plugin and gets zero tools - see the banner at the top of this plan. Codex prefers `.codex-plugin/plugin.json` over `.claude-plugin/plugin.json` when both are present (verified), so this is additive and cannot affect Claude Code.

Create `plugins/remarc/.codex-plugin/plugin.json`:

```json
{
  "name": "remarc",
  "version": "0.5.0",
  "description": "Read, address, and resolve Remarc comments from Codex.",
  "author": { "name": "Mete Polat", "email": "mete@metedata.com" },
  "homepage": "https://remarc.app",
  "repository": "https://github.com/metedata/remarc-agent-plugins",
  "license": "MIT",
  "keywords": ["remarc", "comments", "macos", "code-review"],
  "mcpServers": "./codex-mcp.json"
}
```

Create `plugins/remarc/codex-mcp.json`. The relative `cwd` is the whole point: Codex resolves it against the installed plugin root and then resolves `args` against that, which is its documented replacement for `${CLAUDE_PLUGIN_ROOT}`:

```json
{
  "mcpServers": {
    "remarc": {
      "command": "node",
      "args": ["mcp/dist/index.js"],
      "cwd": "."
    }
  }
}
```

Per OpenAI's plugin docs only the manifest belongs in `.codex-plugin/`; `skills/`, `hooks/` and the mcp config files stay at the plugin root, so all three harness manifests share one `mcp/dist/index.js` and one `skills/remarc/SKILL.md`.

- [ ] **Step 2: Validate JSON**

Run:

```bash
for f in plugins/remarc/.claude-plugin/plugin.json \
         plugins/remarc-hooks/.claude-plugin/plugin.json \
         plugins/remarc/.codex-plugin/plugin.json \
         plugins/remarc/codex-mcp.json; do
  python3 -m json.tool "$f" >/dev/null || echo "INVALID: $f"
done && echo OK
```

Expected: `OK` with no INVALID lines.

- [ ] **Step 3: Commit AND PUSH - this is a hard precondition for Phase B**

Phase A happens in a throwaway clone, so a commit that is never pushed is a commit that never happened. Nothing in Phase B works until these manifests are live on GitHub: without them `codex plugin list --json` reports version `"local"`, `isNumericVersion("local")` is false, `CodexPluginInstaller.install()` returns `.failed`, and the migration is dead on arrival for every user.

```bash
git add -A && git commit -m "Add semver versions - required for sane Codex version-dir semantics" && git push
```

Refresh both local caches so later verification tests against the pushed state, not a stale snapshot:

```bash
claude plugin marketplace update remarc
codex plugin marketplace upgrade remarc 2>/dev/null || true
```

- [ ] **Step 4: Verify the semver is actually live before going any further**

```bash
codex plugin marketplace add metedata/remarc-agent-plugins >/dev/null 2>&1
codex plugin marketplace upgrade remarc >/dev/null 2>&1
python3 -c "import json,urllib.request; print('published version:', json.load(urllib.request.urlopen('https://raw.githubusercontent.com/metedata/remarc-agent-plugins/main/plugins/remarc/.claude-plugin/plugin.json')).get('version'))"
```

Expected: `published version: 0.5.0`. If it prints `None`, the push did not land - stop and fix it. **Do not start Phase B until this prints a version.** Task 2 is independent of this gate and must never block it.

### Task 2: Cursor dual-manifest for the future marketplace listing

**Files:**
- Create: `plugins/remarc/.cursor-plugin/plugin.json`
- Create: `plugins/remarc/cursor-mcp.json`
- Modify: `README.md`

**Interfaces:**
- Produces: a Cursor-parseable manifest in the same plugin dir (Figma's `figma/mcp-server-guide` proves multi-manifest single-dir works). This exists ONLY so a future official Cursor Marketplace listing has something to publish. No app code consumes it - revision 4 cut the app-side Cursor install path entirely, and Cursor users continue to be served by the existing `~/.cursor/mcp.json` + `~/.cursor/skills/` integration on main.

- [ ] **Step 1: Write the Cursor manifest**

Create `plugins/remarc/.cursor-plugin/plugin.json`:

```json
{
  "name": "remarc",
  "displayName": "Remarc",
  "version": "0.5.0",
  "description": "Read, address, and resolve Remarc comments from Cursor.",
  "author": { "name": "Mete Polat", "email": "mete@metedata.com" },
  "homepage": "https://remarc.app",
  "repository": "https://github.com/metedata/remarc-agent-plugins",
  "license": "MIT",
  "keywords": ["remarc", "comments", "macos", "code-review"],
  "skills": "./skills/",
  "mcpServers": "./cursor-mcp.json"
}
```

- [ ] **Step 2: Write the Cursor MCP config with the plugin-root variable**

Create `plugins/remarc/cursor-mcp.json`. Revision 2 recorded `${CURSOR_PLUGIN_ROOT}` substitution as verified in Cursor 3.13.10's shipped source, but revision 4 could not re-derive that claim (see "Why Cursor was cut"), so treat it as UNVERIFIED and prove it in Step 3 before publishing. Bare relative args are definitely not resolved (no cwd is set on plugin MCP servers), so a variable of some form is required:

```json
{
  "mcpServers": {
    "remarc": {
      "command": "node",
      "args": ["${CURSOR_PLUGIN_ROOT}/mcp/dist/index.js"]
    }
  }
}
```

- [ ] **Step 3: Verify by local install (COPY, never symlink) - REQUIRED, this is the only proof the manifest works**

This step now carries the weight that revision 2 placed on reading Cursor's minified source. If `${CURSOR_PLUGIN_ROOT}` does not resolve, the MCP server will fail to spawn and you must fix the manifest before publishing.

Cursor rejects symlinks pointing outside `~/.cursor/plugins/local/`. Back up any pre-existing directory first, then copy:

```bash
[ -e ~/.cursor/plugins/local/remarc ] && mv ~/.cursor/plugins/local/remarc ~/.cursor/plugins/local/remarc.pre-test-backup
cp -R "$(pwd)/plugins/remarc" ~/.cursor/plugins/local/remarc
```

Restart Cursor (or run "Developer: Reload Window"), open Customize, confirm the Remarc plugin appears and its MCP server starts (invoke a remarc tool in chat; Cursor's plugin logs record `loadClaudePlugin`/local plugin loads). If the server does not spawn, capture Cursor's log output before changing anything. Restore state after:

```bash
rm -rf ~/.cursor/plugins/local/remarc
[ -e ~/.cursor/plugins/local/remarc.pre-test-backup ] && mv ~/.cursor/plugins/local/remarc.pre-test-backup ~/.cursor/plugins/local/remarc
```

If this verification does not pass, do not commit the Cursor manifest files - an unvalidated Cursor manifest must not reach the marketplace snapshot existing users pull. This gate applies ONLY to Task 2's own Cursor files. It has no authority over Task 1, which pushes independently and must already be live before Phase B starts. Revision 4 recorded that the Cursor plugin runtime could not be found in the installed Cursor 3.13.10 bundle, so this verification may well be impossible right now; if so, skip Task 2 entirely and move on. Task 2 is optional groundwork for a deferred Marketplace listing, and nothing in the Codex migration depends on it.

- [ ] **Step 4: README - add Codex and Cursor install sections**

Append to `README.md` after the existing Install section. The outer fence below is FOUR backticks because the content itself contains a three-backtick block - a three-backtick outer fence is closed early by the inner one and silently corrupts the rest of the document (this exact bug was present in revisions 2 and 3):

````markdown
## Codex

```sh
codex plugin marketplace add metedata/remarc-agent-plugins
codex plugin add remarc@remarc
```

## Cursor

The Remarc macOS app configures Cursor directly (Preferences > MCP Integrations > Cursor);
no plugin install is needed. A Cursor Marketplace listing for this plugin is planned.
````

- [ ] **Step 5: Commit and push**

```bash
git add -A && git commit -m "Cursor manifest + Codex install docs" && git push
```

Then refresh the local dev install so later tasks test against the pushed state:

```bash
claude plugin marketplace update remarc && claude plugin update remarc@remarc && claude plugin update remarc-hooks@remarc
```

---

## Phase B: Codex app-side

All tasks in a worktree: `git fetch origin && git worktree add .worktrees/codex-plugin origin/main -b feat/codex-plugin`.

### Task 3: CodexPluginDetector

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/CodexPluginDetector.swift`
- Test: `app/RemarcPackage/Tests/RemarcFeatureTests/CodexPluginDetectorTests.swift`

**Interfaces:**
- Consumes: `ShellResolver.resolveBinaryPath("codex")`, `ProcessRunner.runCollectingResult` (NOT `runCapture` - see below).
- Produces: `struct CodexPluginState: Equatable, Sendable { let remarcInstalled: Bool; let remarcEnabled: Bool; let remarcVersion: String?; static let zero: CodexPluginState }` and `final class CodexPluginDetector: Sendable { init(); static func parse(jsonOutput: Data) throws -> CodexPluginState; func read() async -> CodexPluginState }`. Tasks 4 and 6 consume both. `remarcVersion` is parsed from the entry's `version` field; a value of `"local"` means the install came from a pre-semver snapshot, which Task 4's gate rejects and Task 6 surfaces as "Needs repair". The detector's `read()` must call `runCollectingResult(..., mergeStderr: false)` and reject timeout/nonzero, NOT `runCapture` - `runCapture` never escalates past SIGTERM, so a trapping process hangs detection.

- [ ] **Step 1: Write the failing tests**

Create `CodexPluginDetectorTests.swift`:

```swift
import XCTest
@testable import RemarcFeature

final class CodexPluginDetectorTests: XCTestCase {
    // Envelope and field names captured from a real `codex plugin list --json`
    // run (codex-cli 0.146.1, 2026-08-06); the remarc entry is adapted to the
    // post-Task-1 semver state (the live test predated the version field and
    // reported version "local").
    private let realOutput = """
    { "installed": [
        { "pluginId": "browser@openai-bundled", "name": "browser", "marketplaceName": "openai-bundled", "version": "26.721.81911", "installed": true, "enabled": true },
        { "pluginId": "remarc@remarc", "name": "remarc", "marketplaceName": "remarc", "version": "0.5.0", "installed": true, "enabled": true }
      ],
      "available": [] }
    """.data(using: .utf8)!

    func testDetectsInstalledRemarcPlugin() throws {
        let state = try CodexPluginDetector.parse(jsonOutput: realOutput)
        XCTAssertTrue(state.remarcInstalled)
        XCTAssertTrue(state.remarcEnabled)
        XCTAssertEqual(state.remarcVersion, "0.5.0")
    }

    func testAbsentRemarcReportsNotInstalled() throws {
        let json = #"{ "installed": [{ "pluginId": "figma@openai-curated", "enabled": true }], "available": [] }"#.data(using: .utf8)!
        let state = try CodexPluginDetector.parse(jsonOutput: json)
        XCTAssertFalse(state.remarcInstalled)
        XCTAssertFalse(state.remarcEnabled)
        XCTAssertNil(state.remarcVersion)
    }

    func testStaleLocalVersionIsSurfaced() throws {
        // Pre-Task-1 installs report version "local" (no manifest version
        // field); Task 4's install gate and Task 6's status row key off it.
        let json = #"{ "installed": [{ "pluginId": "remarc@remarc", "enabled": true, "version": "local" }], "available": [] }"#.data(using: .utf8)!
        let state = try CodexPluginDetector.parse(jsonOutput: json)
        XCTAssertTrue(state.remarcInstalled)
        XCTAssertEqual(state.remarcVersion, "local")
    }

    func testDisabledRemarcReportsInstalledNotEnabled() throws {
        let json = #"{ "installed": [{ "pluginId": "remarc@remarc", "enabled": false }], "available": [] }"#.data(using: .utf8)!
        let state = try CodexPluginDetector.parse(jsonOutput: json)
        XCTAssertTrue(state.remarcInstalled)
        XCTAssertFalse(state.remarcEnabled)
    }

    func testMalformedJSONReportsZero() {
        let state = (try? CodexPluginDetector.parse(jsonOutput: "nope".data(using: .utf8)!)) ?? .zero
        XCTAssertEqual(state, .zero)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/RemarcPackage && swift test --filter CodexPluginDetectorTests`
Expected: compile FAIL - `Cannot find 'CodexPluginDetector' in scope`

- [ ] **Step 3: Implement**

Create `CodexPluginDetector.swift`:

```swift
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
        let remarc = installed.first { ($0["pluginId"] as? String) == "remarc@remarc" }
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/RemarcPackage && swift test --filter CodexPluginDetectorTests`
Expected: 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(codex): plugin detector via codex plugin list --json"
```

### Task 4: CodexPluginInstaller

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/CodexPluginInstaller.swift`
- Test: `app/RemarcPackage/Tests/RemarcFeatureTests/CodexPluginInstallerTests.swift`

**Interfaces:**
- Consumes: `ProcessRunner.CommandResult`, `ProcessRunner.runCollectingResult`, `ShellResolver`.
- Produces: `enum CodexPluginInstaller { static let marketplaceSlug: String; static var marketplaceArguments: [String]; static var installArguments: [String]; static func manualCommands() -> String; enum Outcome: Equatable, Sendable { case success, codexNotFound, failed(String) }; static func outcome(install: ProcessRunner.CommandResult?, marketplace: ProcessRunner.CommandResult?) -> Outcome; static func install() async -> Outcome; static func isNumericVersion(_ version: String) -> Bool; enum MarketplaceProvenance: Equatable, Sendable { case ours, foreign(String), absent }; static func marketplaceProvenance(listJSON: Data) -> MarketplaceProvenance }`. Task 6 is the only consumer: it calls `install()` from the Install/Repair button, renders `manualCommands()` as the copy-paste fallback, and uses `isNumericVersion(_:)` to decide whether an installed plugin is healthy.

- [ ] **Step 1: Write the failing tests**

Create `CodexPluginInstallerTests.swift`:

```swift
import XCTest
@testable import RemarcFeature

final class CodexPluginInstallerTests: XCTestCase {
    private func result(_ exitCode: Int32, _ output: String = "", timedOut: Bool = false) -> ProcessRunner.CommandResult {
        ProcessRunner.CommandResult(exitCode: exitCode, output: output, timedOut: timedOut)
    }

    func testInstallSuccessWinsEvenWhenMarketplaceAddFailed() {
        // codex marketplace re-add exits 0 with alreadyAdded, but tolerate
        // nonzero too (older CLIs, transient states) when install succeeds.
        let outcome = CodexPluginInstaller.outcome(
            install: result(0, #"{"pluginId":"remarc@remarc"}"#),
            marketplace: result(1, "error: marketplace exists")
        )
        XCTAssertEqual(outcome, .success)
    }

    func testInstallFailureSurfacesInstallOutput() {
        let outcome = CodexPluginInstaller.outcome(
            install: result(1, "error: plugin not found in marketplace"),
            marketplace: result(0, "")
        )
        XCTAssertEqual(outcome, .failed("error: plugin not found in marketplace"))
    }

    func testSilentInstallFailureFallsBackToMarketplaceOutput() {
        let outcome = CodexPluginInstaller.outcome(
            install: result(1, " \n"),
            marketplace: result(128, "fatal: unable to access repo")
        )
        XCTAssertEqual(outcome, .failed("fatal: unable to access repo"))
    }

    func testTimeoutProducesTimeoutMessage() {
        let outcome = CodexPluginInstaller.outcome(
            install: result(15, "", timedOut: true),
            marketplace: result(0, "")
        )
        guard case .failed(let message) = outcome else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("Timed out"))
    }

    func testCommandConstruction() {
        XCTAssertEqual(CodexPluginInstaller.marketplaceArguments, ["plugin", "marketplace", "add", "metedata/remarc-agent-plugins"])
        XCTAssertEqual(CodexPluginInstaller.installArguments, ["plugin", "add", "remarc@remarc"])
        let manual = CodexPluginInstaller.manualCommands()
        XCTAssertTrue(manual.contains("codex plugin marketplace add metedata/remarc-agent-plugins"))
        XCTAssertTrue(manual.contains("codex plugin marketplace upgrade remarc"))
        XCTAssertTrue(manual.contains("codex plugin add remarc@remarc"))
        // Must never tell the user to remove the plugin: reinstall-over
        // works, and removal opens a window where they have neither.
        XCTAssertFalse(manual.contains("plugin remove"))
    }

    // MARK: - Marketplace provenance (envelope verified live, codex-cli 0.146.1)

    private func provenanceJSON(_ marketplaceEntry: String) -> Data {
        #"{"marketplaces":[\#(marketplaceEntry)]}"#.data(using: .utf8)!
    }

    func testProvenanceOursForEveryCanonicalGitSource() {
        for source in [
            "metedata/remarc-agent-plugins",
            "https://github.com/metedata/remarc-agent-plugins",
            "https://github.com/metedata/remarc-agent-plugins.git",
        ] {
            let json = provenanceJSON(#"{"name":"remarc","root":"/Users/x/.codex/.tmp/marketplaces/remarc","marketplaceSource":{"sourceType":"git","source":"\#(source)"}}"#)
            XCTAssertEqual(CodexPluginInstaller.marketplaceProvenance(listJSON: json), .ours, "source: \(source)")
        }
    }

    func testProvenanceForeignForLookAlikeGitSources() {
        // Exactly what substring matching would wrongly accept.
        for source in [
            "https://github.com/evil/metedata/remarc-agent-plugins",
            "https://github.com/metedata/remarc-agent-plugins-evil",
            "git@github.com:metedata/remarc-agent-plugins.git",
        ] {
            let json = provenanceJSON(#"{"name":"remarc","marketplaceSource":{"sourceType":"git","source":"\#(source)"}}"#)
            guard case .foreign = CodexPluginInstaller.marketplaceProvenance(listJSON: json) else {
                return XCTFail("expected foreign for \(source)")
            }
        }
    }

    func testProvenanceForeignForLocalSourceEchoingOurSlug() {
        let json = provenanceJSON(#"{"name":"remarc","marketplaceSource":{"sourceType":"local","source":"/tmp/metedata/remarc-agent-plugins"}}"#)
        guard case .foreign = CodexPluginInstaller.marketplaceProvenance(listJSON: json) else {
            return XCTFail("expected foreign for a local-source marketplace")
        }
    }

    func testProvenanceForeignWhenMarketplaceSourceMissing() {
        // Seen live: one built-in marketplace entry carries NO
        // marketplaceSource object at all. A remarc entry shaped like that
        // is foreign (never ours), not a parse error.
        let json = provenanceJSON(#"{"name":"remarc","root":"/Users/x/.codex/builtin/remarc"}"#)
        guard case .foreign = CodexPluginInstaller.marketplaceProvenance(listJSON: json) else {
            return XCTFail("expected foreign when marketplaceSource is absent")
        }
    }

    func testProvenanceAbsentWhenNoRemarcEntry() {
        let json = provenanceJSON(#"{"name":"openai-bundled","root":"/b","marketplaceSource":{"sourceType":"local","source":"/b"}}"#)
        XCTAssertEqual(CodexPluginInstaller.marketplaceProvenance(listJSON: json), .absent)
    }

    func testProvenanceAbsentOnMalformedJSON() {
        XCTAssertEqual(CodexPluginInstaller.marketplaceProvenance(listJSON: Data("nope".utf8)), .absent)
    }

    // MARK: - Semver gate

    func testSemverGateAcceptsRealVersions() {
        for v in ["0.5.0", "26.721.81911", "1.0", "1.2.3-beta.1"] {
            XCTAssertTrue(CodexPluginInstaller.isNumericVersion(v), v)
        }
    }

    func testSemverGateRejectsLocalAndMalformed() {
        for v in ["local", "", "latest", "v1.2.3", "1.", ".1", "1.x"] {
            XCTAssertFalse(CodexPluginInstaller.isNumericVersion(v), v)
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd app/RemarcPackage && swift test --filter CodexPluginInstallerTests`
Expected: compile FAIL - `Cannot find 'CodexPluginInstaller' in scope`

- [ ] **Step 3: Implement**

Create `CodexPluginInstaller.swift`:

```swift
import Foundation

/// Installs the Remarc Codex plugin by shelling out to the scriptable
/// `codex plugin` CLI (all subcommands support --json and run
/// non-interactively). The app never edits ~/.codex/config.toml for MCP
/// registration anymore - Codex owns its own plugin state.
public enum CodexPluginInstaller {
    public static let marketplaceSlug = "metedata/remarc-agent-plugins"

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
        ["plugin", "add", "remarc@remarc"]
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
        codex plugin marketplace upgrade remarc
        codex plugin add remarc@remarc
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
    /// installer guards against). Envelope verified live on codex-cli
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
        guard let remarc = entries.first(where: { ($0["name"] as? String) == "remarc" }) else { return .absent }
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

    public static func install() async -> Outcome {
        guard let codex = await ShellResolver.resolveBinaryPath("codex") else {
            return .codexNotFound
        }
        let marketplace = await ProcessRunner.runCollectingResult(
            codex, arguments: marketplaceArguments, timeoutSeconds: commandTimeoutSeconds
        )

        // JSON must come from stdout only - codex prints warnings to stderr.
        guard let listOutput = await ProcessRunner.runCollectingResult(
            codex, arguments: ["plugin", "marketplace", "list", "--json"],
            timeoutSeconds: commandTimeoutSeconds, mergeStderr: false
        ), listOutput.exitCode == 0, !listOutput.timedOut else {
            return .failed("Could not verify the plugin marketplace. Run the commands manually.")
        }
        switch marketplaceProvenance(listJSON: Data(listOutput.output.utf8)) {
        case .ours: break
        case .foreign(let source):
            return .failed("A different Codex marketplace named \"remarc\" already exists (\(source)). Remove it with: codex plugin marketplace remove remarc - then try again.")
        case .absent:
            return .failed("The remarc marketplace could not be added. Run the commands manually.")
        }

        // `marketplace add` on an existing marketplace does NOT refresh its
        // snapshot - upgrade explicitly so existing users never install from
        // a stale pre-semver state. Failure here is nonfatal (offline users
        // still install from their snapshot); the version gate below is what
        // makes staleness fail loudly instead of silently.
        _ = await ProcessRunner.runCollectingResult(
            codex, arguments: ["plugin", "marketplace", "upgrade", "remarc"],
            timeoutSeconds: commandTimeoutSeconds
        )

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
            return .failed("Installed from a stale marketplace snapshot (version \"\(reported)\"). Run: codex plugin marketplace upgrade remarc && codex plugin add remarc@remarc")
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
```

Note for the implementer: `outcome()` must check `timedOut` BEFORE `exitCode == 0` (a signal-trapping wrapper can exit 0 after SIGTERM), exactly like the hardened `PluginInstaller.outcome`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd app/RemarcPackage && swift test --filter CodexPluginInstallerTests`
Expected: 13 tests PASS

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(codex): one-click plugin installer via codex CLI"
```

### Task 6: Preferences - Codex section becomes a plugin panel

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/HarnessIntegrationManager.swift`

**Interfaces:**
- Consumes: `CodexPluginDetector` (Task 3), `CodexPluginInstaller` (Task 4), existing view helpers `sectionHeader`, `integrationStatusLabel`, `settingsHint`, `textButton`, `CardActionButton`, and the existing generic `pluginRow(plugin:title:subtitle:installed:enabled:installAllowed:)` used by the Claude Code section.
- Produces: `codexIntegrationSection` replacing `harnessIntegrationSection(.codex)` in `mcpIntegrationsSection`.

The existing `pluginRow` is Claude-Code-specific in three places: it renders `PluginInstaller.manualCommands(plugin:)`, copies via `copyPluginCommands`, and installs via `installPlugin(_:)`. Generalize it minimally by adding parameters instead of duplicating the layout.

- [ ] **Step 1: Generalize pluginRow**

Change the signature and the three call-throughs (existing Claude Code call sites updated in the same edit):

There is exactly ONE final signature. Use it verbatim:

```swift
    @ViewBuilder
    private func pluginRow(
        plugin: String,
        title: String,
        subtitle: String,
        installed: Bool,
        enabled: Bool,
        healthy: Bool,
        needsAction: Bool,
        actionTitle: String,
        installAllowed: Bool,
        checked: Bool,
        installing: Bool,
        manualCommands: String,
        installAction: @escaping () -> Void
    ) -> some View {
```

`installing` replaces the internal `installingPlugins.contains(plugin)` check (Claude Code call sites pass exactly that expression; Codex passes `codexInstalling`), and the commands block + copy button render only when `manualCommands` is non-empty. Every call site in the final state supplies a non-empty `manualCommands`, but keep the guard: it costs one line and the Claude Desktop section may reuse this row later.

Inside the body: replace the two `pluginStateChecked` reads with `checked`, `installingPlugins.contains(plugin)` with `installing`, `PluginInstaller.manualCommands(plugin: plugin)` with `manualCommands`, and the Install button action with `installAction()`. `copyPluginCommands(_:)` becomes `copyCommands(_ commands: String, key: String)` (pasteboard write + `copiedPluginCommands = key`), with the copy button passing `copyCommands(manualCommands, key: plugin)`.

The status helper stops reading view state internally - `checked` becomes its first parameter, and it gains `healthy` so a degraded install is not reported as fine:

```swift
    private func pluginRowStatus(checked: Bool, installed: Bool, enabled: Bool, healthy: Bool) -> IntegrationRowStatus {
        if !checked { return .pending("Checking") }
        if installed && enabled && healthy { return .installed("Installed") }
        if installed && enabled { return .warning("Needs repair") }
        if installed { return .warning("Installed (disabled)") }
        return .inactive("Not installed")
    }
```

and the call inside `pluginRow` becomes `integrationStatusLabel(pluginRowStatus(checked: checked, installed: installed, enabled: enabled, healthy: healthy))`.

**The action affordance is an explicit per-call-site predicate, NOT derived from `healthy`.** Replace both `!installed` conditions in the row body with `needsAction`, and label the button `actionTitle`.

Deriving the button from `healthy` with a defaulted parameter was tried and is wrong: Claude Code's call sites do not pass `healthy`, so it defaults to `true`, and `!healthy` is then always false - which hides the Install button even when the Claude plugin is absent. That silently breaks the shipped Claude Code panel. An explicit predicate per call site cannot fail that way, because every caller must state its own answer.

- Claude Code passes `healthy: pluginState.remarcInstalled` (presence is the only health notion it has), `needsAction: !pluginState.remarcInstalled`, `actionTitle: "Install"`.
- Codex passes `healthy: codexHealthy`, `needsAction: !codexHealthy`, `actionTitle: codexPluginState.remarcInstalled ? "Repair" : "Install"`, where health covers ALL three failure modes, not just the version:

```swift
    private var codexHealthy: Bool {
        codexPluginState.remarcInstalled
            && codexPluginState.remarcEnabled
            && (codexPluginState.remarcVersion.map(CodexPluginInstaller.isNumericVersion) ?? false)
    }
```

Note the consequence for verification: a healthy row deliberately hides the button, so idempotence cannot be checked by clicking Install twice. The checklist tests it at the CLI instead.

Claude Code call sites become:

```swift
            pluginRow(
                plugin: "remarc",
                title: "remarc",
                subtitle: "Required. MCP server and skill for managing comments.",
                installed: pluginState.remarcInstalled,
                enabled: pluginState.remarcEnabled,
                healthy: pluginState.remarcInstalled,
                needsAction: !pluginState.remarcInstalled,
                actionTitle: "Install",
                installAllowed: true,
                checked: pluginStateChecked,
                installing: installingPlugins.contains("remarc"),
                manualCommands: PluginInstaller.manualCommands(plugin: "remarc"),
                installAction: { installPlugin("remarc") }
            )
```

(and equivalently for `remarc-hooks` with `installed: pluginState.remarcHooksInstalled`, `enabled: pluginState.remarcHooksEnabled`, `healthy: pluginState.remarcHooksInstalled`, `needsAction: !pluginState.remarcHooksInstalled`, `actionTitle: "Install"`, `installAllowed: pluginState.remarcInstalled`, `installing: installingPlugins.contains("remarc-hooks")`).

This preserves the shipped Claude Code behavior exactly: `needsAction` is `!installed`, which is the condition the row uses today.

- [ ] **Step 2: Add Codex state + section**

New state vars next to the Claude Code plugin state:

```swift
    @State private var codexPluginState: CodexPluginState = .zero
    @State private var codexPluginChecked = false
    @State private var codexInstalling = false
    @State private var codexInstallError: String?
    private let codexDetector = CodexPluginDetector()
```

New section (replaces `harnessIntegrationSection(.codex)` in `mcpIntegrationsSection`'s VStack):

```swift
    private var codexIntegrationSection: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                "Codex",
                description: "Remarc integrates through a Codex plugin from the \(CodexPluginInstaller.marketplaceSlug) marketplace."
            )

            pluginRow(
                plugin: "codex-remarc",
                title: "remarc",
                subtitle: "MCP server and skill for managing comments from Codex.",
                installed: codexPluginState.remarcInstalled,
                enabled: codexPluginState.remarcEnabled,
                healthy: codexHealthy,
                needsAction: !codexHealthy,
                actionTitle: codexPluginState.remarcInstalled ? "Repair" : "Install",
                installAllowed: true,
                checked: codexPluginChecked,
                installing: codexInstalling,
                manualCommands: CodexPluginInstaller.manualCommands(),
                installAction: { installCodexPlugin() }
            )

            if let error = codexInstallError {
                settingsHint(error, icon: "exclamationmark.triangle.fill", tint: Color.remarcWarning(for: colorScheme))
            }
        }
    }

    private func installCodexPlugin() {
        guard !codexInstalling else { return }
        codexInstalling = true
        codexInstallError = nil
        Task { @MainActor in
            switch await CodexPluginInstaller.install() {
            case .success:
                break
            case .codexNotFound:
                codexInstallError = "Codex CLI not found. Install Codex first, or run the commands in a terminal."
            case .failed(let message):
                codexInstallError = message
            }
            codexPluginState = await codexDetector.read()
            codexPluginChecked = true
            codexInstalling = false
        }
    }
```

Refresh on appear - extend the existing `.task` on `mcpIntegrationsSection`:

```swift
        .task {
            await refreshPluginState()
            codexPluginState = await codexDetector.read()
            codexPluginChecked = true
            await resolveManualPaths()
        }
```

- [ ] **Step 3: Stop the legacy Codex installer**

In `HarnessIntegrationManager.installAll()`, extend the existing skip:

```swift
            // Claude Code and Codex ship as marketplace plugins
            // (PluginInstaller / CodexPluginInstaller); only Cursor still
            // uses the app-side installer. This is the final state:
            // revision 4 cut the Cursor migration, so Cursor keeps this
            // path for good.
            if harness == .claudeCode || harness == .codex { continue }
```

In `mcpIntegrationsSection`, delete the `harnessIntegrationSection(.codex)` row (replaced by `codexIntegrationSection`).

- [ ] **Step 4: Build, test, relaunch, verify**

Run: `swift test` (all PASS), then the xcodebuild + relaunch commands from Global Constraints.
Manual check: Preferences > MCP Integrations shows the new Codex section; with the plugin not installed it shows Not installed + commands + Copy + Install; clicking Install completes and flips to Installed; `codex plugin list --json` confirms a numeric version. Press Install a second time and confirm it stays healthy (reinstall-over is verified safe). Confirm the app no longer adds `[mcp_servers.remarc]` to `~/.codex/config.toml` on relaunch, and that any table already there is left untouched - this plan deletes nothing.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(preferences): Codex section becomes plugin install panel"
```

## Phase D: Documentation only

Revision 5 DEFERRED the code-retirement task entirely (was Task 11). Both review engines independently found it not mechanically executable against the real sources, and one found a regression its own stated verification could not catch: `MCPManager.isEnabled` is written only by the enable/register paths the task deletes, but is read seven times in `PopoverContentView` (the menu bar MCP indicator, its tooltip, the Enabled/Not Connected label, the glow, and the sample-prompt block) and once in `ExportManager` to gate the export AI hint. Neither file was in the task's file list, and pinning that property to false compiles and tests clean, so the menu bar would have gone permanently red and the export hint would have silently vanished with a green build.

The task also described an API that does not exist: it referenced `.claudeCode`/`.codex` branches of `enable`/`disable`, while the real `HarnessIntegrationManager` exposes `enable(_:)`/`uninstall(_:)` with the case branches inside `installMCP`/`uninstallMCP`, and `MCPManager.checkDependencies()` mixes path resolution with legacy auto-registration so there is no clean seam to cut.

Deferring costs nothing a user can see: retirement is tidying, and after the Cursor cut the code is not fully dead anyway. Revisit as its own piece of work, starting by giving `MCPManager.isEnabled` a plugin-aware source (derived from `PluginInstallDetector`/`CodexPluginDetector`) so its consumers keep working, then removing the legacy writers.

No worktree and no code changes: this phase is documentation only, committed directly on main (CLAUDE.md allows root docs on main). Start only after Phase B is merged and verified on this machine. The worktree command that used to live here belonged to the code-retirement task that revision 5 deferred.

Scope note for revision 4: Cursor still uses the app-side installer, so this phase can NOT delete `HarnessIntegrationManager`, `CursorMCPInstaller` or `SkillInstaller`. It removes only the Claude Code and Codex install paths, which are now genuinely dead. The full retirement returns to the table if and when Cursor moves to the Marketplace listing.

### Task 12: Documentation + repo truth

**Files:**
- Modify: `CLAUDE.md` (root, allowed on main): rewrite the "Claude Code integration" section into an "Agent integrations" section describing the two plugin surfaces accurately: Claude Code is plugin-based AND retains its legacy cleanup latch; Codex is plugin-based and INSTALL-ONLY with no cleanup; Cursor remains fully app-managed via `~/.cursor/mcp.json` + `~/.cursor/skills/`, with its installer branch still active. Do not describe the legacy machinery as dormant - only its Claude Code and Codex branches are. Also reconcile the stale "Min macOS: 14.4" line against `MACOSX_DEPLOYMENT_TARGET = 14.0` in `app/Config/Shared.xcconfig` while editing.
- Modify: `docs/superpowers/plans/2026-08-06-codex-cursor-plugin-migration.md`: check off completed tasks.
- Memory: update `~/.claude/projects/<project>/memory/project_plugin_marketplace_migration_stranded.md` (and its line in MEMORY.md) - Codex migrated; Cursor deliberately deferred with the reasoning; legacy installer machinery still present; its Claude Code and Codex branches are dormant but the Cursor branch is live (retirement deferred); remaining items are the code retirement with an `MCPManager.isEnabled` replacement, the Cursor official-marketplace listing, the empty `~/.cursor/skills/remarc/` diagnosis, and `mcp/` consolidation once Claude Desktop is rethought.
- Do NOT claim the legacy machinery was removed. It was not - revision 5 deferred that work.

- [ ] **Step 1: Apply the documentation edits above, commit on main**

```bash
git add CLAUDE.md docs && git commit -m "docs: Claude Code and Codex are plugin-based; Cursor stays app-managed"
```

## Final verification checklist (after all phases)

Every destructive drill below follows the Global Constraints backup rule (same pattern as Task 2 Step 3): back up the touched file or directory first, restore it after.

- [ ] Fresh Codex state drill. Back up, reset, exercise, restore:

```bash
cp ~/.codex/config.toml ~/.codex/config.toml.drill-backup
codex plugin remove remarc@remarc; codex plugin marketplace remove remarc
```

Preferences Codex section shows Not installed -> Install click -> Installed; `codex plugin list --json` agrees; config.toml has no `[mcp_servers.remarc]`; a Codex session can call `remarc_list_sessions`. Then compare and restore anything unexpected:

```bash
diff ~/.codex/config.toml ~/.codex/config.toml.drill-backup; rm ~/.codex/config.toml.drill-backup
```

(The end state - plugin installed at current semver - is the desired final state, so no rollback beyond the diff check; the backup exists in case the drill goes sideways.)

- [ ] Publish precondition actually held: `codex plugin list --json` reports a numeric version for `remarc@remarc`, not `local`. If it reports `local`, Task 1 was never pushed and everything downstream is invalid.
- [ ] Runtime verification, not just metadata. THIS IS THE ONE THAT MATTERS - installed-and-enabled says nothing about whether the server starts (see the BLOCKED banner). From a clean state, after pressing Install, run:

```bash
echo "" | codex exec --skip-git-repo-check "List every tool available to you whose name contains 'remarc', one per line. If none print exactly NONE."
```

Expected: seven `mcp__remarc__remarc_*` tools. `NONE` means the plugin installed but its MCP server never launched, which is exactly the failure this plan is currently blocked on.

- [ ] Idempotence, tested at the CLI (a healthy row deliberately hides the button, so this cannot be done through the UI): run `codex plugin add remarc@remarc` twice in a row and confirm the second run exits 0 and the plugin stays on a numeric version.
- [ ] Repair affordance: drive the plugin into each degraded state and confirm the row never reads a plain "Installed" with no button. For non-semver, install against a pre-semver snapshot; for disabled, run `codex plugin disable remarc@remarc`. Expect "Needs repair" or "Installed (disabled)" WITH a visible button and the manual commands, and confirm the button recovers it.
- [ ] Marketplace-hijack guard: register a foreign marketplace named `remarc` (back up first: `codex plugin marketplace list --json > /tmp/mkt-backup.json`), press Install, and confirm it refuses with the "different Codex marketplace" message rather than installing. Remove the foreign marketplace afterward.
- [ ] Nothing was deleted: `~/.codex/config.toml` still contains whatever `[mcp_servers.remarc]` table it had before, and `~/.codex/skills/remarc/SKILL.md` is untouched. This plan installs only. If either disappeared, cleanup code leaked back in.
- [ ] App stops writing: with the legacy table removed by hand, relaunch twice and confirm the app does not recreate it.
- [ ] Cursor UNCHANGED: the Preferences Cursor section still shows its Enable toggle and installs exactly as it does on main.
- [ ] Claude Code unaffected: plugin panel still shows Installed.
- [ ] Menu bar and export unaffected (the legacy machinery is still live and still owns `MCPManager.isEnabled`): the MCP indicator reflects real state rather than being stuck on "Not Connected", and an export with the AI hint enabled still includes the hint trailer.
- [ ] `swift test` green; xcodebuild green; app relaunched from main's DerivedData.

One-time developer cleanup, done by hand and only after everything above passes. The developer machine has a legacy table from earlier testing, which would otherwise leave two `remarc` servers registered with Codex:

Line-based, NOT a regex. A regex bounded by `[^\[]*` stops at the `[` inside `args = [...]`, leaving the args line orphaned - and because that line then reads `["/Users/..."]` at column zero, TOML parses it as a table header, so the file silently becomes valid-but-wrong with no error. This was verified by running it; use the version below.

```bash
cp ~/.codex/config.toml ~/.codex/config.toml.backup
python3 - <<'PY'
import pathlib, tomllib
p = pathlib.Path.home() / ".codex/config.toml"
lines = p.read_text().split("\n")
out, i, removed = [], 0, False
while i < len(lines):
    if lines[i].strip() == "[mcp_servers.remarc]":
        if out and out[-1].strip() == "# Generated by Remarc - do not edit":
            out.pop()
        i += 1
        while i < len(lines) and not lines[i].lstrip().startswith("["):
            i += 1
        removed = True
        continue
    out.append(lines[i]); i += 1
text = "\n".join(out)
tomllib.loads(text)          # refuse to write anything that does not parse
d = tomllib.loads(text)
assert "remarc" not in d.get("mcp_servers", {}), "remarc survived removal"
p.write_text(text)
print("removed" if removed else "nothing to remove")
PY
python3 -c "
import tomllib,pathlib
d=tomllib.loads((pathlib.Path.home()/'.codex/config.toml').read_text())
print('mcp_servers now:', list(d.get('mcp_servers',{}).keys()))"
```

Expected: the list no longer contains `remarc`, every other server is still present, and no junk table appears. Diff against the backup before deleting it.

## Revision history

- **Revision 1 (2026-08-06):** initial 12-task plan.
- **Revision 2 (2026-08-06):** Codex adversarial round 1 incorporated (see header note).
- **Revision 3 (2026-08-06):** Codex adversarial round 2's ten-item worklist applied IN PLACE - the delta blocks that had overridden retained code were dissolved into the task bodies, so prose and code no longer diverge. Highlights: Task 8 rewritten around a sentinel + staged atomic swap with hermetic tests; `remarcVersion` threaded through detector/installer/cleanup; install version gate encoded in `CodexPluginInstaller.install()`; `ShippedSkillOwnership` hash-set ownership; `CursorMCPInstaller.uninstall(ifUnchangedSince:)` compare-and-write; reload-hint lifecycle; provenance fixtures; worktree commands pinned to `origin/main`; checklist drills gained backups.
- **Revision 4 (2026-08-06):** Codex adversarial round 3 returned "do not execute" with four criticals and eight highs, and an independent six-lens Claude-side review agreed on the compile-blockers and the destructive migration. Roughly eight of the fourteen findings were Cursor-specific, so **Cursor was cut from the migration** rather than patched a fourth time (rationale in "Why Cursor was cut"); Tasks 8, 9 and 10 are deleted and Phase D is reduced. Surviving non-Cursor findings applied: `ShippedSkillOwnership.isAppShipped` split into a public wrapper plus an internal testable overload (the single-method form does not compile - reproduced the exact error); the regen-guard test's path traversal corrected from four to five `deletingLastPathComponent()` calls plus an explicit existence assertion (four resolved under `app/`, so the test could never have guarded anything); the stale-install migration redesigned to be non-destructive with a bounded attempt counter replacing the pending flag; an advisory lock added mirroring `LegacyInstallCleanup`; the version gate changed to require a parsed semver rather than `!= "local"`; Task 2's three-backtick fence around fenced content corrected to four backticks (it was silently swallowing Step 5 and injecting phantom `## Codex`/`## Cursor` headings into the document); Task 11 rewritten against the verified test layout (`MCPInstallerTests.swift` is swift-testing, there is no `CursorMCPInstallerTests.swift`); hash-set provenance limits documented rather than overclaimed.

- **Revision 4.1 (2026-08-06):** empirically verified the assumption revision 4's whole migration rests on, instead of leaving it as reasoning. Installed the plugin at version `local`, injected a semver into the marketplace snapshot, and re-ran `codex plugin add` with no removal: it exited 0, re-resolved to `0.5.0`, and Codex deleted the stale `local` cache directory itself. So reinstall-over works and removal is genuinely unnecessary. The same run disproved revision 2's stated rationale for Task 1 (that a `local` dir shadows numeric ones) and confirmed the marketplace reports its source as the `.git` URL form that Task 4's provenance set matches. Codex state was backed up and restored; `~/.codex/config.toml` verified byte-identical afterward.

- **Revision 5 (2026-08-06):** round 4 ran on both engines and both returned NOT SAFE, converging independently on the same worst finding. Applied: **the code-retirement task was deferred entirely** (see Phase D) after both engines found it not mechanically executable and one proved its `swift build` oracle could not see the `MCPManager.isEnabled` regression it would ship; **Task 1 now pushes and gates Phase B on the semver actually being live** (previously the only `git push` in the plan sat inside the cut-scope Cursor task, behind a verification revision 4 had already documented as probably impossible, so the migration was dead on arrival); Task 2 explicitly decoupled and marked skippable; `manualCommands()` made non-destructive and given the marketplace-upgrade line that makes a stale snapshot recoverable at all; `import Darwin` added for `flock`; `releaseLock()` no longer deletes the lock file, which was breaking lock identity; the completion latch now re-reads plugin health after the removals instead of trusting the pre-removal gate; Preferences gained a health-based Repair affordance so a degraded install is no longer rendered as "Installed" with no way back, and an explicit user repair resets the attempt ceiling; `isSemver` renamed `isNumericVersion` since it is a pragmatic numeric-dotted check, not a SemVer 2.0 parser.

- **Revision 6 (2026-08-06):** the product owner confirmed there are no existing Codex users, which invalidated the premise of the hardest third of the plan. Deleted Task 5 (`LegacyCodexInstallCleanup`, 454 lines) and Task 7 (its launch wiring), and with them the completion latch and un-latch detection, `ShippedSkillOwnership` and its historical hash set, the stale-install migration, the bounded attempt counter, the advisory `flock` lock, and two `defaults` keys. The plan went from 1470 lines to roughly 970 and from seven tasks to five. This was not a compromise: across four review rounds on two independent engines, every blocking finding lived in the deleted machinery, and the surviving tasks (detector, installer, Preferences panel) never produced one. The app now stops writing the legacy Codex table and never deletes anything; the developer removes their own leftover table once, by hand, from the checklist.

## Revision 7 worklist (from the final review round - apply once the launch-mechanism decision is made)

The final round ran both engines against revision 6. Codex returned NOT SAFE with seven blocking items; the empirical test in the BLOCKED banner independently proved its item 5 is not hypothetical. Three items were fixed immediately because they are independent of the blocked decision and one was a live regression:

- FIXED: Task 6 showed two contradictory `pluginRow` signatures, one labelled FINAL. There is now exactly one.
- FIXED: the action affordance was derived from a defaulted `healthy` parameter, which would have hidden the Install button on the shipped Claude Code panel whenever its plugin was absent. It is now an explicit `needsAction` predicate supplied by each call site, and Codex health covers installed AND enabled AND numeric version rather than version alone.
- FIXED: the stale-version failure message still told users to `codex plugin remove`, contradicting the non-destructive contract two paragraphs above it.

The second engine (a three-lens Claude-side review, 25 findings raised, 19 surviving refutation) reached the same top finding independently in all three lenses, and proposed the exact fix that was applied. It added one further item, since fixed and worth recording because the buggy version was actually executed:

- FIXED: the one-time cleanup snippet used a regex bounded by `[^\[]*`, which stops at the `[` inside `args = [...]`. That left the args line orphaned at column zero, where TOML reads it as a table header - so the file stayed parseable while silently gaining a junk table and losing nothing. Replaced with a line-based removal that skips to the next table header, asserts the result parses, and asserts `remarc` is actually gone before writing. Verified against a realistic fixture.
- FIXED: Task 6 Step 3's replacement comment had been spliced mid-sentence by an earlier edit.
- FIXED: Phase D still carried a worktree command belonging to the deferred retirement task, though it is now documentation-only and commits on main.

Remaining, to apply when the plan unblocks:

1. **Runtime verification gate.** Task 4 proves installation metadata, not a callable tool. Decide whether the UI claims "Installed" or "Verified", and make a clean-state `remarc_list_sessions` call a hard pre-merge gate. A checklist item for this now exists.
2. ~~Detector timeout unbounded.~~ APPLIED: Task 3's `read()` now uses `runCollectingResult(..., mergeStderr: false)` and rejects timeout and nonzero exit.
3. **Repository and worktree handoff is not executable top to bottom.** Phase A leaves the engineer inside the plugin scratch clone; Phase B never returns to the Remarc repo or enters the worktree it creates, and there is no merge step before Task 12 commits on main. Add the explicit `cd`, worktree entry, merge and return-to-main commands.
4. ~~Task 12 would write false documentation.~~ APPLIED: Task 12 now specifies the accurate wording (Claude Code keeps its latch, Codex is install-only, only the Claude/Codex branches are dormant, Cursor stays active).
5. **The "app stops writing" checklist item cannot fail.** Relaunching twice and observing that no table appears proves nothing on a machine where the table was already removed and the code already skips Codex. Make it positive: assert the skip is reached (debug log line) or temporarily re-add a table and confirm it is neither rewritten nor removed.
6. ~~Bare `swift test` in four steps.~~ APPLIED: every filtered test step now begins with `cd app/RemarcPackage &&`.
7. **Nice-to-haves.** (Tooltip APPLIED: now "Runs the commands shown above".) Remove the obsolete comments about `local` shadowing numeric versions, about destroying a working legacy integration, and about the deleted attempt ceiling. Clarify whether the Tech Stack line describes this plan or the whole package (`ProcessRunner.run` is unused by surviving plan code but still used by the Claude cleanup).

- **Revision 8 (2026-08-06):** researched the blocking finding instead of only reproducing it, and unblocked the plan. It is a known upstream issue (openai/codex#19582, #19372, #22842, discussion #28145) with a documented replacement: a relative `cwd`, resolved against the installed plugin root. Verified working here, then verified the zero-risk placement - Codex prefers `.codex-plugin/plugin.json` over `.claude-plugin/plugin.json`, so a Codex-specific manifest pointing at its own `codex-mcp.json` delivers all seven tools while `.claude-plugin` and the root `.mcp.json` stay untouched and the shipped Claude Code path cannot regress. Task 1 now ships that manifest and Phase A validates it. The earlier `npx` suggestion was an inference from unrelated servers' config and has been demoted.

## Known residual risks (accepted, not fixed here)

- `LegacyInstallCleanup.legacyMCPSignatureMatches` (shipped in 0.5.1, used by the Claude Code cleanup) treats ANY server whose command or args end in `mcp/dist/index.js` as Remarc's. A user's own server named `remarc` pointing at a custom path matching that suffix would be removed. Narrow but real, in shipped code, and outside this plan's scope - fix separately with a tighter provenance rule (for example requiring the path to sit under the app's own bundle or Application Support directory).
- A machine that already carries the legacy `[mcp_servers.remarc]` table and then installs the plugin registers two `remarc` servers with Codex. Nothing in this plan detects or fixes that, by design. Realistically it affects only the developer machine, which the checklist cleans up by hand once. If a real user base ever exists before this ships, that assumption must be revisited - and the honest answer then is an explicit, user-initiated switch, not a silent launch-time cleanup.

## Deferred / explicitly out of scope

- **The whole Cursor plugin migration** (was Tasks 8-10). Cursor keeps the app-managed `~/.cursor/mcp.json` + `~/.cursor/skills/remarc/SKILL.md` integration. Revisit only when the official Marketplace listing lands, which would replace the app-written bundle anyway.
- Diagnosing why `~/.cursor/skills/remarc/` is empty and `~/.cursor/mcp.json` has no servers on the developer machine. Independent of this plan and worth doing sooner - it suggests the retained Cursor path may be silently broken.
- Cursor official-marketplace listing (manual submission at cursor.com/marketplace/publish; curated, no SLA). Task 2 prepares the manifest for it.
- Codex official directory submission (portal, review, test cases - repo marketplace serves users meanwhile).
- remarc-hooks for Codex (Codex supports the same hook schema with CLAUDE_PLUGIN_ROOT compat; revisit once hooks leave experimental status on Claude Code).
- Deleting app repo `mcp/` entirely: still bundled for the Cursor integration and the Claude Desktop snippet. Revisit if Claude Desktop gains a plugin surface.
