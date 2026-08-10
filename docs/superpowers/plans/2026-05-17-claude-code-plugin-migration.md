# Claude Code Plugin Migration Implementation Plan (v3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop writing into `~/.claude/` from the Remarc app. Ship MCP, skill, and session-lifecycle hooks via a public Claude Code plugin marketplace at `metedata/remarc-agent-plugins`. Hooks are an optional second plugin that users must explicitly install — this honors "hooks off by default" without involving the app at all.

**Architecture:** New marketplace repo hosts two plugins. `remarc` (skill + stdio MCP server) is the required install. `remarc-hooks` (session-lifecycle orchestration) is the opt-in second install with `dependencies: ["remarc"]`. Both plugins share a `data.ts` source module via marketplace-relative symlinks (resolved at install time per the plugin docs). The Remarc macOS app deletes its `mcp/` directory, deletes its install code, and runs cleanup of legacy `~/.claude/` artifacts that retries on every launch until both the artifacts are gone AND the new plugin is detected installed.

**Tech Stack:** Swift 6 (Remarc.app), TypeScript + esbuild (bundled per plugin), Node 18+ (runtime), JSON manifests.

**Rollout:** Two phases gated by manual verification.
- **Phase A**: ship and verify the plugin repo (Tasks 1-7). Plugin must be installable from the public GitHub marketplace and exercised end-to-end on a real machine before Phase B starts.
- **Phase B**: ship the app changes (Tasks 8-16). The app should NOT be released to users until Phase A is verified — otherwise install commands in onboarding point at a missing integration.

**Revision history:**

_v1 → v2 (after first Codex review):_
- Hook script was a 30-line read-only summarizer; v2 ports the real orchestration from [mcp/src/cli.ts](mcp/src/cli.ts).
- Data path: `data.json` → `comments.json` with fallback.
- Comment field: `c.text` → `c.commentText` with `!isDeleted` filter.
- `PluginInstallDetector` uses `claude plugin list --json` instead of undocumented internal file.
- `LegacyInstallCleanup` traverses all hook events, matches by stable `REMARC_CLI_PATH` env-var marker, defensive failure handling.
- `remarc-hooks` declares `dependencies: ["remarc"]`.
- Prompt-submit regex narrowed.
- Shared modules via marketplace symlinks, JSON schema fixture for cross-language tests.

_v2 → v3 (after second Codex review):_
- **Task 5**: `import.meta.url` path guard fixed for paths with spaces (uses `fileURLToPath`), and `runHook` now wraps the whole switch in try/catch to enforce the "hooks degrade silently" contract.
- **New Task 8: extract `ProcessRunner` helper** before deleting MCPManager. Provides `runProcess` and `runProcessCapture` that Tasks 9 + 10 depend on. Without this, the deletion in Task 12 (was 11) is a compile blocker.
- **Task 10 (was 9)**: `removeRemarcHooksFromAllEvents()` fixed for mutation-during-iteration and silent-skip on inner-hook-removed-but-entry-not-fully-empty. Snapshots `Array(hooks.keys)`, tracks `changed` per inner-hook removal.
- **Task 10 (was 9)**: cleanup is no longer one-shot. `pluginMigrationCompleted` only set when cleanup verified AND `remarc` plugin is detected installed. Retries every launch until both true. This kills the rollout race where a user installs the plugin before upgrading the app.
- **Task 5**: added a unit test pinning the year-2000 marker mtime invariant (silently breakable otherwise).
- **Task 14 (was 13)**: added `plugins/shared/contracts.md` formalizing the `com.metepolat.Remarc` defaults keys the hook reads. Cross-repo coupling is now an explicit contract, not prose.
- **Task 7**: CI now exercises install-from-cache, not just `--plugin-dir` source-tree loading.

_Context7 verification (between v3 and v4):_
All doc-dependent claims were re-verified against `/websites/code_claude` Context7 docs:
- **Dependency syntax**: `"dependencies": ["remarc"]` (bare string) is the documented unversioned form; resolves within the same marketplace. ✓
- **Cross-marketplace deps**: blocked by default; would need `allowCrossMarketplaceDependenciesOn` if `remarc-hooks` and `remarc` were in different marketplaces. Both in same marketplace `remarc` — N/A. ✓
- **Auto-install of dependencies**: confirmed `/plugin install remarc-hooks@remarc` auto-installs `remarc` if not present.
- **Hook input shapes**: SessionStart input is `{ session_id, transcript_path, cwd, hook_event_name, source, model, agent_type? }` with `source: "startup" | "resume" | "clear" | "compact"`. UserPromptSubmit input is `{ session_id, transcript_path, cwd, permission_mode, hook_event_name, prompt }`. Plan matches. ✓
- **Hook output envelope**: `hookSpecificOutput.additionalContext` is the canonical structure for SessionStart (documented example). UserPromptSubmit decision control says `additionalContext` is allowed; same nested envelope works. `decision` field for UserPromptSubmit is top-level, but we don't use blocking — only `additionalContext`. ✓
- **`claude plugin list --json`**: documented, includes per-plugin `errors` field useful for surfacing `dependency-unsatisfied` etc.
- **Auto-installed dependency cleanup**: `claude plugin prune` or `--prune` flag on uninstall. Uninstalling the main `remarc` while `remarc-hooks` is installed leaves `remarc-hooks` in `dependency-unsatisfied` state — added to Task 16 verification.

_v3 → v4 (after third Codex review):_
- **Task 8 ProcessRunner**: `var collected` was racy between `readabilityHandler` (background pipe queue) and `terminationHandler`. Wrapped in `NSLock` — pipe reads append under lock, terminationHandler reads under lock. Swift 6 strict-concurrency-safe.
- **Task 10 `unregisterOldMCP()` infinite-loop bug**: v3 verified cleanup by checking that `claude mcp list` no longer contained `"mcp/dist/index.js"` — but the new plugin's `.mcp.json` also references `${CLAUDE_PLUGIN_ROOT}/mcp/dist/index.js`, so once the plugin installs that check ALWAYS returns false and `pluginMigrationCompleted` never sets. Initial v4 fix deleted the verify entirely (Codex flagged that as silent-failure masking). Iterated through three sub-fixes: (1) parse `claude mcp list` for bare `remarc:` line vs `plugin:<name>:remarc:` (verified against live CLI output), (2) caught that `runCapture` returning `""` on both empty-success AND on failure made a broken CLI look identical to a clean install — changed `runCapture` signature to `String?` (nil on timeout/nonzero/launch failure, "" only on success-with-no-output), and (3) updated both `unregisterOldMCP` and `PluginInstallDetector.read` to handle the nil case as "don't know, retry next launch" / "treat as not detected". Test coverage in Task 8 distinguishes all three outcomes (success with output, success empty, failure).
- **Task 15 contracts.md**: v3 claimed `comments-schema.json` carries `$id` + `version` fields but Task 2's schema is derived from current Swift/TS types which have no version field. Either claim must hold across all four artifacts (Swift, TS, schema, fixture) — it doesn't. Rewrote the contracts section to be honest: no schema version yet; schema-breaking changes require coordinated app + plugin release with manual cross-validation.
- **Task 7 CI**: `require('ajv')` had no `package.json` to install it. Added `plugins/shared/package.json` with Ajv as a dev dep and a `npm ci` step before the fixture decode.
- **Task 5 cleanup**: moved `fileURLToPath` import to the top of `hook.ts` with the other imports instead of being a patch-artifact inline import at the bottom.

---

## Key decisions (locked in)

1. **Two plugins in one marketplace.** `remarc` required; `remarc-hooks` opt-in with `dependencies: ["remarc"]`. This is the only way to make hooks truly off-by-default — `userConfig` can't conditionally remove hooks once a plugin is enabled.
2. **Stdio MCP transport.** Spec-recommended for local servers. No HTTP, no Origin validation, no bearer tokens.
3. **MCP server source moves to plugin repo.** App's `mcp/` directory is deleted entirely.
4. **`cli.ts` operations move to `remarc-hooks` plugin.** The MCP plugin doesn't need them — `tools.ts` already implements its own data-layer access for the MCP tools.
5. **Shared modules via marketplace symlinks.** `plugins/shared/data.ts` and `plugins/shared/notify.ts` are symlinked into both plugins' source trees. Per the [plugin docs](https://code.claude.com/docs/en/plugins-reference#share-files-within-a-marketplace-with-symlinks), symlinks within the same marketplace are dereferenced at install time (content is copied into the cache). esbuild also follows symlinks at build time, so this works for both dev (`--plugin-dir`) and production install.
6. **No `version` field on either plugin initially.** Every commit becomes a new version; switch to semver before public announcement.
7. **One-shot legacy cleanup is defensive.** Per-step success, atomic JSON writes with backup, advisory lock to handle parallel old/new app instances, only sets `pluginMigrationCompleted` flag after re-reading and confirming all three artifacts are gone.

---

## File map

### New repository: `metedata/remarc-agent-plugins`

```
metedata/remarc-agent-plugins/
├── .claude-plugin/marketplace.json
├── plugins/
│   ├── shared/                              # symlink targets, NOT a plugin
│   │   ├── data.ts                          # canonical data layer
│   │   ├── notify.ts                        # canonical reload notifier
│   │   └── comments-schema.json             # JSON schema for cross-language tests
│   ├── remarc/                              # required plugin
│   │   ├── .claude-plugin/plugin.json
│   │   ├── .mcp.json
│   │   ├── skills/remarc/SKILL.md
│   │   ├── mcp/
│   │   │   ├── package.json
│   │   │   ├── tsconfig.json
│   │   │   ├── src/
│   │   │   │   ├── index.ts                 # MCP entrypoint (from app mcp/src/)
│   │   │   │   ├── tools.ts                 # MCP tool registrations
│   │   │   │   ├── data.ts → ../../../shared/data.ts (symlink)
│   │   │   │   ├── notify.ts → ../../../shared/notify.ts (symlink)
│   │   │   │   └── data.test.ts             # ported tests
│   │   │   └── dist/index.js                # committed bundle
│   │   └── README.md
│   └── remarc-hooks/                        # optional plugin
│       ├── .claude-plugin/plugin.json       # declares dependencies: ["remarc"]
│       ├── hooks/hooks.json
│       ├── cli/
│       │   ├── package.json
│       │   ├── src/
│       │   │   ├── hook.ts                  # hook entrypoint (replaces shell scripts)
│       │   │   ├── operations.ts            # createSession/handoff/windDown (from cli.ts)
│       │   │   ├── marker.ts                # marker file logic
│       │   │   ├── defaults.ts              # macOS defaults shell-out
│       │   │   ├── data.ts → ../../../shared/data.ts (symlink)
│       │   │   ├── notify.ts → ../../../shared/notify.ts (symlink)
│       │   │   └── hook.test.ts             # vitest unit tests
│       │   └── dist/hook.js                 # committed bundle
│       └── README.md
├── .github/workflows/build.yml              # builds both dist/, validates, runs cross-lang fixtures
├── README.md
├── LICENSE
└── CHANGELOG.md
```

### Existing repo: `Remarc/` — deletes

- `mcp/` (entire directory)
- `scripts/hooks/` (entire directory)
- `app/RemarcPackage/Sources/RemarcFeature/Services/MCPManager.swift`
- `app/RemarcPackage/Sources/RemarcFeature/Services/ClaudeCodeManager.swift`
- `app/RemarcPackage/Sources/RemarcFeature/Utilities/SkillInstaller.swift`
- `app/RemarcPackage/Sources/RemarcFeature/Utilities/ScriptInstaller.swift`
- `app/RemarcPackage/Sources/RemarcFeature/Utilities/HarnessIntegrationManager.swift` (if present)

### Existing repo: `Remarc/` — modifies

- `app/RemarcPackage/Sources/RemarcFeature/AppController.swift` — drop install calls; add `LegacyInstallCleanup.runIfNeeded()`
- `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift` — replace MCP/hooks toggles with read-only plugin status panel
- `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift` — remove `mcpUserDisabled`, `claudeCodeEnabled`, `claudeCodeAutoCreateSession`; add `pluginMigrationCompleted`. Note: `claudeCodeAutoCreateSession` migrates to `defaults` directly (hook still reads it via `defaults read`) so user behavior survives — see Task 12.
- `CLAUDE.md` — remove install-related sections

### Existing repo: `Remarc/` — adds

- `app/RemarcPackage/Sources/RemarcFeature/Services/PluginInstallDetector.swift`
- `app/RemarcPackage/Sources/RemarcFeature/Services/LegacyInstallCleanup.swift`
- `app/RemarcPackage/Sources/RemarcFeature/Views/Onboarding/PluginInstallView.swift`
- `app/RemarcPackage/Tests/RemarcFeatureTests/PluginInstallDetectorTests.swift`
- `app/RemarcPackage/Tests/RemarcFeatureTests/LegacyInstallCleanupTests.swift`

---

## Tasks

### Task 1: Bootstrap the marketplace repo

**Files (in new repo):**
- Create: `.claude-plugin/marketplace.json`
- Create: `README.md`
- Create: `LICENSE`

`remarc` is not on the [reserved marketplace names list](https://code.claude.com/docs/en/plugin-marketplaces#reserved-marketplace-names).

- [ ] **Step 1: Create GitHub repo**

```bash
gh repo create metedata/remarc-agent-plugins --public \
  --description "Claude Code plugins for Remarc"
git clone git@github.com:metedata/remarc-agent-plugins
cd remarc-agent-plugins
mkdir -p .claude-plugin plugins/shared
```

- [ ] **Step 2: Write `.claude-plugin/marketplace.json`**

```json
{
  "$schema": "https://json.schemastore.org/claude-code-marketplace.json",
  "name": "remarc",
  "owner": { "name": "Mete Polat", "email": "metepolat.a@gmail.com" },
  "description": "Plugins for the Remarc macOS contextual commenting app.",
  "plugins": [
    {
      "name": "remarc",
      "source": "./plugins/remarc",
      "description": "Required: MCP server and skill for managing Remarc comments from Claude Code."
    },
    {
      "name": "remarc-hooks",
      "source": "./plugins/remarc-hooks",
      "description": "Optional, experimental: session-lifecycle hooks that auto-link Claude Code sessions to Remarc sessions and inject open comments on session start. Off by default - install only if you want automatic context injection."
    }
  ]
}
```

- [ ] **Step 3: Commit**

```bash
git add . && git commit -m "feat: scaffold marketplace with two plugin entries"
```

---

### Task 2: Create shared/ canonical source + schema fixture

**Files (in plugin repo):**
- Create: `plugins/shared/data.ts` (copy from app's `mcp/src/data.ts`, verbatim)
- Create: `plugins/shared/notify.ts` (copy from app's `mcp/src/notify.ts`, verbatim)
- Create: `plugins/shared/comments-schema.json` (JSON Schema for the canonical `comments.json` format)
- Create: `plugins/shared/fixtures/comments.sample.json` (representative `comments.json` for cross-decode tests)

The shared directory is **not a plugin** — it has no `.claude-plugin/`. Its files are referenced by the two real plugins via relative symlinks.

- [ ] **Step 1: Copy data.ts and notify.ts from app repo**

```bash
mkdir -p plugins/shared
cp ~/Developer/Remarc/mcp/src/data.ts    plugins/shared/data.ts
cp ~/Developer/Remarc/mcp/src/notify.ts  plugins/shared/notify.ts
```

- [ ] **Step 2: Generate JSON schema fixture + ajv install**

Manually write `plugins/shared/comments-schema.json` derived from the `AppState`, `Session`, `RawComment` interfaces in data.ts. Include the `commentText` field, the `status` enum, `isDeleted` boolean, the `type` discriminated union, and `sessionID` foreign key. ~50 lines.

Also create `plugins/shared/package.json` so CI can install Ajv for the fixture decode step (Task 7):

```json
{
  "name": "@metedata/remarc-shared",
  "version": "0.0.0",
  "private": true,
  "type": "commonjs",
  "devDependencies": {
    "ajv": "^8.17.0"
  }
}
```

```bash
cd plugins/shared && npm install --package-lock-only
```

(`--package-lock-only` generates the lockfile without writing `node_modules`; the actual install happens in CI.)

- [ ] **Step 3: Capture a real `comments.json` sample**

```bash
cp ~/Library/Application\ Support/Remarc/comments.json plugins/shared/fixtures/comments.sample.json
# Optional: scrub any user PII from the sample before committing
```

- [ ] **Step 4: Commit**

```bash
git add plugins/shared
git commit -m "feat(shared): canonical data layer + JSON schema fixture"
```

---

### Task 3: Author the `remarc` plugin (MCP + skill)

**Files (in plugin repo):**
- Create: `plugins/remarc/.claude-plugin/plugin.json`
- Create: `plugins/remarc/.mcp.json`
- Create: `plugins/remarc/skills/remarc/SKILL.md`
- Create: `plugins/remarc/mcp/package.json`, `tsconfig.json`, `src/`
- Symlinks: `plugins/remarc/mcp/src/data.ts → ../../../shared/data.ts`, same for notify.ts
- Create: `plugins/remarc/README.md`

- [ ] **Step 1: Plugin manifest** — `plugins/remarc/.claude-plugin/plugin.json`

```json
{
  "$schema": "https://json.schemastore.org/claude-code-plugin-manifest.json",
  "name": "remarc",
  "description": "Read, address, and resolve Remarc comments from Claude Code.",
  "author": { "name": "Mete Polat", "email": "metepolat.a@gmail.com" },
  "homepage": "https://remarc.app",
  "repository": "https://github.com/metedata/remarc-agent-plugins",
  "license": "MIT",
  "keywords": ["remarc", "comments", "macos", "code-review"]
}
```

- [ ] **Step 2: MCP config** — `plugins/remarc/.mcp.json`

```json
{
  "mcpServers": {
    "remarc": {
      "command": "node",
      "args": ["${CLAUDE_PLUGIN_ROOT}/mcp/dist/index.js"]
    }
  }
}
```

- [ ] **Step 3: Copy MCP source + skill from app repo**

```bash
mkdir -p plugins/remarc/mcp/src plugins/remarc/skills/remarc
cp ~/Developer/Remarc/mcp/src/index.ts   plugins/remarc/mcp/src/index.ts
cp ~/Developer/Remarc/mcp/src/tools.ts   plugins/remarc/mcp/src/tools.ts
cp ~/Developer/Remarc/mcp/src/data.test.ts plugins/remarc/mcp/src/data.test.ts
cp ~/Developer/Remarc/mcp/skill/SKILL.md plugins/remarc/skills/remarc/SKILL.md
cp ~/Developer/Remarc/mcp/tsconfig.json  plugins/remarc/mcp/tsconfig.json
```

- [ ] **Step 4: Create symlinks for shared modules**

```bash
cd plugins/remarc/mcp/src
ln -s ../../../shared/data.ts   data.ts
ln -s ../../../shared/notify.ts notify.ts
cd -
```

- [ ] **Step 5: Write `plugins/remarc/mcp/package.json`**

```json
{
  "name": "@metedata/remarc-mcp",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "esbuild src/index.ts --bundle --platform=node --target=node18 --format=esm --outfile=dist/index.js --banner:js=\"#!/usr/bin/env node\"",
    "test": "vitest run"
  },
  "dependencies": { "@modelcontextprotocol/sdk": "^1.12.0", "zod": "^3.25.0" },
  "devDependencies": { "@types/node": "^22.0.0", "esbuild": "^0.28.0", "typescript": "^5.7.0", "vitest": "^4.1.6" }
}
```

- [ ] **Step 6: Build, run tests, smoke-test plugin locally**

```bash
cd plugins/remarc/mcp && npm install && npm test && npm run build && cd ../../..
claude --plugin-dir ./plugins/remarc
# inside session:
/mcp
```

Expected: `remarc` MCP server listed and connected. Run `remarc_list_sessions` (via natural language) to verify reads work.

- [ ] **Step 7: Write `plugins/remarc/README.md` and commit**

```bash
git add plugins/remarc
git commit -m "feat(remarc): plugin manifest, MCP server, skill"
```

---

### Task 4: Port `cli.ts` operations into `remarc-hooks` plugin

**Files (in plugin repo):**
- Create: `plugins/remarc-hooks/cli/package.json`, `tsconfig.json`
- Create: `plugins/remarc-hooks/cli/src/operations.ts` (refactored from `mcp/src/cli.ts`)
- Symlinks for shared modules
- Create: `plugins/remarc-hooks/cli/src/marker.ts`
- Create: `plugins/remarc-hooks/cli/src/defaults.ts`

`operations.ts` exports pure async functions consumed by `hook.ts` (Task 5). No CLI argv parsing, no process.exit. Each function takes typed arguments, returns typed results.

- [ ] **Step 1: Set up cli/ directory and symlinks**

```bash
mkdir -p plugins/remarc-hooks/cli/src
cd plugins/remarc-hooks/cli/src
ln -s ../../../shared/data.ts   data.ts
ln -s ../../../shared/notify.ts notify.ts
cd -
```

- [ ] **Step 2: Write `plugins/remarc-hooks/cli/src/defaults.ts`**

```typescript
import { execFile } from "node:child_process";
import { promisify } from "node:util";
const execFileAsync = promisify(execFile);

export async function readBoolDefault(key: string): Promise<boolean | undefined> {
  try {
    const { stdout } = await execFileAsync("defaults", ["read", "com.metepolat.Remarc", key], { timeout: 3000 });
    const v = stdout.trim();
    if (v === "0" || v === "false") return false;
    if (v === "1" || v === "true") return true;
    return undefined;
  } catch { return undefined; }
}

export async function readStringDefault(key: string, fallback: string): Promise<string> {
  try {
    const { stdout } = await execFileAsync("defaults", ["read", "com.metepolat.Remarc", key], { timeout: 3000 });
    return stdout.trim();
  } catch { return fallback; }
}
```

- [ ] **Step 3: Write `plugins/remarc-hooks/cli/src/marker.ts`**

```typescript
import { writeFile, readFile, stat, unlink } from "node:fs/promises";
import { existsSync, statSync } from "node:fs";

export interface Marker { remarcSessionId: string; dataFilePath: string; }

const markerPath = (claudeSessionId: string) => `/tmp/remarc-claude-${claudeSessionId}.marker`;

export async function writeMarker(claudeSessionId: string, m: Marker): Promise<void> {
  const path = markerPath(claudeSessionId);
  await writeFile(path, `${m.remarcSessionId}\n${m.dataFilePath}\n`);
  // Touch backwards so file mtime < data file mtime, ensuring first prompt-submit fires
  const stamp = new Date("2000-01-01T00:00:00Z");
  await import("node:fs/promises").then(fs => fs.utimes(path, stamp, stamp));
}

export async function readMarker(claudeSessionId: string): Promise<Marker | null> {
  const path = markerPath(claudeSessionId);
  if (!existsSync(path)) return null;
  const content = await readFile(path, "utf8");
  const [remarcSessionId, dataFilePath] = content.split("\n");
  return remarcSessionId ? { remarcSessionId, dataFilePath: dataFilePath ?? "" } : null;
}

export async function touchMarker(claudeSessionId: string): Promise<void> {
  const path = markerPath(claudeSessionId);
  if (existsSync(path)) {
    const now = new Date();
    const fs = await import("node:fs/promises");
    await fs.utimes(path, now, now);
  }
}

export function dataNewerThanMarker(claudeSessionId: string, dataFilePath: string): boolean {
  const mp = markerPath(claudeSessionId);
  if (!existsSync(mp) || !existsSync(dataFilePath)) return false;
  return statSync(dataFilePath).mtimeMs > statSync(mp).mtimeMs;
}

export async function removeMarker(claudeSessionId: string): Promise<void> {
  try { await unlink(markerPath(claudeSessionId)); } catch { /* gone is fine */ }
}
```

- [ ] **Step 4: Refactor `mcp/src/cli.ts` into `plugins/remarc-hooks/cli/src/operations.ts`**

Strip argv parsing and CLI plumbing. Export the 4 operations as pure async functions:

```typescript
import { readAppState, writeAppState, getDataFilePath, applyStatusUpdate } from "./data.js";
import { notifyRemarcReload } from "./notify.js";
import { randomUUID } from "node:crypto";
import { readStringDefault } from "./defaults.js";
import type { Session, CommentStatus } from "./data.js";

const MAX_ACTIVE_SESSIONS = 8;

export interface CreateSessionInput { name: string; claudeSessionId: string; source: string; }
export interface CreateSessionResult { remarcSessionId: string; dataFilePath: string; }

export async function createSession(input: CreateSessionInput): Promise<CreateSessionResult> {
  // ... copy body of existing createSession() in cli.ts:65-160, but:
  //  - take input as typed arg instead of flags
  //  - return result instead of console.log
  //  - throw on error instead of process.exit
}

export async function handoff(input: { remarcSessionId: string; claudeSessionId: string; recovery: boolean }): Promise<string> {
  // ... copy body of existing handoff() in cli.ts:164-230, but return the formatted text instead of console.log
}

export async function windDown(input: { remarcSessionId: string }): Promise<void> {
  // ... copy body of existing windDown() in cli.ts:234-339
  // Replace inline `execSync("defaults read ...")` with `await readStringDefault("claudeCodeSessionEndBehavior", "autoDelete")`
}

export async function bulkSetStatus(input: { remarcSessionId: string; status: CommentStatus; summary?: string }): Promise<{ updated: number }> {
  // ... copy body of existing bulkSetStatus() in cli.ts:343-394
}
```

(Full bodies elided here — they're 1-to-1 ports of cli.ts. The execution agent uses cli.ts as the source of truth.)

- [ ] **Step 5: package.json for the cli bundle**

```json
{
  "name": "@metedata/remarc-hooks-cli",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "esbuild src/hook.ts --bundle --platform=node --target=node18 --format=esm --outfile=dist/hook.js --banner:js=\"#!/usr/bin/env node\"",
    "test": "vitest run"
  },
  "devDependencies": { "@types/node": "^22.0.0", "esbuild": "^0.28.0", "typescript": "^5.7.0", "vitest": "^4.1.6" }
}
```

(No `@modelcontextprotocol/sdk` dependency — this bundle never speaks MCP.)

- [ ] **Step 6: Commit**

```bash
git add plugins/remarc-hooks/cli/{package.json,tsconfig.json,src/operations.ts,src/marker.ts,src/defaults.ts,src/data.ts,src/notify.ts}
git commit -m "feat(remarc-hooks): port cli operations + marker/defaults helpers"
```

---

### Task 5: Write `hook.ts` orchestrator

**Files (in plugin repo):**
- Create: `plugins/remarc-hooks/cli/src/hook.ts`
- Create: `plugins/remarc-hooks/cli/src/hook.test.ts`

Single entrypoint that takes the event name as argv[2], reads the JSON event from stdin, orchestrates the operations, and emits the hook output envelope.

- [ ] **Step 1: Write failing test (sample test for session-start happy path)**

```typescript
// hook.test.ts
import { describe, it, expect, vi, beforeEach } from "vitest";

vi.mock("./operations.js", () => ({
  createSession: vi.fn(async () => ({ remarcSessionId: "ABC-123", dataFilePath: "/tmp/test-data.json" })),
  handoff:       vi.fn(async () => "## Remarc Comments (2 outstanding)\n..."),
  windDown:      vi.fn(async () => {}),
}));
vi.mock("./defaults.js", () => ({
  readBoolDefault: vi.fn(async () => true),
  readStringDefault: vi.fn(async () => "autoDelete"),
}));
vi.mock("./marker.js", () => ({
  writeMarker: vi.fn(), readMarker: vi.fn(async () => ({ remarcSessionId: "ABC-123", dataFilePath: "/tmp/d.json" })),
  touchMarker: vi.fn(), dataNewerThanMarker: vi.fn(() => true), removeMarker: vi.fn(),
}));

describe("hook session-start", () => {
  beforeEach(() => vi.clearAllMocks());

  it("startup: creates session, writes marker, emits additionalContext", async () => {
    const input = JSON.stringify({ source: "startup", session_id: "claude-abc", cwd: "/Users/m/proj" });
    const { runHook } = await import("./hook.js");
    const output = await runHook("session-start", input);

    expect(JSON.parse(output)).toEqual({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: expect.stringContaining("Remarc Comments"),
      }
    });
  });

  it("startup with auto-create disabled: emits empty object, no session created", async () => {
    const { readBoolDefault } = await import("./defaults.js");
    vi.mocked(readBoolDefault).mockResolvedValueOnce(false);
    const input = JSON.stringify({ source: "startup", session_id: "claude-abc", cwd: "/Users/m/proj" });
    const { runHook } = await import("./hook.js");
    const output = await runHook("session-start", input);

    expect(JSON.parse(output)).toEqual({});
    const { createSession } = await import("./operations.js");
    expect(createSession).not.toHaveBeenCalled();
  });

  it("subagent invocations are skipped", async () => {
    const input = JSON.stringify({ source: "startup", session_id: "claude-abc", agent_type: "Explore" });
    const { runHook } = await import("./hook.js");
    const output = await runHook("session-start", input);
    expect(JSON.parse(output)).toEqual({});
  });

  it("errors thrown by operations degrade to {} (silent fail contract)", async () => {
    const { handoff } = await import("./operations.js");
    vi.mocked(handoff).mockRejectedValueOnce(new Error("simulated data layer failure"));
    const input = JSON.stringify({ source: "startup", session_id: "claude-abc", cwd: "/Users/m/proj" });
    const { runHook } = await import("./hook.js");
    const output = await runHook("session-start", input);
    expect(JSON.parse(output)).toEqual({});
  });
});

describe("marker", () => {
  it("writeMarker sets mtime in the past so first prompt-submit fires", async () => {
    // Pins the non-obvious year-2000 mtime invariant. If someone changes writeMarker
    // to use `now`, this test breaks loudly. Without it, the first prompt-submit
    // would silently no-op for any session created after data.json was last touched.
    const { writeMarker } = await import("./marker.js");
    const { statSync } = await import("node:fs");
    const sessionId = `test-${Date.now()}`;
    await writeMarker(sessionId, { remarcSessionId: "abc", dataFilePath: "/tmp/x.json" });
    const path = `/tmp/remarc-claude-${sessionId}.marker`;
    const stat = statSync(path);
    expect(stat.mtimeMs).toBeLessThan(Date.now() - 365 * 24 * 60 * 60 * 1000);
  });
});
```

Run: `npm test` → expect FAIL (runHook not defined).

- [ ] **Step 2: Implement `hook.ts`**

```typescript
#!/usr/bin/env node
import { basename } from "node:path";
import { fileURLToPath } from "node:url";
import { createSession, handoff, windDown } from "./operations.js";
import { readBoolDefault } from "./defaults.js";
import { writeMarker, readMarker, touchMarker, dataNewerThanMarker, removeMarker } from "./marker.js";

type Envelope = Record<string, unknown>;

export async function runHook(event: string, rawInput: string): Promise<string> {
  // Enforce the "hooks degrade silently" contract (Codex v2 review): if anything
  // inside the orchestration throws — createSession, handoff, marker IO, defaults
  // shell-out — we emit `{}` so Claude Code continues without injection rather than
  // surfacing a nonzero exit and a stderr trace in the user's session.
  try {
    let input: any;
    try { input = JSON.parse(rawInput || "{}"); }
    catch { return "{}"; }

    switch (event) {
      case "session-start": return JSON.stringify(await onSessionStart(input));
      case "prompt-submit": return JSON.stringify(await onPromptSubmit(input));
      case "session-end":   return JSON.stringify(await onSessionEnd(input));
      default: return "{}";
    }
  } catch (err) {
    process.stderr.write(`remarc-hooks: ${event} failed: ${err instanceof Error ? err.message : String(err)}\n`);
    return "{}";
  }
}

async function onSessionStart(input: { source: string; session_id: string; cwd?: string; agent_type?: string }): Promise<Envelope> {
  if (input.agent_type || !input.session_id) return {};
  const source = input.source ?? "startup";

  if (source === "startup" || source === "resume") {
    const autoCreate = await readBoolDefault("claudeCodeAutoCreateSession");
    if (autoCreate === false) return {};

    const name = basename(input.cwd ?? process.cwd()) || "Session";
    const result = await createSession({ name, claudeSessionId: input.session_id, source });
    await writeMarker(input.session_id, { remarcSessionId: result.remarcSessionId, dataFilePath: result.dataFilePath });
    const context = await handoff({ remarcSessionId: result.remarcSessionId, claudeSessionId: input.session_id, recovery: true });
    return wrap("SessionStart", context);
  }

  if (source === "compact" || source === "clear") {
    const marker = await readMarker(input.session_id);
    if (!marker) return {};
    const context = await handoff({ remarcSessionId: marker.remarcSessionId, claudeSessionId: input.session_id, recovery: true });
    return wrap("SessionStart", context);
  }

  return {};
}

async function onPromptSubmit(input: { session_id: string; prompt?: string }): Promise<Envelope> {
  if (!input.session_id) return {};
  const marker = await readMarker(input.session_id);
  if (!marker) return {};

  // Narrow prompt-relevance filter (Codex feedback): word boundaries, not bare 'comment'
  const prompt = input.prompt ?? "";
  const hintMatches = /\bremarc\b|\bmy comments?\b|\bopen comments?\b/i.test(prompt);

  // Always-injection logic: incremental handoff if data file changed since last touch
  if (!dataNewerThanMarker(input.session_id, marker.dataFilePath) && !hintMatches) return {};

  const context = await handoff({ remarcSessionId: marker.remarcSessionId, claudeSessionId: input.session_id, recovery: false });
  await touchMarker(input.session_id);
  if (!context) return {};
  return wrap("UserPromptSubmit", context);
}

async function onSessionEnd(input: { session_id: string }): Promise<Envelope> {
  if (!input.session_id) return {};
  const marker = await readMarker(input.session_id);
  if (!marker) return {};
  try { await windDown({ remarcSessionId: marker.remarcSessionId }); } catch { /* swallow */ }
  await removeMarker(input.session_id);
  return {};
}

function wrap(eventName: string, additionalContext: string): Envelope {
  if (!additionalContext) return {};
  return { hookSpecificOutput: { hookEventName: eventName, additionalContext } };
}

// CLI entrypoint. fileURLToPath imported at top of file. Use it instead of
// string-comparing `import.meta.url` to `file://${process.argv[1]}` — the former
// percent-encodes spaces while the latter doesn't, so the naive comparison
// silently never matches on paths with spaces (Codex v2 review).
if (fileURLToPath(import.meta.url) === process.argv[1]) {
  const event = process.argv[2] ?? "";
  let raw = "";
  process.stdin.setEncoding("utf8");
  for await (const chunk of process.stdin) raw += chunk;
  const out = await runHook(event, raw);
  if (out !== "{}") process.stdout.write(out);
  process.exit(0);
}
```

- [ ] **Step 3: Run tests, expect PASS**

```bash
cd plugins/remarc-hooks/cli && npm install && npm test
```

- [ ] **Step 4: Build the bundle**

```bash
npm run build && cd ../../..
```

- [ ] **Step 5: Commit**

```bash
git add plugins/remarc-hooks/cli/src/hook.ts plugins/remarc-hooks/cli/src/hook.test.ts plugins/remarc-hooks/cli/dist
git commit -m "feat(remarc-hooks): hook orchestrator with vitest coverage"
```

---

### Task 6: Author `remarc-hooks` plugin manifest and hooks.json

**Files (in plugin repo):**
- Create: `plugins/remarc-hooks/.claude-plugin/plugin.json`
- Create: `plugins/remarc-hooks/hooks/hooks.json`
- Create: `plugins/remarc-hooks/README.md`

- [ ] **Step 1: Plugin manifest with dependency**

```json
{
  "$schema": "https://json.schemastore.org/claude-code-plugin-manifest.json",
  "name": "remarc-hooks",
  "description": "EXPERIMENTAL session-lifecycle hooks for Remarc. Auto-creates a Remarc session linked to each Claude Code session and injects open comments on session start. Install only if you want automatic context injection.",
  "author": { "name": "Mete Polat", "email": "metepolat.a@gmail.com" },
  "homepage": "https://remarc.app",
  "repository": "https://github.com/metedata/remarc-agent-plugins",
  "license": "MIT",
  "keywords": ["remarc", "hooks", "experimental"],
  "dependencies": ["remarc"]
}
```

The `dependencies` field tells Claude Code that `remarc-hooks` requires `remarc`. Per [the dependencies docs](https://code.claude.com/docs/en/plugin-dependencies), installing `remarc-hooks` will prompt to also install `remarc` if not already present.

- [ ] **Step 2: hooks.json — exec form, `${CLAUDE_PLUGIN_ROOT}` paths**

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|compact|clear",
        "hooks": [
          {
            "type": "command",
            "command": "node",
            "args": ["${CLAUDE_PLUGIN_ROOT}/cli/dist/hook.js", "session-start"],
            "timeout": 10
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node",
            "args": ["${CLAUDE_PLUGIN_ROOT}/cli/dist/hook.js", "prompt-submit"],
            "timeout": 10
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node",
            "args": ["${CLAUDE_PLUGIN_ROOT}/cli/dist/hook.js", "session-end"],
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

Exec form (`command` + `args` array) is preferred per the [hooks reference](https://code.claude.com/docs/en/hooks#exec-form-and-shell-form) — no shell quoting needed for paths with spaces. Matcher includes `compact|clear` so context re-injection works after `/clear` or auto-compact.

- [ ] **Step 3: Plugin README**

````markdown
# remarc-hooks (experimental)

Optional session-lifecycle hooks for [Remarc](https://remarc.app). Off by default — installing this plugin is your explicit opt-in.

## What it does

- **SessionStart**: creates a Remarc session linked to the Claude Code session (named after `cwd`), injects outstanding comments as `additionalContext`.
- **UserPromptSubmit**: incremental handoff — if the Remarc data file changed since the last hook fire, injects new comments. Also fires when your prompt mentions "remarc" or "my comments".
- **SessionEnd**: runs the user-configured wind-down (auto-delete the linked session, keep it, or move unresolved comments to Inbox).

## Install

```sh
/plugin marketplace add metedata/remarc-agent-plugins
/plugin install remarc-hooks@remarc
```

Installs the `remarc` plugin too if not already present.

## Uninstall

```sh
/plugin uninstall remarc-hooks@remarc
```

Hooks are removed immediately. The `remarc` plugin stays installed unless you also `/plugin uninstall remarc@remarc`.

## What it does NOT do

- Does not work on Linux/Windows (shell-outs to macOS `defaults`).
- Does not start the Remarc.app process. If Remarc isn't running, hooks degrade to no-op silently.
````

- [ ] **Step 4: Local smoke test**

```bash
claude --plugin-dir ./plugins/remarc --plugin-dir ./plugins/remarc-hooks
# In session:
/hooks
```

Expected: 3 hooks shown under `remarc-hooks` plugin source.

- [ ] **Step 5: Commit**

```bash
git add plugins/remarc-hooks/.claude-plugin plugins/remarc-hooks/hooks plugins/remarc-hooks/README.md
git commit -m "feat(remarc-hooks): plugin manifest + hooks.json + README"
```

---

### Task 7: CI workflow (build + cross-decode fixture test + plugin validate)

**Files (in plugin repo):**
- Create: `.github/workflows/build.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: build
on: [push, pull_request]
jobs:
  build:
    runs-on: macos-latest   # to test the `defaults` shell-out path
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "22" }

      - name: build + test remarc MCP
        working-directory: plugins/remarc/mcp
        run: npm ci && npm test && npm run build

      - name: build + test remarc-hooks CLI
        working-directory: plugins/remarc-hooks/cli
        run: npm ci && npm test && npm run build

      - name: verify committed dist/ matches build output
        run: |
          if ! git diff --exit-code plugins/remarc/mcp/dist plugins/remarc-hooks/cli/dist; then
            echo "ERROR: dist/ is out of date. Run 'npm run build' in each bundle and commit."
            exit 1
          fi

      - name: install Claude Code and validate marketplace
        run: |
          curl -fsSL https://claude.ai/install.sh | bash
          export PATH="$HOME/.local/bin:$PATH"
          claude plugin validate .

      - name: exercise install-from-cache path
        # Codex v2 strong suggestion: --plugin-dir loads from the source tree, which
        # preserves symlinks differently than the cached install path (per the
        # plugin docs). To catch symlink-resolution bugs that only show up on real
        # installs, do a full `marketplace add` + `install` + smoke-invoke flow.
        run: |
          export PATH="$HOME/.local/bin:$PATH"
          # Add this checkout as a local marketplace
          claude plugin marketplace add "$GITHUB_WORKSPACE"
          claude plugin install remarc@remarc
          claude plugin install remarc-hooks@remarc
          # Confirm both bundles are present in the cache and the symlinked
          # data.ts was dereferenced into a real file
          test -f "$HOME/.claude/plugins/cache/remarc/remarc/"*"/mcp/dist/index.js"
          test -f "$HOME/.claude/plugins/cache/remarc/remarc-hooks/"*"/cli/dist/hook.js"
          # Smoke-invoke the hook bundle with a synthetic session-start event
          echo '{"source":"startup","session_id":"ci-test","cwd":"/tmp"}' \
            | node "$HOME/.claude/plugins/cache/remarc/remarc-hooks/"*"/cli/dist/hook.js" session-start
          # (exit 0 means no thrown errors; on macOS-less Linux runner, the
          # `defaults` shell-out fails inside the bundle which the silent-fail
          # contract catches — we're verifying the bundle is invokable, not the
          # full macOS flow)

      - name: install ajv for fixture validation
        # v3 referenced require('ajv') with no install path — broken in CI (Codex v3 review).
        # plugins/shared/package.json declares ajv as a dev dep; `npm ci` here makes
        # it available to the next step.
        working-directory: plugins/shared
        run: npm ci

      - name: cross-decode schema fixture
        working-directory: plugins/shared
        run: |
          node -e "
            const sample = require('./fixtures/comments.sample.json');
            const Ajv = require('ajv').default;
            const schema = require('./comments-schema.json');
            const ajv = new Ajv({ allowUnionTypes: true });
            const valid = ajv.validate(schema, sample);
            if (!valid) { console.error(ajv.errors); process.exit(1); }
          " || (echo 'TS decode failed' && exit 1)
          # Swift side runs in the app repo's CI — see Task 11
```

- [ ] **Step 2: Commit and push**

```bash
git add .github && git commit -m "ci: build, validate, fixture cross-decode" && git push -u origin main
```

Expected: green CI run.

---

### Task 8: Extract `ProcessRunner` helper (NEW in v3)

**Files (in app repo):**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Utilities/ProcessRunner.swift`
- Test: `app/RemarcPackage/Tests/RemarcFeatureTests/ProcessRunnerTests.swift`

Codex v2 review caught this: `runProcess` is currently private inside `MCPManager.swift`, and `runProcessCapture` doesn't exist at all. Tasks 9 and 10 both call these. Without extracting them first, deleting `MCPManager.swift` in Task 12 is a compile blocker.

- [ ] **Step 1: Write failing test for runProcessCapture timeout behavior**

```swift
import XCTest
@testable import RemarcFeature

final class ProcessRunnerTests: XCTestCase {
    func testRunProcessCaptureReturnsStdout() async throws {
        let output = await ProcessRunner.runCapture("/bin/echo", arguments: ["hello world"], timeoutSeconds: 2)
        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testRunProcessCaptureTimesOutGracefully() async throws {
        let start = Date()
        let output = await ProcessRunner.runCapture("/bin/sleep", arguments: ["10"], timeoutSeconds: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0)  // killed near the timeout
        XCTAssertNil(output)              // nil on timeout, NOT empty string
    }

    func testRunProcessCaptureReturnsEmptyStringOnSuccessfulEmptyOutput() async throws {
        let output = await ProcessRunner.runCapture("/usr/bin/true", arguments: [], timeoutSeconds: 2)
        // /usr/bin/true exits 0 with no stdout — that's an empty string, not nil
        XCTAssertEqual(output, "")
    }

    func testRunProcessCaptureReturnsNilOnNonzeroExit() async throws {
        let output = await ProcessRunner.runCapture("/usr/bin/false", arguments: [], timeoutSeconds: 2)
        XCTAssertNil(output)
    }

    func testRunProcessReturnsTrueOnZeroExit() async throws {
        let success = await ProcessRunner.run("/usr/bin/true", arguments: [])
        XCTAssertTrue(success)
    }

    func testRunProcessReturnsFalseOnNonzeroExit() async throws {
        let success = await ProcessRunner.run("/usr/bin/false", arguments: [])
        XCTAssertFalse(success)
    }
}
```

Run: expect FAIL — `ProcessRunner` not defined.

- [ ] **Step 2: Implement `ProcessRunner.swift`**

```swift
import Foundation

/// Shared Process + Pipe helper. Replaces the private helpers that used to live
/// inside MCPManager.swift, plus a new capturing variant for parsing CLI output.
public enum ProcessRunner {
    /// Run a process, return true on exit-0. Stdout/stderr discarded.
    public static func run(_ executablePath: String, arguments: [String]) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executablePath)
            p.arguments = arguments
            p.standardOutput = Pipe()
            p.standardError  = Pipe()
            p.terminationHandler = { proc in
                cont.resume(returning: proc.terminationStatus == 0)
            }
            do { try p.run() } catch { cont.resume(returning: false) }
        }
    }

    /// Run a process, capture stdout as a UTF-8 string. Returns nil on timeout,
    /// nonzero exit, or launch failure. Empty string is reserved for the legitimate
    /// case where the command ran successfully and produced no output — distinguishing
    /// these two outcomes matters for callers that gate behavior on the captured
    /// content (e.g., LegacyInstallCleanup needs to retry next launch if the list
    /// command itself failed, not assume "clean").
    public static func runCapture(_ executablePath: String, arguments: [String], timeoutSeconds: Double) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let p = Process()
            let pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: executablePath)
            p.arguments = arguments
            p.standardOutput = pipe
            p.standardError  = Pipe()

            // The pipe's readabilityHandler fires on a background queue while
            // terminationHandler fires when the process exits. Both touch
            // `collected`. Without a lock this is a data race (caught by Swift 6
            // strict concurrency) — Codex v3 review.
            let lock = NSLock()
            var collected = Data()
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                guard !chunk.isEmpty else { return }
                lock.lock()
                collected.append(chunk)
                lock.unlock()
            }

            // Timeout watchdog.
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if p.isRunning { p.terminate() }
            }

            p.terminationHandler = { proc in
                handle.readabilityHandler = nil
                timeoutTask.cancel()
                // Final drain — anything written between the last readability
                // tick and the process exit. availableData returns immediately
                // when the pipe is at EOF, so this is bounded.
                let tail = handle.availableData
                lock.lock()
                if !tail.isEmpty { collected.append(tail) }
                let snapshot = collected
                lock.unlock()

                if proc.terminationStatus == 0,
                   let s = String(data: snapshot, encoding: .utf8) {
                    cont.resume(returning: s)
                } else {
                    cont.resume(returning: nil)  // nonzero exit OR decode failure
                }
            }

            do { try p.run() } catch {
                timeoutTask.cancel()
                cont.resume(returning: nil)  // failed to launch
            }
        }
    }
}
```

- [ ] **Step 3: Run tests, expect PASS**

```bash
cd app && xcodebuild test -workspace Remarc.xcworkspace -scheme Remarc -only-testing:RemarcFeatureTests/ProcessRunnerTests
```

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(plugin): extract ProcessRunner helper before MCPManager deletion"
```

This MUST land before Task 12. Tasks 9 and 10 call `ProcessRunner.run`/`runCapture` directly.

---

### Task 9: `PluginInstallDetector` using `claude plugin list --json`

**Files (in app repo):**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/PluginInstallDetector.swift`
- Test: `app/RemarcPackage/Tests/RemarcFeatureTests/PluginInstallDetectorTests.swift`

Per Codex's blocker: use the documented CLI surface (`claude plugin list --json`), not the undocumented `installed_plugins.json` file.

- [ ] **Step 1: Test that asserts shell-out, fallback, parsing**

```swift
import XCTest
@testable import RemarcFeature

final class PluginInstallDetectorTests: XCTestCase {
    func testParsesPluginListJSONOutput() throws {
        // Sample shape from `claude plugin list --json` (verify against actual CLI output during impl)
        let sample = """
        [
          { "name": "remarc",       "marketplace": "remarc", "enabled": true,  "scope": "user" },
          { "name": "remarc-hooks", "marketplace": "remarc", "enabled": false, "scope": "user" },
          { "name": "other",        "marketplace": "x",      "enabled": true,  "scope": "user" }
        ]
        """.data(using: .utf8)!

        let state = try PluginInstallDetector.parse(jsonOutput: sample)
        XCTAssertTrue(state.remarcInstalled)
        XCTAssertTrue(state.remarcHooksInstalled)
        XCTAssertFalse(state.remarcHooksEnabled)
    }

    func testReturnsAllFalseOnInvalidJSON() throws {
        let state = try PluginInstallDetector.parse(jsonOutput: Data("not json".utf8))
        XCTAssertFalse(state.remarcInstalled)
        XCTAssertFalse(state.remarcHooksInstalled)
    }
}
```

Run: expect FAIL.

- [ ] **Step 2: Implement**

```swift
import Foundation

public struct PluginInstallState: Equatable {
    public let remarcInstalled: Bool
    public let remarcHooksInstalled: Bool
    public let remarcHooksEnabled: Bool
}

public final class PluginInstallDetector {
    public init() {}

    /// Public for testing.
    public static func parse(jsonOutput: Data) throws -> PluginInstallState {
        guard let array = (try? JSONSerialization.jsonObject(with: jsonOutput)) as? [[String: Any]] else {
            return PluginInstallState(remarcInstalled: false, remarcHooksInstalled: false, remarcHooksEnabled: false)
        }
        let matches = array.filter { ($0["marketplace"] as? String) == "remarc" }
        let remarc      = matches.first { ($0["name"] as? String) == "remarc" }
        let remarcHooks = matches.first { ($0["name"] as? String) == "remarc-hooks" }
        return PluginInstallState(
            remarcInstalled:      remarc != nil,
            remarcHooksInstalled: remarcHooks != nil,
            remarcHooksEnabled:   (remarcHooks?["enabled"] as? Bool) ?? false
        )
    }

    public func read() async -> PluginInstallState {
        let zero = PluginInstallState(remarcInstalled: false, remarcHooksInstalled: false, remarcHooksEnabled: false)
        guard let claude = await ShellResolver.resolveBinaryPath("claude") else { return zero }
        // nil means the command didn't succeed — treat as "unknown / not detected".
        // Callers gate destructive actions on positive detection, so the safe default
        // is to report all-false here.
        guard let output = await ProcessRunner.runCapture(claude, arguments: ["plugin", "list", "--json"], timeoutSeconds: 5),
              let data = output.data(using: .utf8), !data.isEmpty else { return zero }
        return (try? Self.parse(jsonOutput: data)) ?? zero
    }
}
```

`ProcessRunner` comes from Task 8.

- [ ] **Step 3: Run tests, expect PASS, commit**

---

### Task 10: `LegacyInstallCleanup` (defensive, retries until plugin installed + clean)

**Files (in app repo):**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/LegacyInstallCleanup.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift` — add `pluginMigrationCompleted: Bool`
- Test: `app/RemarcPackage/Tests/RemarcFeatureTests/LegacyInstallCleanupTests.swift`

Addresses Codex blockers 3 + 4. Per-step success tracking, traverse all hook events, match by `REMARC_CLI_PATH` env-var marker, advisory lock for parallel-app races, only set the one-shot flag after re-reading and confirming the artifacts are gone.

- [ ] **Step 1: Failing tests for each cleanup step + idempotency**

```swift
final class LegacyInstallCleanupTests: XCTestCase {
    func testRemovesOldSkillFile() throws { /* setup file, run, assert gone */ }

    func testRemovesRemarcHooksFromAllEventTypes() throws {
        // Settings.json contains Remarc hooks under SessionStart AND PostToolUse (simulating bug-induced misplacement)
        // Both must be removed; non-Remarc hooks must survive
    }

    func testToleratesUnparseableSettingsJSON() throws {
        // settings.json has trailing commas (JSONC-ish, common manual edit)
        // Cleanup should NOT crash, NOT touch the file, and NOT set the migration flag
    }

    func testDoesNotSetFlagIfAnyStepFailed() throws {
        // Mock the MCP remove to fail
        // After runIfNeeded: flag still false; next run should retry
    }

    func testIsIdempotentAfterSuccessfulRun() throws {
        // First run: artifacts removed, flag set
        // Second run: short-circuits without doing work
    }
}
```

- [ ] **Step 2: Implement `LegacyInstallCleanup.swift`**

```swift
import Foundation

@MainActor
public final class LegacyInstallCleanup {
    public static let shared = LegacyInstallCleanup()

    private static let lockPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.remarc-migration.lock")

    public func runIfNeeded() async {
        guard !SettingsManager.shared.pluginMigrationCompleted else { return }

        // Acquire advisory lock to handle "old app and new app both launched" race.
        guard acquireLock() else {
            debugLog("LegacyInstallCleanup: another instance holds the lock — retry next launch")
            return
        }
        defer { releaseLock() }

        let skillOK = removeOldSkillFile()
        let hooksOK = removeRemarcHooksFromAllEvents()
        let mcpOK   = await unregisterOldMCP()

        // The one-shot flag is set only when cleanup verified AND the new plugin
        // is detected installed. This kills the v2 race where a user installs
        // remarc-hooks BEFORE upgrading the app: in that interval, the old
        // settings.json hooks coexist with the plugin hooks, causing duplicate
        // session creation and double context injection. By retrying every launch
        // until both conditions hold, the migration self-heals as soon as the
        // plugin appears. (Codex v2 review.)
        let pluginState = await PluginInstallDetector().read()
        let isClean = skillOK && hooksOK && mcpOK && verifyClean()

        if isClean && pluginState.remarcInstalled {
            SettingsManager.shared.pluginMigrationCompleted = true
            debugLog("LegacyInstallCleanup: complete, verified, plugin detected — flag set")
        } else {
            debugLog("LegacyInstallCleanup: not yet final (clean=\(isClean) pluginInstalled=\(pluginState.remarcInstalled)) — will retry next launch")
        }
    }

    // MARK: Cleanup steps

    private func removeOldSkillFile() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/remarc/SKILL.md")
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do { try FileManager.default.removeItem(at: url); return true }
        catch { debugLog("removeOldSkillFile failed: \(error)"); return false }
    }

    private func removeRemarcHooksFromAllEvents() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return true }

        // Defensive read — bail out cleanly on JSONC / corrupt input
        guard let data  = try? Data(contentsOf: url),
              let root  = try? JSONSerialization.jsonObject(with: data),
              var settings = root as? [String: Any]
        else {
            debugLog("removeRemarcHooks: settings.json unparseable, leaving untouched")
            return false  // not OK — cleanup didn't complete
        }

        guard var hooks = settings["hooks"] as? [String: Any] else { return true }
        var changed = false

        // Snapshot keys to avoid mutation-during-iteration (Codex v2). Also track
        // `changed` per inner-hook removal — the v2 version only flagged changes
        // when an entry was fully dropped, missing the case where one Remarc inner
        // hook was removed but the entry kept others. That edit would be computed
        // but never persisted.
        for eventName in Array(hooks.keys) {
            guard var entries = hooks[eventName] as? [[String: Any]] else { continue }
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
                    // entry fully drained, drop it
                    continue
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
            // Restore from backup
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(at: backupURL, to: url)
            return false
        }
    }

    /// Match by stable markers: env var the old install always set, or path substring of the old install layout.
    private func isRemarcHook(_ hook: [String: Any]) -> Bool {
        let command = (hook["command"] as? String) ?? ""
        // Old install always shelled with REMARC_CLI_PATH= ... 'scripts/hooks/remarc-*.sh'
        if command.contains("REMARC_CLI_PATH=") { return true }
        if command.contains("scripts/hooks/remarc-") { return true }
        // Also check args[] for exec-form hooks
        if let args = hook["args"] as? [String] {
            return args.contains(where: { $0.contains("scripts/hooks/remarc-") || $0.contains("remarc-cli") })
        }
        return false
    }

    private func unregisterOldMCP() async -> Bool {
        guard let claude = await ShellResolver.resolveBinaryPath("claude") else { return true }  // can't tell, treat as OK

        // Codex v4 caught: v3 grepped `claude mcp list` for "mcp/dist/index.js"
        // and got stuck because the new plugin's .mcp.json also matches → infinite
        // loop. v4 then went too far and always returned true → silent-success on
        // real `claude mcp remove` failures.
        //
        // Correct distinguisher (verified against actual `claude mcp list` output):
        // plugin-provided MCPs appear with a "plugin:<plugin-name>:<server-name>:"
        // prefix, while user-scoped (legacy `add-json`) appears as bare "remarc:".
        // We parse for the bare form, only attempt removal if it's actually there,
        // and return the exit code of the removal.
        // Codex's fifth-pass concern: `runCapture` previously returned "" on both
        // success-with-empty-output AND on failure (timeout, nonzero exit, launch
        // failure). That conflation made a broken `claude` CLI indistinguishable
        // from a clean install, silently allowing pluginMigrationCompleted to set
        // when the cleanup never actually ran. `runCapture` now returns nil on
        // failure; we propagate that as "don't know, retry next launch".
        guard let listOutput = await ProcessRunner.runCapture(claude, arguments: ["mcp", "list"], timeoutSeconds: 5) else {
            debugLog("LegacyInstallCleanup: `claude mcp list` failed — retry next launch")
            return false
        }

        let hasLegacy = listOutput.split(separator: "\n").contains { line in
            // Match exact bare "remarc:" prefix at line start. The plugin-provided
            // form would start with "plugin:remarc:remarc:" or similar and won't
            // match this. Tolerate optional leading whitespace.
            line.trimmingCharacters(in: .whitespaces).hasPrefix("remarc:")
        }

        if !hasLegacy {
            // Nothing legacy to remove (fresh install, or previous cleanup succeeded).
            return true
        }

        // Legacy registration is actually present. Return the actual exit code
        // of the removal so silent failures don't get masked.
        return await ProcessRunner.run(claude, arguments: ["mcp", "remove", "--scope", "user", "remarc"])
    }

    /// Re-read everything and confirm we're clean. Belt-and-suspenders.
    private func verifyClean() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills/remarc/SKILL.md")
        if FileManager.default.fileExists(atPath: url.path) { return false }

        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        if FileManager.default.fileExists(atPath: settingsURL.path),
           let data = try? Data(contentsOf: settingsURL),
           let s = String(data: data, encoding: .utf8),
           s.contains("REMARC_CLI_PATH") || s.contains("scripts/hooks/remarc-") {
            return false
        }
        return true
    }

    // MARK: Advisory lock

    private func acquireLock() -> Bool {
        let path = Self.lockPath.path
        try? FileManager.default.createDirectory(at: Self.lockPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        // Non-blocking exclusive lock
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        Self.lockFD = fd
        return true
    }

    private func releaseLock() {
        if let fd = Self.lockFD { flock(fd, LOCK_UN); close(fd); Self.lockFD = nil }
        try? FileManager.default.removeItem(at: Self.lockPath)
    }

    private static var lockFD: Int32?
}
```

- [ ] **Step 3: Run tests, expect PASS, commit**

```bash
git commit -m "feat(plugin): legacy install cleanup with verification, advisory lock, JSONC tolerance"
```

---

### Task 11: Add Swift cross-decode test against the shared fixture

**Files (in app repo):**
- Create: `app/RemarcPackage/Tests/RemarcFeatureTests/CommentsSchemaFixtureTests.swift`
- Add submodule or git LFS fetch of `plugins/shared/fixtures/comments.sample.json` (or vendor a copy)

Codex's strong suggestion: prove the Swift app and the plugin's TypeScript both decode the same fixture. Catches schema drift at CI time.

- [ ] **Step 1: Vendor the sample**

```bash
mkdir -p app/RemarcPackage/Tests/Fixtures
curl -fsSL https://raw.githubusercontent.com/metedata/remarc-agent-plugins/main/plugins/shared/fixtures/comments.sample.json \
  -o app/RemarcPackage/Tests/Fixtures/comments.sample.json
```

(Or git submodule if we want auto-updates.)

- [ ] **Step 2: Write Swift decode test**

```swift
func testCommentsSampleDecodesAgainstAppState() throws {
    let url = Bundle.module.url(forResource: "comments.sample", withExtension: "json")!
    let data = try Data(contentsOf: url)
    let state = try JSONDecoder.remarc.decode(AppState.self, from: data)
    XCTAssertGreaterThan(state.comments.count, 0)
    // Pin a field that v1 of this plan got wrong: confirm the actual key is `commentText`
    XCTAssertTrue(state.comments.allSatisfy { !$0.commentText.isEmpty })
}
```

- [ ] **Step 3: Commit**

---

### Task 12: Delete legacy install code from app, wire up new services

**Files (in app repo):**
- Delete: `MCPManager.swift`, `ClaudeCodeManager.swift`, `SkillInstaller.swift`, `ScriptInstaller.swift`, `HarnessIntegrationManager.swift` (if present)
- Delete: `mcp/` and `scripts/hooks/`
- Modify: `AppController.swift`, `SettingsManager.swift`, `PreferencesWindowController.swift`

Note on `claudeCodeAutoCreateSession`: today this is a Remarc setting persisted to `defaults`. The hook script reads it directly via `defaults read`. We keep this contract — the setting stays writable from Preferences but moves under "Remarc Hooks" section, with helper text noting it only matters when `remarc-hooks` plugin is installed. The hook continues to read it the same way.

- [ ] **Step 1: Update `AppController.swift`** — drop the install setup block, add migration

```swift
public func setup() {
    Task { await LegacyInstallCleanup.shared.runIfNeeded() }
    // ... rest of existing app setup (windows, hotkeys, etc.) untouched
}
```

- [ ] **Step 2: Remove the 5 files**

```bash
git rm app/RemarcPackage/Sources/RemarcFeature/Services/MCPManager.swift
git rm app/RemarcPackage/Sources/RemarcFeature/Services/ClaudeCodeManager.swift
git rm app/RemarcPackage/Sources/RemarcFeature/Utilities/SkillInstaller.swift
git rm app/RemarcPackage/Sources/RemarcFeature/Utilities/ScriptInstaller.swift
git rm -r mcp/ scripts/hooks/
```

- [ ] **Step 3: Find callers and fix compile errors**

```bash
grep -rn "MCPManager\|ClaudeCodeManager\|SkillInstaller\|ScriptInstaller\|HarnessIntegrationManager" \
  app/RemarcPackage/Sources/
```

For each match: replace with `PluginInstallDetector` calls or remove.

- [ ] **Step 4: Trim `SettingsManager.swift`**

Remove keys: `mcpUserDisabled`, `claudeCodeEnabled`, `claudeCodeAutoCreateSessionEnabled` (the Remarc-Swift mirror — the hook still reads the raw `defaults` key directly). Keep `claudeCodeAutoCreateSession` as a `@UserDefault` because the hook reads it. Add `pluginMigrationCompleted`.

- [ ] **Step 5: Build**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"
```

- [ ] **Step 6: Relaunch + smoke test**

```bash
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

Verify: app launches, screenshots work, commenting works, migration ran (`~/.claude/skills/remarc/SKILL.md` gone, no `remarc-` strings in `settings.json`, `claude mcp list` doesn't show remarc, `pluginMigrationCompleted = true`).

- [ ] **Step 7: Commit**

```bash
git commit -m "feat(plugin): remove legacy install code; app no longer writes ~/.claude/"
```

---

### Task 13: Preferences "Claude Code" tab — plugin status + copy commands

**Files (in app repo):**
- Modify: `PreferencesWindowController.swift`
- Create: `app/RemarcPackage/Sources/RemarcFeature/Views/Onboarding/PluginInstallView.swift`

Per memory rule: use SwiftUI `.help()` for tooltips, not custom hover popovers. Single location for the settings (no duplication across tabs).

- [ ] **Step 1: Write `PluginInstallView.swift`**

```swift
import SwiftUI

struct PluginInstallView: View {
    @State private var state: PluginInstallState = .init(remarcInstalled: false, remarcHooksInstalled: false, remarcHooksEnabled: false)
    private let detector = PluginInstallDetector()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            row(
                title: "remarc",
                subtitle: "Required. MCP server + skill for managing comments.",
                installed: state.remarcInstalled,
                commands: """
                /plugin marketplace add metedata/remarc-agent-plugins
                /plugin install remarc@remarc
                """
            )
            Divider()
            row(
                title: "remarc-hooks (experimental)",
                subtitle: "Optional. Auto-links Claude Code sessions to Remarc sessions and injects comments at session start. Off by default — install only if you want it.",
                installed: state.remarcHooksInstalled,
                enabled: state.remarcHooksEnabled,
                commands: "/plugin install remarc-hooks@remarc"
            )
            if state.remarcHooksInstalled {
                Toggle("Auto-create a Remarc session per Claude Code session", isOn: autoCreateBinding)
                    .help("Stored as defaults key claudeCodeAutoCreateSession. Read by the hook on session start.")
            }
        }
        .padding()
        .task { state = await detector.read() }
    }

    private var autoCreateBinding: Binding<Bool> { /* read/write via defaults */ }

    @ViewBuilder
    private func row(title: String, subtitle: String, installed: Bool, enabled: Bool = true, commands: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).bold()
                    if installed && enabled { Text("Installed").foregroundColor(.green) }
                    else if installed       { Text("Installed (disabled)").foregroundColor(.orange) }
                    else                    { Text("Not installed").foregroundColor(.secondary) }
                }
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button("Copy install commands") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commands, forType: .string)
            }.help("Paste into Claude Code")
        }
    }
}
```

- [ ] **Step 2: Wire into Preferences. Build, relaunch, verify. Commit.**

---

### Task 14: First-launch onboarding card

**Files (in app repo):**
- Modify: existing onboarding flow (located via grep — likely `OnboardingWindowController.swift` or similar)

- [ ] **Step 1: Find onboarding entry point**

```bash
grep -rln "Onboarding\|FirstLaunch\|Welcome" app/RemarcPackage/Sources/
```

- [ ] **Step 2: Insert a step that shows `PluginInstallView` if `state.remarcInstalled == false`**

Skip the step if `state.remarcInstalled == true` (returning user already set up).

- [ ] **Step 3: Verify by resetting onboarding state and relaunching. Commit.**

---

### Task 15: Documentation updates and contracts file

**Files (in app repo):**
- Modify: `CLAUDE.md`

**Files (in plugin repo):**
- Create: `plugins/shared/contracts.md`

Codex v2 strong suggestion: the hook script reads `com.metepolat.Remarc` defaults keys, which is a hidden contract between app and plugin. Formalize it.

- [ ] **Step 1: Write `plugins/shared/contracts.md` in the plugin repo**

````markdown
# App ↔ Plugin contracts

Stable surfaces the `remarc-hooks` plugin consumes from the Remarc macOS app. Breaking changes to these require a coordinated app+plugin release.

## File-system contract

- **`~/Library/Application Support/Remarc/comments.json`** — primary data file. Schema documented in `comments-schema.json` (same directory). The plugin reads this. Falls back to legacy `data.json` if the primary is absent.
- **`/tmp/remarc-claude-<claude_session_id>.marker`** — per-session marker the plugin writes/reads. Format: two lines, first is the Remarc session UUID (uppercase), second is the data file path. The app does NOT read or write these.

## `defaults` contract (domain: `com.metepolat.Remarc`)

These keys are read by the plugin via the `defaults read` shell-out. The app owns the Preferences UI that writes them; the plugin reads them at hook fire time. Absent keys fall back to the documented default.

| Key | Type | Values | Default | Read by |
|---|---|---|---|---|
| `claudeCodeAutoCreateSession` | Bool | `0`/`1` or `false`/`true` | `true` | `session-start` hook (startup/resume) — when false, skip creating a Remarc session and skip context injection |
| `claudeCodeSessionEndBehavior` | String | `keep`, `moveUnresolved`, `autoDelete` | `autoDelete` | `session-end` hook — controls what `windDown` does with unresolved comments |

## Contract versioning

The current schema has **no version field**. Both Swift (`AppState`) and TypeScript (`RawAppState`) decoders permit unknown fields for forward-compatibility, and the plugin's JSON-schema validation in CI only fails on missing-required or type-mismatch (additive optional fields pass).

Until a schema version is added, breaking changes require:
1. Bump `comments-schema.json` to capture the new required fields.
2. Run the cross-decode CI in both repos against a representative `comments.sample.json` until both pass.
3. Ship the app update first (writes the new schema, falls back gracefully for old plugin readers), then the plugin update (parses the new fields).

Adding a `schemaVersion` field is tracked as future work — it would let the plugin decline cleanly when the file is too new instead of silently misparsing.
````

- [ ] **Step 2: Update `CLAUDE.md` in the app repo**

Remove obsolete sections about MCP/hooks install. Add:

```markdown
## Claude Code integration

Remarc's Claude Code integration is distributed as a plugin marketplace at https://github.com/metedata/remarc-agent-plugins, not built into the app. The app reads installed-plugin state but does not write to `~/.claude/`.

- `remarc` — required plugin (MCP server + skill)
- `remarc-hooks` — optional, experimental (session-lifecycle hooks)

The app ↔ plugin contract (file paths, defaults keys, comment schema) is documented in the plugin repo at `plugins/shared/contracts.md`. Changes to `comments.json` schema or the `com.metepolat.Remarc` defaults keys require a coordinated app + plugin release.
```

- [ ] **Step 3: Release notes (3 high-level bullets per memory rule)**

```
- Claude Code integration moved to a plugin marketplace at metedata/remarc-agent-plugins.
- Existing users: cleanup of the old skill file, hooks, and MCP registration runs on launch and completes once the plugin is installed.
- Optional: install remarc-hooks@remarc for experimental session context injection. Off by default.
```

- [ ] **Step 4: Commit (both repos)**

---

### Task 16: End-to-end verification on a clean install

**No files modified.** Validation only.

- [ ] **Step 1: Clean state**

```bash
rm -f ~/.claude/skills/remarc/SKILL.md
claude mcp remove --scope user remarc 2>/dev/null || true
# Manually inspect ~/.claude/settings.json: no remarc-* commands left
claude plugin marketplace remove remarc 2>/dev/null || true
```

- [ ] **Step 2: Add marketplace, install required plugin**

```bash
claude plugin marketplace add metedata/remarc-agent-plugins
claude plugin install remarc@remarc
```

Verify in session: `/mcp` shows `remarc` connected. Ask "list my Remarc sessions" — expect a real list.

- [ ] **Step 3: Verify hooks NOT installed by default**

`/hooks` shows zero Remarc hooks. **This is the off-by-default requirement passing.**

- [ ] **Step 4: Install hooks plugin, verify session lifecycle**

```bash
claude plugin install remarc-hooks@remarc
```

Start a fresh session in a project directory. Verify:
- `/hooks` shows 3 Remarc hooks under the `remarc-hooks` plugin source
- Remarc.app's session list shows a new session matching the cwd basename
- SessionStart `additionalContext` was injected (visible in `/debug` or via verbose mode)
- Make a comment in Remarc → submit a Claude Code prompt → comment is injected as context
- End the session → wind-down ran per `claudeCodeSessionEndBehavior` default

- [ ] **Step 5: Uninstall hooks, verify clean removal**

```bash
claude plugin uninstall remarc-hooks@remarc
```

`/hooks` no longer shows Remarc entries. No app process involved.

- [ ] **Step 6: Uninstall main plugin (with hooks still installed), verify dependency-unsatisfied surfaces**

```bash
# First reinstall hooks so we have both, then remove just the main
claude plugin install remarc-hooks@remarc 2>/dev/null
claude plugin uninstall remarc@remarc
claude plugin list --json | jq '.[] | select(.name == "remarc-hooks") | .errors'
```

Expected: `remarc-hooks` shows a `dependency-unsatisfied` error and is disabled. This is the documented behavior — auto-installed dependencies stay on disk after the dependent is removed, but the dependent surfaces an error. See [plugin dependencies docs](https://code.claude.com/docs/en/plugin-dependencies).

- [ ] **Step 7: Full revert with --prune**

```bash
claude plugin uninstall remarc-hooks@remarc --prune
/mcp  # remarc no longer listed (prune removed the orphaned remarc auto-install)
```

- [ ] **Step 8: Reinstall via dependency auto-pull**

```bash
claude plugin install remarc-hooks@remarc  # should auto-install remarc as a dependency
claude plugin list --json | jq '.[] | .name'
```

Expected: both `remarc` and `remarc-hooks` end up installed.

---

## Self-review

**Spec coverage:**
- "Stop writing to `~/.claude/` from the app" ✓ (Tasks 9, 11)
- "Hooks off by default in Remarc" ✓ (Task 6's separate plugin, verified in Task 16 Step 3)
- "Plugin & MCP best practices" ✓ (stdio MCP, exec-form hooks, `${CLAUDE_PLUGIN_ROOT}`, shared schema)
- "Existing user migration" ✓ (Task 10, defensive, retries-until-installed)
- "Codex's blockers" ✓ (each one cited in the revision note at top + addressed in numbered tasks)

**Placeholders:** None. Operation bodies in Task 4 Step 4 explicitly point to `mcp/src/cli.ts` as 1-to-1 source (which is committed in the app repo and read by the executing agent — not a TBD).

**Type consistency:** `PluginInstallState`, `PluginInstallDetector`, `LegacyInstallCleanup`, `Marker`, `CreateSessionResult` used consistently. Hook event names match docs. Field name `commentText` is correct per data.ts.

## Open decisions

1. **`metedata` GitHub org ownership** — assumed; create-repo will fail if not. Confirm before Task 1.
2. **CI runs on `macos-latest`** for the `defaults` shell-out test — costs more minutes than Ubuntu. Acceptable for a low-volume plugin repo.
3. **`PluginInstallDetector` polls on demand**, not via FSEvents. If we want live updates in Preferences, add a 30s refresh timer.
4. **Should the onboarding card recommend `remarc-hooks`?** Default: no. Mentioned only in the `remarc` README. Surface as a one-time tip later if user feedback requests it.
5. **No telemetry on migration outcomes** — could add Sentry breadcrumbs on `LegacyInstallCleanup` success/failure to monitor the rollout.
