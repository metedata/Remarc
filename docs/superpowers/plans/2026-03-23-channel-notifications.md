# Channel Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add experimental support for Claude Code channel notifications so new Remarc comments are pushed into the linked Claude Code session in real-time, instead of waiting for Claude to poll via tools.

**Architecture:** The MCP server gains a file watcher on `comments.json`. When a change is detected, it diffs old vs new state and pushes new/updated comments to Claude via `notifications/claude/channel`. This is gated behind a UserDefaults setting (`claudeCodeChannelEnabled`, default off) that the MCP server reads at startup via `defaults read`. A new "Real-time Notifications" section is added to the Claude Integration settings tab with a toggle and setup instructions.

**Tech Stack:** TypeScript (MCP server, `@modelcontextprotocol/sdk`), Swift/SwiftUI (settings UI)

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `mcp/src/index.ts` | Modify | Add `experimental: { "claude/channel": {} }` capability, expose `server` reference, start channel watcher |
| `mcp/src/channel.ts` | Create | File watcher, state diffing, notification dispatch - all channel logic in one module |
| `mcp/src/tools.ts` | Modify | Track linked session ID when `remarc_create_session` or `remarc_list_comments` is called |
| `mcp/src/data.ts` | No change | Already has `readAppState`, `getDataFilePath` |
| `mcp/src/notify.ts` | No change | Existing DistributedNotification helper (app -> MCP direction) |
| `app/.../SettingsManager.swift` | Modify | Add `claudeCodeChannelEnabled` setting key + published property |
| `app/.../PreferencesWindowController.swift` | Modify | Add "Real-time Notifications" section to Claude Integration tab |

---

### Task 1: Add channel capability to MCP server

**Files:**
- Modify: `mcp/src/index.ts`

The `McpServer` high-level class doesn't accept `experimental` capabilities directly. We need to pass them via the `ServerOptions.capabilities` object and access `server.server` for notifications.

- [ ] **Step 1: Update McpServer constructor to declare channel capability**

In `mcp/src/index.ts`, update the McpServer constructor to include the experimental channel capability. The channel should only be active when the user has opted in via UserDefaults.

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerTools } from "./tools.js";
import { startChannelWatcher } from "./channel.js";
import { execSync } from "node:child_process";

// Check if channel notifications are enabled via macOS UserDefaults
let channelEnabled = false;
try {
  const result = execSync(
    "defaults read com.metepolat.Remarc claudeCodeChannelEnabled",
    { encoding: "utf-8", timeout: 3000, stdio: ["pipe", "pipe", "pipe"] }
  ).trim();
  channelEnabled = result === "1";
} catch {
  // Key not set or defaults command failed - channel stays disabled
}

const server = new McpServer(
  {
    name: "remarc",
    version: "0.1.0",
  },
  {
    capabilities: channelEnabled
      ? { experimental: { "claude/channel": {} } as Record<string, object> }
      : undefined,
    instructions:
      'Remarc is a macOS contextual commenting app. Comments have short IDs (first 5 UUID chars, e.g. \'a3f2b\'). After addressing a comment, call remarc_set_status with status "resolved" and a brief summary of what you did. When resolving multiple comments, use remarc_bulk_set_status to save context.' +
      (channelEnabled
        ? "\n\nReal-time notifications are enabled. New comments from the user will appear as <channel source=\"remarc\"> messages. When you receive one, acknowledge it and address it promptly."
        : ""),
  }
);

registerTools(server);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Remarc MCP server running on stdio");

  if (channelEnabled) {
    startChannelWatcher(server);
    console.error("Channel notifications enabled");
  }
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
```

- [ ] **Step 2: Create stub channel.ts so the build passes**

Create `mcp/src/channel.ts` with stub exports (will be implemented in Task 2):

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

export function setLinkedSession(_sessionId: string): void {}
export function getLinkedSession(): string | null { return null; }
export function startChannelWatcher(_server: McpServer): void {}
```

- [ ] **Step 3: Build and verify no errors**

Run: `cd /Users/mete/Developer/Remarc/mcp && npm run build:mcp`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add mcp/src/index.ts mcp/src/channel.ts
git commit -m "feat: add channel capability declaration to MCP server"
```

---

### Task 2: Create channel watcher module

**Files:**
- Create: `mcp/src/channel.ts`

This module watches `comments.json` for changes, diffs old vs new state, and pushes notifications for new or updated comments that belong to the linked session.

- [ ] **Step 1: Create channel.ts with file watcher and diff logic**

```typescript
import { watch, type FSWatcher } from "node:fs";
import { dirname, basename } from "node:path";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  readAppState,
  getDataFilePath,
  typeIdentifier,
  formatDate,
  type AppState,
  type Comment,
} from "./data.js";

/** The Remarc session ID this MCP process is linked to. Set by tools. */
let linkedSessionId: string | null = null;

/** Previous state snapshot for diffing. */
let previousState: AppState | null = null;

/** Reference to the MCP server for sending notifications. */
let mcpServer: McpServer | null = null;

/** File watcher instance. */
let watcher: FSWatcher | null = null;

/** Debounce timer to coalesce rapid file changes. */
let debounceTimer: ReturnType<typeof setTimeout> | null = null;
const DEBOUNCE_MS = 300;

/**
 * Set the linked Remarc session ID for this MCP process.
 * Called from tools.ts when a session is created or comments are listed.
 */
export function setLinkedSession(sessionId: string): void {
  linkedSessionId = sessionId;
}

/** Get the current linked session ID. */
export function getLinkedSession(): string | null {
  return linkedSessionId;
}

/**
 * Start watching comments.json for changes and push channel notifications.
 */
export function startChannelWatcher(server: McpServer): void {
  mcpServer = server;

  const dataFile = getDataFilePath();

  // Snapshot initial state
  readAppState().then((state) => {
    previousState = state;
  }).catch(() => {
    // Non-critical - first diff will treat everything as new
  });

  // IMPORTANT: Watch the directory, not the file directly. On macOS, fs.watch()
  // uses kqueue which tracks inodes. Atomic writes (tmp + rename) replace the
  // inode, causing a direct file watcher to silently stop after the first write.
  const dataDir = dirname(dataFile);
  const dataBasename = basename(dataFile);

  try {
    watcher = watch(dataDir, { persistent: false }, (_eventType, filename) => {
      if (filename !== dataBasename) return;
      // Debounce: Remarc writes atomically (tmp + rename), which can fire
      // multiple events. Coalesce into a single diff.
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(() => handleFileChange(), DEBOUNCE_MS);
    });

    watcher.on("error", (err) => {
      console.error(`[channel] Watcher error: ${err.message}`);
    });
  } catch (err) {
    console.error(`[channel] Failed to start watcher: ${err}`);
  }
}

async function handleFileChange(): Promise<void> {
  if (!mcpServer || !linkedSessionId) return;

  try {
    const newState = await readAppState();
    if (!newState) return;

    const changes = diffComments(previousState, newState, linkedSessionId);
    previousState = newState;

    for (const change of changes) {
      await pushNotification(change);
    }
  } catch (err) {
    console.error(`[channel] Diff error: ${err}`);
  }
}

interface CommentChange {
  type: "new" | "updated" | "deleted";
  comment: Comment;
}

function diffComments(
  oldState: AppState | null,
  newState: AppState,
  sessionId: string
): CommentChange[] {
  const changes: CommentChange[] = [];

  const newComments = newState.comments.filter(
    (c) => c.sessionID.toUpperCase() === sessionId.toUpperCase() && !c.isDeleted
  );

  const oldMap = new Map<string, Comment>();
  if (oldState) {
    for (const c of oldState.comments) {
      oldMap.set(c.id, c);
    }
  }

  for (const comment of newComments) {
    const old = oldMap.get(comment.id);
    if (!old) {
      // New comment
      changes.push({ type: "new", comment });
    } else if (old.updatedAt.getTime() !== comment.updatedAt.getTime()) {
      // Updated - but only notify if the change came from the app, not from
      // this MCP process (i.e., skip status changes we made ourselves).
      // Heuristic: if the status changed to resolved/inProgress and resolvedBy
      // is "claude", we made that change - skip it.
      if (comment.resolvedBy === "claude" && comment.status !== old.status) {
        continue;
      }
      changes.push({ type: "updated", comment });
    }
  }

  // Check for deletions
  if (oldState) {
    const oldComments = oldState.comments.filter(
      (c) => c.sessionID.toUpperCase() === sessionId.toUpperCase() && !c.isDeleted
    );
    const newIds = new Set(newComments.map((c) => c.id));
    for (const old of oldComments) {
      if (!newIds.has(old.id)) {
        changes.push({ type: "deleted", comment: old });
      }
    }
  }

  return changes;
}

async function pushNotification(change: CommentChange): Promise<void> {
  if (!mcpServer) return;

  const { type, comment } = change;
  const lowLevelServer = mcpServer.server;

  let content: string;
  switch (type) {
    case "new":
      content = formatNewComment(comment);
      break;
    case "updated":
      content = `Comment ${comment.shortID} was updated: "${comment.commentText}"`;
      break;
    case "deleted":
      content = `Comment ${comment.shortID} was deleted.`;
      break;
  }

  try {
    await (lowLevelServer as any).notification({
      method: "notifications/claude/channel",
      params: {
        content,
        meta: {
          comment_id: comment.shortID,
          event_type: type,
          comment_type: typeIdentifier(comment.type),
          source: comment.source,
        },
      },
    });
    console.error(`[channel] Pushed ${type} notification for ${comment.shortID}`);
  } catch (err) {
    console.error(`[channel] Failed to push notification: ${err}`);
  }
}

function formatNewComment(comment: Comment): string {
  const lines: string[] = [];
  lines.push(`New comment [${comment.shortID}]: ${comment.commentText}`);

  if ("comment" in comment.type) {
    lines.push(`Selected text: "${comment.type.comment.text}"`);
  }

  if (comment.source) {
    lines.push(`Source: ${comment.source}`);
  }

  lines.push(`Type: ${typeIdentifier(comment.type)}`);

  return lines.join("\n");
}
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/mete/Developer/Remarc/mcp && npm run build:mcp`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add mcp/src/channel.ts
git commit -m "feat: add channel watcher for real-time comment notifications"
```

---

### Task 3: Wire session linkage from tools

**Files:**
- Modify: `mcp/src/tools.ts`

When `remarc_create_session` is called, we know the Claude Code session is linked to a Remarc session. We need to call `setLinkedSession()` so the channel watcher knows which comments to push.

- [ ] **Step 1: Import and call setLinkedSession in tools.ts**

Add import at the top of `mcp/src/tools.ts`:

```typescript
import { setLinkedSession } from "./channel.js";
```

In the `remarc_create_session` handler, after `state.activeSessionID = sessionId;`, add:

```typescript
setLinkedSession(sessionId);
```

In the `remarc_list_comments` handler, when a `session_id` filter is provided, add session linkage as a side effect (so that if a session was created by the CLI hook rather than the tool, the channel still activates):

```typescript
if (session_id) {
  comments = comments.filter((c) => c.sessionID === session_id);
  setLinkedSession(session_id);
}
```

- [ ] **Step 2: Also link session from CLI-created sessions**

The CLI `create-session` command writes a marker file. When the MCP server starts, it doesn't automatically know which session it belongs to. The handoff hook calls `remarc_list_comments --session-id`, which will trigger the linkage above. This covers the common flow.

For the startup case: in `mcp/src/index.ts`, after connecting, check for an active session with a `claudeCodeSessionId` and link it:

```typescript
if (channelEnabled) {
  // Try to auto-link the active session
  const { readAppState } = await import("./data.js");
  const { setLinkedSession } = await import("./channel.js");
  const state = await readAppState();
  if (state?.activeSessionID) {
    const activeSession = state.sessions.find(
      (s) => s.id === state.activeSessionID && !s.isDeleted && s.origin === "claudeCode"
    );
    if (activeSession) {
      setLinkedSession(activeSession.id);
      console.error(`[channel] Auto-linked to session ${activeSession.id}`);
    }
  }
  startChannelWatcher(server);
  console.error("Channel notifications enabled");
}
```

- [ ] **Step 3: Build and verify**

Run: `cd /Users/mete/Developer/Remarc/mcp && npm run build:mcp`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add mcp/src/tools.ts mcp/src/index.ts
git commit -m "feat: wire session linkage for channel notifications"
```

---

### Task 4: Add setting to SettingsManager

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift`

- [ ] **Step 1: Add the setting key and published property**

In the `Keys` enum, add after `mcpUserDisabled`:

```swift
static let claudeCodeChannelEnabled = "claudeCodeChannelEnabled"
```

In the Claude Code Integration MARK section, add after `mcpUserDisabled`:

```swift
@Published public var claudeCodeChannelEnabled: Bool {
    didSet { defaults.set(claudeCodeChannelEnabled, forKey: Keys.claudeCodeChannelEnabled) }
}
```

In `init()`, in the Claude Code Integration block (after `self.mcpUserDisabled = ...`), add:

```swift
self.claudeCodeChannelEnabled = defaults.bool(forKey: Keys.claudeCodeChannelEnabled)
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/mete/Developer/Remarc/app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift
git commit -m "feat: add claudeCodeChannelEnabled setting"
```

---

### Task 5: Add settings UI for channel notifications

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

- [ ] **Step 1: Add Real-time Notifications section to Claude Integration tab**

In the `claudeCodeSection` computed property, after the `Divider` (line ~1498) and before `claudeDesktopSection`, add a new section:

```swift
// Real-time Notifications (Experimental)
VStack(alignment: .leading, spacing: Self.itemSpacing) {
    sectionHeader(
        "Real-time Notifications",
        description: "Push new comments directly into your Claude Code session as they're created, instead of waiting for the next prompt.",
        badge: "Experimental",
        badgeTooltip: "This feature requires Claude Code v2.1.80+ and uses an experimental protocol extension. It may not work with all Claude Code configurations."
    )

    toggleRow("Enable channel notifications", isOn: $settings.claudeCodeChannelEnabled, disabled: !settings.claudeCodeEnabled)

    if settings.claudeCodeChannelEnabled {
        VStack(alignment: .leading, spacing: 8) {
            Text("To activate, launch Claude Code with:")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.6))

            Text("claude --dangerously-load-development-channels server:remarc")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.7))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                )

            Text("Comments you create in Remarc will appear in Claude's conversation immediately. Claude Code must be logged in via claude.ai (not API key).")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

Divider()
    .padding(.vertical, 4)
```

- [ ] **Step 2: Build and verify**

Run: `cd /Users/mete/Developer/Remarc/app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Relaunch and verify UI**

```bash
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

Open Settings > Claude Integration. Verify the "Real-time Notifications" section appears with toggle (disabled when integration is off), and enabling it shows the launch command.

- [ ] **Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add channel notifications toggle to Claude Integration settings"
```

---

### Task 6: End-to-end test

- [ ] **Step 1: Enable the setting**

Open Remarc Settings > Claude Integration. Toggle on "Enable channel notifications".

- [ ] **Step 2: Rebuild MCP server**

```bash
cd /Users/mete/Developer/Remarc/mcp && npm run build:mcp
```

- [ ] **Step 3: Verify MCP server reads the setting**

```bash
defaults read com.metepolat.Remarc claudeCodeChannelEnabled
# Should output: 1
```

- [ ] **Step 4: Test with Claude Code**

Launch Claude Code with channels enabled:

```bash
claude --dangerously-load-development-channels server:remarc
```

Create a Remarc session, then make a comment in Remarc. Verify the comment appears as a `<channel source="remarc">` message in the Claude Code session.

- [ ] **Step 5: Test graceful degradation**

Launch Claude Code normally (without `--channels` flag). Verify the MCP server works as before - tools are available, no errors in stderr.

- [ ] **Step 6: Test with setting disabled**

```bash
defaults write com.metepolat.Remarc claudeCodeChannelEnabled -bool NO
```

Rebuild MCP server and launch with channels flag. Verify no channel capability is declared and no file watcher starts.
