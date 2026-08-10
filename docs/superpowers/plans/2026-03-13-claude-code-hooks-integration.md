# Claude Code Hooks Integration — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically create Remarc sessions, inject comments into Claude Code context, and manage session lifecycle via Claude Code hooks.

**Architecture:** A Node.js CLI (`mcp/src/cli.ts`) reuses the existing MCP data layer for hook shell scripts to call. Three hooks (SessionStart, UserPromptSubmit, SessionEnd) manage the full lifecycle. A new `ClaudeCodeManager` Swift service handles hook registration in `~/.claude/settings.json`. A new "Claude Code" section in Preferences controls the integration.

**Tech Stack:** TypeScript/Node.js (CLI), Bash (hook scripts), Swift/SwiftUI (app changes), esbuild (bundling)

**Spec:** `docs/superpowers/specs/2026-03-13-claude-code-hooks-integration-design.md`

---

## Chunk 1: Data Model Foundation

### Task 1: Swift Data Model — `handedOff` Status

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/CommentStatus.swift:4-24`

- [ ] **Step 1: Add `handedOff` case to CommentStatus enum**

```swift
public enum CommentStatus: String, Codable, Sendable, CaseIterable {
    case open
    case handedOff
    case inProgress
    case resolved

    public var label: String {
        switch self {
        case .open: return "Open"
        case .handedOff: return "Handed Off"
        case .inProgress: return "In-Progress"
        case .resolved: return "Resolved"
        }
    }

    public static func color(for status: CommentStatus, colorScheme: ColorScheme) -> Color {
        switch status {
        case .open:       return Color.remarcSecondary(for: colorScheme)
        case .handedOff:  return Color.remarcInfo(for: colorScheme)
        case .inProgress: return Color.remarcWarning(for: colorScheme)
        case .resolved:   return Color.remarcSuccess(for: colorScheme)
        }
    }
}
```

- [ ] **Step 2: Build to verify no compile errors from new case**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

Any `switch` statements on `CommentStatus` that aren't exhaustive will fail here. Fix each one by adding `case .handedOff:` — typically treating it like `.inProgress` (it's a "someone has seen this" state). Search for all switch sites:

```bash
grep -rn "case \.open" app/RemarcPackage/Sources/ --include="*.swift" | grep -v "CommentStatus.swift"
```

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Models/CommentStatus.swift
# Plus any files with fixed switch statements
git commit -m "feat: add handedOff status to CommentStatus enum"
```

---

### Task 2: Swift Data Model — Session Origin

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/Session.swift:3-33`

- [ ] **Step 1: Add SessionOrigin enum and new fields to Session**

Add above the Session struct:
```swift
public enum SessionOrigin: String, Codable, Sendable {
    case manual
    case claudeCode
}
```

Add two new fields to the Session struct (with defaults so existing Codable conformance is preserved):
```swift
public var origin: SessionOrigin
public var claudeCodeSessionId: String?
```

Update the init to include new fields with defaults:
```swift
public init(
    id: UUID = UUID(),
    name: String,
    createdAt: Date = Date(),
    isDeleted: Bool = false,
    deletedAt: Date? = nil,
    isAutoDismissed: Bool = false,
    autoDismissedAt: Date? = nil,
    origin: SessionOrigin = .manual,
    claudeCodeSessionId: String? = nil
) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
    self.isDeleted = isDeleted
    self.deletedAt = deletedAt
    self.isAutoDismissed = isAutoDismissed
    self.autoDismissedAt = autoDismissedAt
    self.origin = origin
    self.claudeCodeSessionId = claudeCodeSessionId
}
```

- [ ] **Step 2: Add CodingKeys with defaults for backward compatibility**

Swift's `Codable` won't decode old JSON without these fields unless we provide defaults via `init(from:)`:

```swift
private enum CodingKeys: String, CodingKey {
    case id, name, createdAt, isDeleted, deletedAt
    case isAutoDismissed, autoDismissedAt
    case origin, claudeCodeSessionId
}

public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
    deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
    isAutoDismissed = try container.decode(Bool.self, forKey: .isAutoDismissed)
    autoDismissedAt = try container.decodeIfPresent(Date.self, forKey: .autoDismissedAt)
    origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin) ?? .manual
    claudeCodeSessionId = try container.decodeIfPresent(String.self, forKey: .claudeCodeSessionId)
}
```

- [ ] **Step 3: Build to verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Models/Session.swift
git commit -m "feat: add origin and claudeCodeSessionId to Session model"
```

---

### Task 3: TypeScript Data Model

**Files:**
- Modify: `mcp/src/data.ts:40,87-105,173-184,223-234`
- Modify: `mcp/src/tools.ts:139-152`

- [ ] **Step 1: Update CommentStatus type and add session fields**

In `mcp/src/data.ts`, update the CommentStatus type (line 40):
```typescript
export type CommentStatus = "open" | "handedOff" | "inProgress" | "resolved";
```

Add `origin` and `claudeCodeSessionId` to `RawSession` interface (after line 95):
```typescript
export interface RawSession {
  id: string;
  name: string;
  createdAt: number;
  isDeleted: boolean;
  deletedAt?: number | null;
  isAutoDismissed: boolean;
  autoDismissedAt?: number | null;
  origin?: string;
  claudeCodeSessionId?: string | null;
}
```

Add to `Session` interface (after line 105):
```typescript
export interface Session {
  id: string;
  name: string;
  createdAt: Date;
  isDeleted: boolean;
  deletedAt: Date | null;
  isAutoDismissed: boolean;
  autoDismissedAt: Date | null;
  origin: string;
  claudeCodeSessionId: string | null;
}
```

- [ ] **Step 2: Update parseSession() and serializeSession()**

Update `parseSession()` (around line 173):
```typescript
function parseSession(raw: RawSession): Session {
  return {
    id: raw.id,
    name: raw.name,
    createdAt: appleToDate(raw.createdAt),
    isDeleted: raw.isDeleted,
    deletedAt: raw.deletedAt != null ? appleToDate(raw.deletedAt) : null,
    isAutoDismissed: raw.isAutoDismissed,
    autoDismissedAt:
      raw.autoDismissedAt != null ? appleToDate(raw.autoDismissedAt) : null,
    origin: raw.origin ?? "manual",
    claudeCodeSessionId: raw.claudeCodeSessionId ?? null,
  };
}
```

Update `serializeSession()` (around line 223):
```typescript
function serializeSession(session: Session): RawSession {
  const raw: RawSession = {
    id: session.id,
    name: session.name,
    createdAt: dateToApple(session.createdAt),
    isDeleted: session.isDeleted,
    deletedAt: session.deletedAt ? dateToApple(session.deletedAt) : null,
    isAutoDismissed: session.isAutoDismissed,
    autoDismissedAt: session.autoDismissedAt
      ? dateToApple(session.autoDismissedAt)
      : null,
    origin: session.origin,
    claudeCodeSessionId: session.claudeCodeSessionId,
  };
  return raw;
}
```

- [ ] **Step 3: Update remarc_list_comments filter to accept `handedOff`**

In `mcp/src/tools.ts`, update the status enum in `remarc_list_comments` (around line 145):
```typescript
status: z
  .enum(["open", "handedOff", "inProgress", "resolved"])
  .optional()
  .describe("Filter by status."),
```

Do NOT add `handedOff` to `remarc_set_status` — it should only be set by the CLI.

- [ ] **Step 4: Build MCP to verify**

```bash
cd mcp && npm run build
```

- [ ] **Step 5: Commit**

```bash
git add mcp/src/data.ts mcp/src/tools.ts
git commit -m "feat: add handedOff status and session origin to TypeScript data layer"
```

---

### Task 4: PersistenceManager — Cancel Debounced Save on Reload

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift:69-74,461-471`

- [ ] **Step 1: Cancel pending save before reloading from disk**

The race condition: CLI writes to disk → sends reload notification → PersistenceManager's debounced save fires → overwrites CLI's changes with stale in-memory state.

Fix `reloadFromDisk()` (line 461) to cancel the pending debounce first:

```swift
private func reloadFromDisk() {
    // Cancel any pending debounced save — disk state takes precedence
    saveCancellable?.cancel()
    saveCancellable = saveSubject
        .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            self?.saveToDisk()
        }

    guard let data = try? Data(contentsOf: fileURL),
          let state = try? JSONDecoder().decode(AppState.self, from: data) else {
        debugLog("PersistenceManager: Failed to reload from disk")
        return
    }
    appState = state
    debugLog("PersistenceManager: Reloaded from disk (\(state.comments.count) comments, \(state.sessions.count) sessions)")
    autoDeleteResolvedComments()
}
```

This cancels the existing Combine subscription (which includes any pending debounced value) and re-subscribes. The in-memory state is then replaced by disk state, so any subsequent `scheduleSave()` call writes the correct data.

- [ ] **Step 2: Build and relaunch to verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

```bash
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift
git commit -m "fix: cancel debounced save before reloading from disk to prevent race condition"
```

---

## Chunk 2: CLI Implementation

### Task 5: CLI Scaffolding and Build Configuration

**Files:**
- Create: `mcp/src/cli.ts`
- Modify: `mcp/package.json`

- [ ] **Step 1: Add CLI build script to package.json**

Add a `build:cli` script and update the `build` script to build both:
```json
{
  "scripts": {
    "build": "npm run build:mcp && npm run build:cli",
    "build:mcp": "esbuild src/index.ts --bundle --platform=node --target=node18 --format=esm --outfile=dist/index.js --banner:js=\"#!/usr/bin/env node\"",
    "build:cli": "esbuild src/cli.ts --bundle --platform=node --target=node18 --format=esm --outfile=dist/cli.js --banner:js=\"#!/usr/bin/env node\"",
    "dev": "npx tsx src/index.ts"
  }
}
```

- [ ] **Step 2: Create CLI entry point with argument parsing**

Create `mcp/src/cli.ts`:
```typescript
#!/usr/bin/env node
import { readAppState, writeAppState, getDataFilePath } from "./data.js";
import { notifyRemarcReload } from "./notify.js";

interface CliResult {
  remarc_session_id?: string;
  data_file_path?: string;
  hookSpecificOutput?: {
    additionalContext: string;
  };
}

function parseArgs(args: string[]): { command: string; flags: Record<string, string> } {
  const command = args[0] ?? "";
  const flags: Record<string, string> = {};
  for (let i = 1; i < args.length; i++) {
    if (args[i].startsWith("--") && i + 1 < args.length) {
      const key = args[i].slice(2);
      flags[key] = args[i + 1];
      i++;
    }
  }
  return { command, flags };
}

async function main() {
  const { command, flags } = parseArgs(process.argv.slice(2));

  switch (command) {
    case "create-session":
      await createSession(flags);
      break;
    case "handoff":
      await handoff(flags);
      break;
    case "wind-down":
      await windDown(flags);
      break;
    default:
      console.error(`Unknown command: ${command}`);
      console.error("Usage: remarc-cli <create-session|handoff|wind-down> [flags]");
      process.exit(1);
  }
}

main().catch((err) => {
  console.error("CLI error:", err.message);
  process.exit(1);
});
```

Note: `getDataFilePath` is currently not exported from `data.ts`. Add `export` to the function declaration in `data.ts` (line 132): change `function getDataFilePath()` to `export function getDataFilePath()`. (`writeAppState` and `AppState` are already exported — no changes needed for those.)

- [ ] **Step 3: Build to verify scaffolding compiles**

```bash
cd mcp && npm run build
```

- [ ] **Step 4: Commit**

```bash
git add mcp/src/cli.ts mcp/package.json mcp/src/data.ts
git commit -m "feat: scaffold CLI entry point with argument parsing and build config"
```

---

### Task 6: CLI `create-session` Command

**Files:**
- Modify: `mcp/src/cli.ts`
- Modify: `mcp/src/data.ts` (need to export helper and add session creation logic)

- [ ] **Step 1: Add `createSession` function to cli.ts**

Add above `main()` in `mcp/src/cli.ts`:
```typescript
import { randomUUID } from "node:crypto";

const MAX_ACTIVE_SESSIONS = 8;

async function createSession(flags: Record<string, string>) {
  const name = flags["name"];
  const claudeSessionId = flags["claude-session-id"];
  const source = flags["source"] ?? "startup";

  if (!name || !claudeSessionId) {
    console.error("Required: --name <name> --claude-session-id <id>");
    process.exit(1);
  }

  const state = await readAppState();
  if (!state) {
    console.error("Remarc data file not found. Is Remarc installed?");
    process.exit(1);
  }

  // Resume: look for existing session with this Claude Code session ID
  if (source === "resume") {
    const existing = state.sessions.find(
      (s) => !s.isDeleted && !s.isAutoDismissed && s.claudeCodeSessionId === claudeSessionId
    );
    if (existing) {
      state.activeSessionID = existing.id;
      await writeAppState(state);
      await notifyRemarcReload();
      const result: CliResult = {
        remarc_session_id: existing.id,
        data_file_path: getDataFilePath(),
      };
      console.log(JSON.stringify(result));
      return;
    }
    // Fall through to create new if not found
  }

  // Check session limit
  const activeSessions = state.sessions.filter((s) => !s.isDeleted && !s.isAutoDismissed);
  if (activeSessions.length >= MAX_ACTIVE_SESSIONS) {
    // Auto-dismiss oldest claudeCode-origin session
    const claudeSessions = activeSessions
      .filter((s) => s.origin === "claudeCode")
      .sort((a, b) => a.createdAt.getTime() - b.createdAt.getTime());

    if (claudeSessions.length > 0) {
      const oldest = claudeSessions[0];
      const idx = state.sessions.findIndex((s) => s.id === oldest.id);
      if (idx !== -1) {
        state.sessions[idx].isAutoDismissed = true;
        state.sessions[idx].autoDismissedAt = new Date();
      }
    } else {
      console.error("Max sessions reached and no Claude Code sessions to auto-dismiss.");
      process.exit(1);
    }
  }

  // Create new session
  const sessionId = randomUUID();
  const now = new Date();
  state.sessions.push({
    id: sessionId,
    name,
    createdAt: now,
    isDeleted: false,
    deletedAt: null,
    isAutoDismissed: false,
    autoDismissedAt: null,
    origin: "claudeCode",
    claudeCodeSessionId: claudeSessionId,
  });
  state.activeSessionID = sessionId;

  await writeAppState(state);
  await notifyRemarcReload();

  const result: CliResult = {
    remarc_session_id: sessionId,
    data_file_path: getDataFilePath(),
  };
  console.log(JSON.stringify(result));
}
```

- [ ] **Step 2: Export `writeAppState` and `getDataFilePath` from data.ts if not already exported**

`writeAppState`, `AppState`, and `activeSessionID` are already exported. Only `getDataFilePath` needs the `export` keyword added (should already be done in Task 5 Step 2).

- [ ] **Step 3: Test manually**

```bash
cd mcp && npm run build && node dist/cli.js create-session --name "Test Session" --claude-session-id "test-123" --source startup
```

Should output JSON with `remarc_session_id` and `data_file_path`. Check `~/Library/Application Support/Remarc/comments.json` to verify the session was created.

- [ ] **Step 4: Commit**

```bash
git add mcp/src/cli.ts mcp/src/data.ts
git commit -m "feat: implement create-session CLI command with resume support"
```

---

### Task 7: CLI `handoff` Command

**Files:**
- Modify: `mcp/src/cli.ts`

- [ ] **Step 1: Add the integration context message constant**

Add near the top of `cli.ts`:
```typescript
const INTEGRATION_CONTEXT =
  "A Remarc session is active for this Claude Code session. " +
  "Comments made in Remarc are automatically attached to your messages. " +
  "When you address a comment, use the remarc_set_status MCP tool to mark it as inProgress or resolved.";
```

- [ ] **Step 2: Add `handoff` function**

```typescript
async function handoff(flags: Record<string, string>) {
  const sessionId = flags["session-id"];
  const recovery = "recovery" in flags;

  if (!sessionId) {
    console.error("Required: --session-id <uuid>");
    process.exit(1);
  }

  const state = await readAppState();
  if (!state) {
    // Remarc not initialized — nothing to hand off
    return;
  }

  // Find session (graceful if deleted)
  const session = state.sessions.find((s) => s.id === sessionId);
  if (!session || session.isDeleted) {
    // Session gone — output nothing
    return;
  }

  // Filter comments by status
  const targetStatuses: string[] = recovery
    ? ["open", "handedOff", "inProgress"]
    : ["open"];

  const comments = state.comments.filter(
    (c) =>
      c.sessionID === sessionId &&
      !c.isDeleted &&
      targetStatuses.includes(c.status)
  );

  if (comments.length === 0 && !recovery) {
    // Nothing to hand off — output nothing
    return;
  }

  // Mark open comments as handedOff (only in non-recovery mode, and only if setting is enabled)
  if (!recovery) {
    let autoHandoff = true;
    try {
      const val = execSync(
        "defaults read com.metepolat.Remarc claudeCodeAutoHandoff",
        { encoding: "utf-8", timeout: 3000 }
      ).trim();
      autoHandoff = val !== "0";
    } catch {
      // Key not set — default to true
    }

    if (autoHandoff) {
      let changed = false;
      for (const comment of comments) {
        if (comment.status === "open") {
          const idx = state.comments.findIndex((c) => c.id === comment.id);
          if (idx !== -1) {
            state.comments[idx].status = "handedOff";
            state.comments[idx].updatedAt = new Date();
            changed = true;
          }
        }
      }
      if (changed) {
        await writeAppState(state);
        await notifyRemarcReload();
      }
    }
  }

  // Format output
  const lines: string[] = [];

  if (recovery) {
    lines.push(INTEGRATION_CONTEXT);
    lines.push("");
  }

  if (comments.length > 0) {
    const label = recovery ? "Outstanding" : "New";
    lines.push(`## Remarc Comments (${comments.length} ${label.toLowerCase()})`);
    lines.push("");

    for (const comment of comments) {
      lines.push(`### [${comment.shortID}] ${comment.commentText}`);

      // Include reference text if it's a text-selection comment
      if (comment.type && "comment" in comment.type) {
        lines.push(`> Selected text: "${comment.type.comment.text}"`);
      }

      if (comment.source) {
        lines.push(`Source: ${comment.source}`);
      }

      lines.push(`Status: ${comment.status}`);
      lines.push("");
    }
  } else if (recovery) {
    lines.push("No outstanding Remarc comments.");
  }

  if (lines.length > 0) {
    const result = {
      hookSpecificOutput: {
        additionalContext: lines.join("\n"),
      },
    };
    console.log(JSON.stringify(result));
  }
}
```

Note: `CommentType` is a tagged union: `{ comment: { text: string } }`, `{ screenshot: { imagePath: string } }`, `{ quickNote: {} }`, `{ critMode: {} }`. The reference text extraction above uses `"comment" in comment.type` to check for text-selection comments.

- [ ] **Step 3: Test manually**

```bash
cd mcp && npm run build && node dist/cli.js handoff --session-id "<uuid-from-create-session>"
```

If there are open comments in that session, should output JSON with `hookSpecificOutput.additionalContext`.

- [ ] **Step 4: Commit**

```bash
git add mcp/src/cli.ts
git commit -m "feat: implement handoff CLI command with recovery mode"
```

---

### Task 8: CLI `wind-down` Command

**Files:**
- Modify: `mcp/src/cli.ts`

- [ ] **Step 1: Add `windDown` function**

```typescript
import { execSync } from "node:child_process";

async function windDown(flags: Record<string, string>) {
  const sessionId = flags["session-id"];

  if (!sessionId) {
    console.error("Required: --session-id <uuid>");
    process.exit(1);
  }

  const state = await readAppState();
  if (!state) return;

  const sessionIdx = state.sessions.findIndex((s) => s.id === sessionId);
  if (sessionIdx === -1) return; // Session already gone

  // Read user preference from UserDefaults
  let behavior = "autoDelete";
  try {
    behavior = execSync(
      "defaults read com.metepolat.Remarc claudeCodeSessionEndBehavior",
      { encoding: "utf-8", timeout: 3000 }
    ).trim();
  } catch {
    // Key not set — use default
  }

  const now = new Date();

  switch (behavior) {
    case "keep":
      // Leave session as-is
      break;

    case "moveUnresolved": {
      // Find or create Inbox session
      let inbox = state.sessions.find(
        (s) => s.name === "Inbox" && !s.isDeleted && !s.isAutoDismissed
      );
      if (!inbox) {
        const inboxId = randomUUID();
        inbox = {
          id: inboxId,
          name: "Inbox",
          createdAt: now,
          isDeleted: false,
          deletedAt: null,
          isAutoDismissed: false,
          autoDismissedAt: null,
          origin: "manual",
          claudeCodeSessionId: null,
        };
        state.sessions.push(inbox);
      }

      // Move unresolved comments to Inbox
      for (let i = 0; i < state.comments.length; i++) {
        const c = state.comments[i];
        if (
          c.sessionID === sessionId &&
          !c.isDeleted &&
          ["open", "handedOff", "inProgress"].includes(c.status)
        ) {
          state.comments[i].sessionID = inbox.id;
          state.comments[i].updatedAt = now;
        }
      }

      // Delete the session and remaining (resolved) comments
      state.sessions[sessionIdx].isDeleted = true;
      state.sessions[sessionIdx].deletedAt = now;
      for (let i = 0; i < state.comments.length; i++) {
        if (state.comments[i].sessionID === sessionId && !state.comments[i].isDeleted) {
          state.comments[i].isDeleted = true;
          state.comments[i].deletedAt = now;
        }
      }
      break;
    }

    case "autoDelete":
    default: {
      // Delete session and all its comments
      state.sessions[sessionIdx].isDeleted = true;
      state.sessions[sessionIdx].deletedAt = now;
      for (let i = 0; i < state.comments.length; i++) {
        if (state.comments[i].sessionID === sessionId) {
          state.comments[i].isDeleted = true;
          state.comments[i].deletedAt = now;
        }
      }
      break;
    }
  }

  // Clear activeSessionID if it was pointing to this session
  if (state.activeSessionID === sessionId) {
    const remaining = state.sessions.filter((s) => !s.isDeleted && !s.isAutoDismissed);
    state.activeSessionID = remaining.length > 0 ? remaining[0].id : null;
  }

  await writeAppState(state);
  await notifyRemarcReload();
}
```

- [ ] **Step 2: Test manually**

```bash
cd mcp && npm run build

# Create a test session first
node dist/cli.js create-session --name "Test Wind-Down" --claude-session-id "test-wd"

# Wind it down
node dist/cli.js wind-down --session-id "<uuid>"
```

Verify in `comments.json` that the session is marked as deleted.

- [ ] **Step 3: Commit**

```bash
git add mcp/src/cli.ts
git commit -m "feat: implement wind-down CLI command with configurable behavior"
```

---

## Chunk 3: Hook Scripts and Registration

### Task 9: Hook Shell Scripts

**Files:**
- Create: `scripts/hooks/remarc-session-start.sh`
- Create: `scripts/hooks/remarc-prompt-submit.sh`
- Create: `scripts/hooks/remarc-session-end.sh`

- [ ] **Step 1: Create SessionStart hook script**

```bash
#!/bin/bash
# Remarc Claude Code hook: SessionStart
# Creates or reconnects a Remarc session when Claude Code starts.

set -euo pipefail

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('source',''))" 2>/dev/null || echo "")
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")
CWD=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('cwd',''))" 2>/dev/null || echo "")

CLI_PATH="${REMARC_CLI_PATH:?}"
NODE="${REMARC_NODE_PATH:?}"
MARKER_FILE="/tmp/remarc-claude-${SESSION_ID}.marker"

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

case "$SOURCE" in
  startup)
    CWD_NAME=$(basename "$CWD")
    RESULT=$("$NODE" "$CLI_PATH" create-session --name "Claude: $CWD_NAME" --claude-session-id "$SESSION_ID" --source startup 2>/dev/null || echo "")
    if [ -z "$RESULT" ]; then
      exit 0
    fi

    # Write marker file (line 1: remarc session ID, line 2: data file path)
    REMARC_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('remarc_session_id',''))")
    DATA_PATH=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data_file_path',''))")
    printf '%s\n%s\n' "$REMARC_ID" "$DATA_PATH" > "$MARKER_FILE"

    # Output integration context + any existing open comments via recovery mode
    "$NODE" "$CLI_PATH" handoff --session-id "$REMARC_ID" --recovery 2>/dev/null || true
    ;;

  resume)
    CWD_NAME=$(basename "$CWD")
    RESULT=$("$NODE" "$CLI_PATH" create-session --name "Claude: $CWD_NAME" --claude-session-id "$SESSION_ID" --source resume 2>/dev/null || echo "")
    if [ -z "$RESULT" ]; then
      exit 0
    fi

    REMARC_ID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('remarc_session_id',''))")
    DATA_PATH=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data_file_path',''))")
    printf '%s\n%s\n' "$REMARC_ID" "$DATA_PATH" > "$MARKER_FILE"

    # Recovery: re-inject context + outstanding comments
    "$NODE" "$CLI_PATH" handoff --session-id "$REMARC_ID" --recovery 2>/dev/null || true
    ;;

  compact|clear)
    if [ ! -f "$MARKER_FILE" ]; then
      exit 0
    fi
    REMARC_ID=$(head -1 "$MARKER_FILE")
    "$NODE" "$CLI_PATH" handoff --session-id "$REMARC_ID" --recovery 2>/dev/null || true
    ;;

  *)
    exit 0
    ;;
esac
```

- [ ] **Step 2: Create UserPromptSubmit hook script**

```bash
#!/bin/bash
# Remarc Claude Code hook: UserPromptSubmit
# Injects open Remarc comments into Claude's context on each message.

set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")

CLI_PATH="${REMARC_CLI_PATH:?}"
NODE="${REMARC_NODE_PATH:?}"
MARKER_FILE="/tmp/remarc-claude-${SESSION_ID}.marker"

# No marker = integration not active
if [ ! -f "$MARKER_FILE" ]; then
  exit 0
fi

REMARC_ID=$(head -1 "$MARKER_FILE")
DATA_PATH=$(sed -n '2p' "$MARKER_FILE")

# mtime check: has comments.json changed since last handoff?
if [ ! "$DATA_PATH" -nt "$MARKER_FILE" ]; then
  exit 0
fi

# Something changed — run handoff
RESULT=$("$NODE" "$CLI_PATH" handoff --session-id "$REMARC_ID" 2>/dev/null || echo "")

# Touch marker to update mtime for next comparison
touch "$MARKER_FILE"

# Pass CLI output through (may be empty if no open comments)
if [ -n "$RESULT" ]; then
  echo "$RESULT"
fi
```

- [ ] **Step 3: Create SessionEnd hook script**

```bash
#!/bin/bash
# Remarc Claude Code hook: SessionEnd
# Winds down the Remarc session per user preference.

set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null || echo "")

CLI_PATH="${REMARC_CLI_PATH:?}"
NODE="${REMARC_NODE_PATH:?}"
MARKER_FILE="/tmp/remarc-claude-${SESSION_ID}.marker"

if [ ! -f "$MARKER_FILE" ]; then
  exit 0
fi

REMARC_ID=$(head -1 "$MARKER_FILE")

# Wind down session
"$NODE" "$CLI_PATH" wind-down --session-id "$REMARC_ID" 2>/dev/null || true

# Clean up marker file
rm -f "$MARKER_FILE"
```

- [ ] **Step 4: Make scripts executable**

```bash
chmod +x scripts/hooks/remarc-session-start.sh scripts/hooks/remarc-prompt-submit.sh scripts/hooks/remarc-session-end.sh
```

- [ ] **Step 5: Commit**

```bash
git add scripts/hooks/
git commit -m "feat: add Claude Code hook shell scripts"
```

---

### Task 10: SettingsManager — Claude Code Settings

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift`

- [ ] **Step 1: Add ClaudeCodeSessionEndBehavior enum**

Add alongside the other enums (after `ResolvedCommentDeletion`, around line 493):
```swift
public enum ClaudeCodeSessionEndBehavior: String, CaseIterable, Sendable {
    case autoDelete
    case keep
    case moveUnresolved

    public var label: String {
        switch self {
        case .autoDelete: "Delete session"
        case .keep: "Keep session"
        case .moveUnresolved: "Delete session, move unresolved to Inbox"
        }
    }
}
```

- [ ] **Step 2: Add Keys and @Published properties**

Add to the Keys enum (around line 11):
```swift
static let claudeCodeEnabled = "claudeCodeEnabled"
static let claudeCodeSessionEndBehavior = "claudeCodeSessionEndBehavior"
static let claudeCodeAutoHandoff = "claudeCodeAutoHandoff"
```

Add to the @Published properties section (around line 238):
```swift
// MARK: - Claude Code Integration

@Published public var claudeCodeEnabled: Bool {
    didSet { defaults.set(claudeCodeEnabled, forKey: Keys.claudeCodeEnabled) }
}

@Published public var claudeCodeSessionEndBehavior: ClaudeCodeSessionEndBehavior {
    didSet { defaults.set(claudeCodeSessionEndBehavior.rawValue, forKey: Keys.claudeCodeSessionEndBehavior) }
}

@Published public var claudeCodeAutoHandoff: Bool {
    didSet { defaults.set(claudeCodeAutoHandoff, forKey: Keys.claudeCodeAutoHandoff) }
}
```

- [ ] **Step 3: Initialize in init()**

Add to the init method (around line 467, before the closing brace):
```swift
// Claude Code Integration
self.claudeCodeEnabled = defaults.bool(forKey: Keys.claudeCodeEnabled)

if let behaviorRaw = defaults.string(forKey: Keys.claudeCodeSessionEndBehavior),
   let behavior = ClaudeCodeSessionEndBehavior(rawValue: behaviorRaw) {
    self.claudeCodeSessionEndBehavior = behavior
} else {
    self.claudeCodeSessionEndBehavior = .autoDelete
}

self.claudeCodeAutoHandoff = defaults.object(forKey: Keys.claudeCodeAutoHandoff) == nil
    ? true
    : defaults.bool(forKey: Keys.claudeCodeAutoHandoff)
```

Note: `claudeCodeAutoHandoff` defaults to `true` — use `defaults.object` nil check to distinguish "never set" from "set to false".

- [ ] **Step 4: Build to verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift
git commit -m "feat: add Claude Code integration settings to SettingsManager"
```

---

### Task 11: ClaudeCodeManager Service

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/ClaudeCodeManager.swift`

- [ ] **Step 1: Create ClaudeCodeManager**

Model after `MCPManager.swift`. This service handles hook registration/deregistration in `~/.claude/settings.json`.

```swift
import Foundation

@MainActor
public final class ClaudeCodeManager: ObservableObject {
    public static let shared = ClaudeCodeManager()

    public enum HookStatus: Equatable, Sendable {
        case registered
        case notRegistered
        case claudeCodeNotFound
    }

    @Published public var hookStatus: HookStatus = .claudeCodeNotFound
    @Published public var claudePath: String?

    private var nodePath: String?

    private init() {}

    // MARK: - Dependency Detection

    public func checkDependencies() {
        Task {
            async let node = resolveBinaryPath("node")
            async let claude = resolveBinaryPath("claude")
            let (n, c) = await (node, claude)
            self.nodePath = n
            self.claudePath = c

            if c == nil {
                hookStatus = .claudeCodeNotFound
            } else {
                hookStatus = checkHooksRegistered() ? .registered : .notRegistered

                // Re-register on launch if enabled (idempotent — fixes stale CLI paths after app upgrade)
                if SettingsManager.shared.claudeCodeEnabled && hookStatus != .registered {
                    _ = enable()
                }
            }
        }
    }

    // MARK: - Hook Registration

    public func enable() -> Bool {
        guard let nodePath else {
            debugLog("ClaudeCodeManager: Node.js not found")
            return false
        }

        guard let cliURL = Bundle.main.url(forResource: "remarc-cli", withExtension: "js") else {
            debugLog("ClaudeCodeManager: remarc-cli.js not found in bundle")
            return false
        }

        let cliPath = cliURL.path

        guard let settingsURL = claudeSettingsURL() else { return false }

        do {
            var settings = readClaudeSettings(at: settingsURL)

            // Remove any existing Remarc hooks first
            removeRemarcHooks(from: &settings)

            // Add Remarc hooks
            let hookCommand = { (script: String) -> [String: Any] in
                [
                    "type": "command",
                    "command": "\(script)",
                ]
            }

            let sessionStartScript = self.hookScript("remarc-session-start.sh", cliPath: cliPath, nodePath: nodePath)
            let promptSubmitScript = self.hookScript("remarc-prompt-submit.sh", cliPath: cliPath, nodePath: nodePath)
            let sessionEndScript = self.hookScript("remarc-session-end.sh", cliPath: cliPath, nodePath: nodePath)

            addHook(to: &settings, event: "SessionStart", hook: hookCommand(sessionStartScript))
            addHook(to: &settings, event: "UserPromptSubmit", hook: hookCommand(promptSubmitScript))
            addHook(to: &settings, event: "SessionEnd", hook: hookCommand(sessionEndScript))

            try writeClaudeSettings(settings, to: settingsURL)
            hookStatus = .registered
            debugLog("ClaudeCodeManager: Hooks registered")
            return true
        } catch {
            debugLog("ClaudeCodeManager: Failed to register hooks: \(error)")
            return false
        }
    }

    public func disable() -> Bool {
        guard let settingsURL = claudeSettingsURL() else { return false }

        do {
            var settings = readClaudeSettings(at: settingsURL)
            removeRemarcHooks(from: &settings)
            try writeClaudeSettings(settings, to: settingsURL)
            hookStatus = .notRegistered
            debugLog("ClaudeCodeManager: Hooks deregistered")
            return true
        } catch {
            debugLog("ClaudeCodeManager: Failed to deregister hooks: \(error)")
            return false
        }
    }

    // MARK: - Private Helpers

    private func claudeSettingsURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".claude")
        let file = dir.appendingPathComponent("settings.json")

        // Create .claude/ directory if needed
        if !FileManager.default.fileExists(atPath: dir.path) {
            // Claude Code not installed — .claude/ should already exist
            return nil
        }
        return file
    }

    private func readClaudeSettings(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func writeClaudeSettings(_ settings: [String: Any], to url: URL) throws {
        // Backup existing file (remove old backup first — copyItem doesn't overwrite)
        let backupURL = url.deletingLastPathComponent().appendingPathComponent("settings.json.remarc-backup")
        try? FileManager.default.removeItem(at: backupURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.copyItem(at: url, to: backupURL)
        }

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)

        // Remove backup on success
        try? FileManager.default.removeItem(at: backupURL)
    }

    private func hookScript(_ scriptName: String, cliPath: String, nodePath: String) -> String {
        // Get the script from the app bundle
        guard let scriptURL = Bundle.main.url(forResource: scriptName.replacingOccurrences(of: ".sh", with: ""), withExtension: "sh") else {
            return ""
        }
        // The script uses __REMARC_CLI_PATH__ placeholder — replace at registration time
        // Actually, we embed the CLI path via an env var approach instead
        return "REMARC_CLI_PATH='\(cliPath)' REMARC_NODE_PATH='\(nodePath)' '\(scriptURL.path)'"
    }

    private func addHook(to settings: inout [String: Any], event: String, hook: [String: Any]) {
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var eventHooks = hooks[event] as? [[String: Any]] ?? []
        eventHooks.append([
            "hooks": [hook]
        ])
        hooks[event] = eventHooks
        settings["hooks"] = hooks
    }

    private func removeRemarcHooks(from settings: inout [String: Any]) {
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for event in ["SessionStart", "UserPromptSubmit", "SessionEnd"] {
            guard var eventHooks = hooks[event] as? [[String: Any]] else { continue }
            eventHooks.removeAll { entry in
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return innerHooks.contains { h in
                    let cmd = h["command"] as? String ?? ""
                    return cmd.contains("remarc-")
                }
            }
            hooks[event] = eventHooks.isEmpty ? nil : eventHooks
        }

        settings["hooks"] = hooks
    }

    private func checkHooksRegistered() -> Bool {
        guard let url = claudeSettingsURL(),
              let settings = try? readClaudeSettings(at: url) as [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }

        // Check that all three hook events have Remarc entries
        for event in ["SessionStart", "UserPromptSubmit", "SessionEnd"] {
            guard let eventHooks = hooks[event] as? [[String: Any]] else { return false }
            let hasRemarc = eventHooks.contains { entry in
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return innerHooks.contains { h in
                    (h["command"] as? String ?? "").contains("remarc-")
                }
            }
            if !hasRemarc { return false }
        }
        return true
    }

    private func resolveBinaryPath(_ name: String) async -> String? {
        // Use login shell to resolve PATH — essential for Homebrew/nvm binaries
        // Matches the pattern in MCPManager.resolveBinaryPath()
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-l", "-c", "which \(name)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: path)
                } else {
                    continuation.resume(returning: nil)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
```

The hook scripts read `REMARC_CLI_PATH` and `REMARC_NODE_PATH` from environment variables set by the `hookScript()` method above. This was already handled in Task 9.

- [ ] **Step 2: Build to verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/ClaudeCodeManager.swift
git commit -m "feat: add ClaudeCodeManager for hook registration and lifecycle"
```

---

## Chunk 4: UI Changes

### Task 12: Preferences — Claude Code Section

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift:126-150,180+`

- [ ] **Step 1: Add `claudeCode` case to SettingsSection enum**

In the `SettingsSection` enum (line 126), add after `chromeExtension`:
```swift
case chromeExtension = "Chrome Extension"
case claudeCode = "Claude Code"
case excludedApps = "Excluded Apps"
```

Add icon in the `icon` switch:
```swift
case .claudeCode: return "terminal"
```

- [ ] **Step 2: Add switch case in body to route to the section view**

In the `switch selectedSection` block (around line 180), add:
```swift
case .claudeCode: claudeCodeSection
```

- [ ] **Step 3: Implement the Claude Code section view**

Add as a new private computed property (after `chromeExtensionSection`):

```swift
private var claudeCodeSection: some View {
    VStack(alignment: .leading, spacing: 16) {
        // Description
        Text("Creates a Remarc session when you start a Claude Code session. Comments you make are automatically attached to your messages so Claude can see and address them. Sessions are cleaned up when the session ends. Powered by Claude Code hooks.")
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)

        Divider()

        // Enable toggle
        HStack {
            Toggle("Enable Claude Code integration", isOn: Binding(
                get: { settings.claudeCodeEnabled },
                set: { newValue in
                    settings.claudeCodeEnabled = newValue
                    if newValue {
                        _ = ClaudeCodeManager.shared.enable()
                    } else {
                        _ = ClaudeCodeManager.shared.disable()
                    }
                }
            ))
            .toggleStyle(.switch)
        }

        // Status row
        HStack {
            Text("Status:")
                .font(.system(size: 11))
            Text(hookStatusLabel)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.6))
        }

        Divider()

        // SessionEnd behavior
        HStack {
            Text("Claude Code SessionEnd behavior:")
                .font(.system(size: 11))
            Picker("", selection: $settings.claudeCodeSessionEndBehavior) {
                ForEach(SettingsManager.ClaudeCodeSessionEndBehavior.allCases, id: \.self) { behavior in
                    Text(behavior.label).tag(behavior)
                }
            }
            .labelsHidden()
            .frame(width: 280)
        }

        // Auto handoff toggle
        Toggle("Automatically mark injected comments as Handed Off", isOn: $settings.claudeCodeAutoHandoff)
            .toggleStyle(.switch)
            .font(.system(size: 11))
    }
    .padding(20)
}

private var hookStatusLabel: String {
    switch ClaudeCodeManager.shared.hookStatus {
    case .registered: return "Hooks: Registered"
    case .notRegistered: return "Hooks: Not registered"
    case .claudeCodeNotFound: return "Claude Code not found"
    }
}
```

- [ ] **Step 4: Build and relaunch to verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

Open Preferences → verify "Claude Code" section appears between Chrome Extension and Excluded Apps.

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add Claude Code section to Preferences window"
```

---

### Task 13: Session Pill — Claude Logo

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/SessionBarView.swift`
- Add Claude logo asset to the asset catalog (or use an inline SVG/path)

- [ ] **Step 1: Add Claude logo as an asset or inline shape**

Option A (preferred): Add a `claude-logo` image to the asset catalog at `app/RemarcPackage/Sources/RemarcFeature/Resources/Assets.xcassets/`. Use a 12pt monochrome version of the Claude logomark that will be tinted with the brand orange.

Option B (fallback): Use an SF Symbol as a placeholder (e.g., `"sparkle"` or `"brain"`) and replace with the real logo later.

For now, proceed with Option B as a placeholder — the exact Claude logo asset will be added separately.

- [ ] **Step 2: Modify SessionPillView to show the Claude logo**

In `SessionBarView.swift`, find the `SessionPillView` struct (around line 200). In its body, add the logo before the session name `Text`:

```swift
// Inside the HStack of SessionPillView, before Text(session.name)
if session.origin == .claudeCode {
    Image(systemName: "sparkle")  // Placeholder — replace with Claude logo asset
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(Color(red: 0.886, green: 0.482, blue: 0.227))  // #E27B3A
}
```

The color `Color(red: 0.886, green: 0.482, blue: 0.227)` is Claude brand orange `#E27B3A` — it does NOT adapt to light/dark mode per the spec.

- [ ] **Step 3: Build and relaunch to verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

Create a test `claudeCode`-origin session via the CLI and verify the logo appears.

- [ ] **Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/SessionBarView.swift
git commit -m "feat: show Claude logo on claudeCode-origin session pills"
```

---

### Task 14: Session Picker — Claude Logo

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/SessionPickerPill.swift:275-320`

- [ ] **Step 1: Add Claude logo to SessionOptionRow**

The `SessionOptionRow` (line 275) currently takes `name: String` and `isSelected: Bool`. It needs the session's origin to show the logo. Update the struct to accept a `Session` instead, or add an `origin: SessionOrigin` parameter.

Simpler approach — add an `isClaudeCode: Bool` parameter:

```swift
private struct SessionOptionRow: View {
    let name: String
    let isSelected: Bool
    let isClaudeCode: Bool  // NEW
    let colorScheme: ColorScheme
    let onSelect: () -> Void

    var body: some View {
        // In the existing HStack, before Text(name), add:
        if isClaudeCode {
            Image(systemName: "sparkle")  // Placeholder
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(red: 0.886, green: 0.482, blue: 0.227))
        }
        // ... rest of existing body
    }
}
```

Update the call site in `SessionDropdownPanel` (around line 247):
```swift
SessionOptionRow(
    name: session.name,
    isSelected: session.id == currentSessionID,
    isClaudeCode: session.origin == .claudeCode,
    colorScheme: colorScheme,
    onSelect: { onSelect(session.id) }
)
```

- [ ] **Step 2: Build and relaunch to verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/SessionPickerPill.swift
git commit -m "feat: show Claude logo in session picker dropdown"
```

---

### Task 15: Bundle CLI and Hook Scripts in App

**Files:**
- Modify: Xcode project build phases (or Package.swift resources)
- The MCP server is already bundled — follow the same pattern

- [ ] **Step 1: Add a build phase script for CLI and hook scripts**

The MCP server is bundled via an Xcode "Run Script" build phase in `project.pbxproj`:
```bash
cp "${SRCROOT}/../mcp/dist/index.js" "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/remarc-mcp.js"
```

Add a similar build phase (or extend the existing one) to copy the CLI and hook scripts:
```bash
# CLI
cp "${SRCROOT}/../mcp/dist/cli.js" "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/remarc-cli.js"

# Hook scripts
cp "${SRCROOT}/../scripts/hooks/remarc-session-start.sh" "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/remarc-session-start.sh"
cp "${SRCROOT}/../scripts/hooks/remarc-prompt-submit.sh" "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/remarc-prompt-submit.sh"
cp "${SRCROOT}/../scripts/hooks/remarc-session-end.sh" "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/remarc-session-end.sh"

# Ensure hook scripts are executable
chmod +x "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/remarc-session-start.sh"
chmod +x "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/remarc-prompt-submit.sh"
chmod +x "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/remarc-session-end.sh"
```

Note: The CLI file is built as `dist/cli.js` but bundled as `remarc-cli.js`. This matches the `Bundle.main.url(forResource: "remarc-cli", withExtension: "js")` call in `ClaudeCodeManager`.

- [ ] **Step 2: Verify bundle references in ClaudeCodeManager**

`ClaudeCodeManager` uses `Bundle.main.url(forResource:withExtension:)` for:
- `"remarc-cli"` with extension `"js"`
- `"remarc-session-start"` with extension `"sh"`
- `"remarc-prompt-submit"` with extension `"sh"`
- `"remarc-session-end"` with extension `"sh"`

These names must match the filenames in the build phase above.

- [ ] **Step 3: Update ClaudeCodeManager to reference bundled paths**

Verify that `Bundle.main.url(forResource:withExtension:)` resolves correctly for all four files.

- [ ] **Step 4: Build and verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

Check the built app bundle:
```bash
ls app/DerivedData/Build/Products/Debug/Remarc.app/Contents/Resources/ | grep -E "remarc|session|prompt"
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: bundle CLI and hook scripts in app resources"
```

---

## Chunk 5: Integration Testing

### Task 16: End-to-End Manual Test

- [ ] **Step 1: Build everything**

```bash
cd mcp && npm run build
cd ../app && xcodebuild clean build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```

- [ ] **Step 2: Launch Remarc and enable integration**

```bash
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

Open Preferences → Claude Code → Enable integration. Verify status shows "Hooks: Registered".

- [ ] **Step 3: Verify hooks in Claude Code settings**

```bash
cat ~/.claude/settings.json | python3 -m json.tool
```

Should show `SessionStart`, `UserPromptSubmit`, `SessionEnd` hook entries with Remarc scripts.

- [ ] **Step 4: Test session lifecycle**

Start a Claude Code session in any directory and verify:
1. A Remarc session appears in the app with Claude logo
2. Make a comment in Remarc
3. Send a message in Claude Code — comment should be injected
4. Comment status should change to "Handed Off" in Remarc
5. Exit Claude Code — session cleaned up per preference

- [ ] **Step 5: Test edge cases**

- Create a comment, hand it off, then reopen it in Remarc UI → should re-inject on next message
- Delete a comment after handoff → no crash
- Delete the Remarc session mid-Claude-session → CLI returns empty gracefully
- Test with "Keep session" preference → session survives SessionEnd
- Test with "Move unresolved to Inbox" → unresolved comments appear in Inbox

---

## Summary

| Chunk | Tasks | Focus |
|-------|-------|-------|
| 1: Data Model Foundation | 1-4 | CommentStatus, Session model, TypeScript types, PersistenceManager fix |
| 2: CLI Implementation | 5-8 | CLI scaffolding, create-session, handoff, wind-down |
| 3: Hooks & Registration | 9-11 | Hook scripts, SettingsManager, ClaudeCodeManager |
| 4: UI Changes | 12-15 | Preferences section, session pill logo, picker logo, bundling |
| 5: Integration Testing | 16 | End-to-end verification |
