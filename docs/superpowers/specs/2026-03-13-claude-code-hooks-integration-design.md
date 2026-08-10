# Claude Code Hooks Integration

**Date:** 2026-03-13
**Status:** Approved

## Overview

Integrate Remarc with Claude Code via hooks so that commenting workflows are automatic and invisible. When a user starts a Claude Code session, a Remarc session is created. Comments made in Remarc are silently attached to the user's messages in Claude Code. Claude sees them, works through them, and resolves them via existing MCP tools. When the session ends, cleanup happens per user preference.

## Goals

- Zero-friction comment delivery: no manual `/remarc` invocation or copy-pasting
- Automatic session lifecycle tied to Claude Code sessions
- Preserve existing MCP tools for Claude's interactions (resolve, set status)
- User control over session cleanup behavior

## Non-Goals

- Git branch/worktree-based session identity (future enhancement)
- Multi-agent support (Cursor, Windsurf — future)
- Auto-detection of orphaned sessions after crashes (too complex for v1)
- Replacing MCP tools with CLI (CLI is only for hooks; Claude still uses MCP)

---

## 1. Data Model: `handedOff` Status

### Comment Status Lifecycle

```
open → handedOff → inProgress → resolved
 ↑         │
 └─────────┘  (user reopens in UI)
```

`handedOff` means the comment has been delivered to a consumer (injected into Claude Code context, copied to clipboard, exported). It is an intermediate state between "nobody has seen this" and "someone is working on it."

### Swift Changes

Add `.handedOff` case to `CommentStatus` enum with raw value `"handedOff"`.

- UI shows a "Handed Off" chip/badge (same pattern as existing status badges)
- User can change status back to `open` from the UI (re-enables injection on next message)
- User cannot manually set a comment TO `handedOff` — only set programmatically by the CLI or via export/copy actions

### TypeScript Changes

Add `"handedOff"` to the status type in `data.ts`. Update `remarc_list_comments` to accept it as a filter value. Do NOT add `handedOff` to `remarc_set_status`'s accepted values — it should only be set programmatically by the CLI, not by Claude via MCP.

### No Changes to Resolved Logic

`resolvedBy`, `resolvedAt`, `resolutionSummary` remain unchanged.

---

## 2. Session Model Changes

### New Fields on Session

```swift
struct Session {
    // ... existing fields
    origin: SessionOrigin           // .manual or .claudeCode
    claudeCodeSessionId: String?    // Claude Code's session_id, nil for manual sessions
}

enum SessionOrigin: String, Codable {
    case manual      // Created by user in Remarc UI (default)
    case claudeCode  // Created by Claude Code SessionStart hook
}
```

Existing sessions default to `.manual` and `nil` for `claudeCodeSessionId`. Both fields are optional in the JSON schema — older versions of Remarc will silently ignore them (Swift `Codable` skips unknown keys), so this is backward-compatible.

### TypeScript Changes

Add `origin?: string` and `claudeCodeSessionId?: string` to the `RawSession` and `Session` types in `data.ts`. Update `parseSession()` and `serializeSession()` to handle these fields. Both are optional with no default — existing sessions remain unaffected.

### UI Indicator

Sessions with `origin == .claudeCode` display the Claude logomark in brand orange (`#E27B3A`) to the left of the session name. This appears in:

1. Session pills in the main app window (horizontal chip list)
2. Session picker in the comment editor dropdown

The logo does not adapt to light/dark mode — it stays orange in both. No logo for `.manual` sessions.

---

## 3. Node.js CLI

### Architecture

New entry point `mcp/src/cli.ts` alongside `mcp/src/index.ts`. Imports the same `loadState()`, `saveState()`, `notifyRemarcReload()` from existing modules. Compiled to `mcp/dist/cli.js` alongside the MCP server.

### Commands

**`create-session`**
```bash
node remarc-cli.js create-session --name "Claude: <cwd_basename>" --claude-session-id <id> [--source startup|resume]
```
- With `--source startup` (default): creates a new Remarc session
  - Checks `maxActiveSessions` limit (currently 8). If at limit, auto-dismisses the oldest (by `createdAt`) `claudeCode`-origin session. If all sessions are manual, fails with an error message.
  - Creates a new session with `origin: "claudeCode"` and `claudeCodeSessionId` set
  - Sets it as the active session (`activeSessionID`)
- With `--source resume`: looks up existing session by `claudeCodeSessionId`
  - If found: reactivates it (sets as `activeSessionID`), returns its UUID
  - If not found: falls back to `--source startup` behavior (creates new)
- Notifies Remarc to reload
- Outputs JSON: `{ "remarc_session_id": "<uuid>", "data_file_path": "<resolved path>" }`
- The `data_file_path` is the resolved path to `comments.json` (or `data.json` for legacy installs), determined by the same `getDataFilePath()` logic used by the MCP server

**`handoff`**
```bash
node remarc-cli.js handoff --session-id <remarc_uuid> [--recovery]
```
- Without `--recovery`: reads comments with `status == "open"`, marks them as `handedOff`
- With `--recovery`: reads comments with `status == "open"`, `"handedOff"`, or `"inProgress"`. Does NOT change any statuses (this is a read-only context recovery after compaction). Prepends the integration context message before the comment list.
- Notifies Remarc to reload (only when statuses were changed, i.e., without `--recovery`)
- Outputs JSON to stdout. The hook shell script passes this through directly as its own stdout, which Claude Code reads as the hook's response:
```json
{
  "hookSpecificOutput": {
    "additionalContext": "## Remarc Comments (2 new)\n\n### [a3f2b] Fix padding on cards\n> Selected text: \"The card has 24px padding on all sides\"\nSource: Figma — Design Review\n\n### [b7c1d] Color doesn't match design\n> Selected text: \"Header background should be #1a1a2e\"\nSource: localhost:3000/dashboard"
  }
}
```
- Each comment includes: short ID, comment text, reference/selected text (if any), and source app/URL — giving Claude enough context to act on the comment
- If no matching comments, outputs nothing to stdout (no context injected)
- All output uses the `hookSpecificOutput.additionalContext` JSON wrapper — this is the same format for SessionStart, UserPromptSubmit, and all hook outputs

**`wind-down`**
```bash
node remarc-cli.js wind-down --session-id <remarc_uuid>
```
- Reads user preference from UserDefaults via `defaults read com.metepolat.Remarc claudeCodeSessionEndBehavior`. Note: `defaults read` reads from `cfprefsd`'s cache, which is typically in sync but can lag by milliseconds. This is acceptable — the preference rarely changes mid-session.
- Executes the preference:
  - `autoDelete`: Delete session and all its comments
  - `keep`: Leave session as-is
  - `moveUnresolved`: Delete session, move comments with status `open`, `handedOff`, or `inProgress` to the Inbox session. The CLI finds Inbox by name (`AppConstants.inboxSessionName`). If Inbox doesn't exist (user deleted it), the CLI creates it before moving comments.
- Notifies Remarc to reload

### Bundling

The CLI is bundled in the app alongside the MCP server. `ClaudeCodeManager` (new service, see Section 6) copies `cli.js` to a stable path and references it in hook configuration.

### Atomic Writes and Concurrency

All CLI commands that modify `comments.json` must use atomic writes (write to temp file, then rename). The existing `saveState()` in `data.ts` already does this.

**Race condition with PersistenceManager:** Remarc's `PersistenceManager` uses a 250ms debounced save — it keeps state in memory and writes periodically. If the CLI writes to disk and sends `notifyRemarcReload()`, PersistenceManager must cancel any pending debounced save before reloading from disk. Otherwise the debounced save could overwrite the CLI's changes with stale in-memory state.

**Mitigation:** The existing `notifyRemarcReload()` distributed notification triggers `PersistenceManager.reloadFromDisk()`. This method must be updated to cancel any pending debounced save before loading, ensuring the disk state (which includes the CLI's changes) takes precedence over in-memory state.

---

## 4. Cache Layer: mtime-Based Fast Path

The `UserPromptSubmit` hook fires on every message. The cache layer ensures zero cost when there are no new comments.

### Flow

```
UserPromptSubmit fires
        │
  Read marker file → get data_file_path
  and remarc_session_id
        │
  data_file_path newer than
  marker file? (shell test -nt, ~1ms)
        │
   ┌────┴────┐
   No        Yes
   │         │
   Exit 0    node remarc-cli.js handoff --session-id <uuid>
   (no output)     │
              Returns additionalContext JSON
                   │
              Touch marker file
```

### Marker File

Path: `/tmp/remarc-claude-<claude_session_id>.marker`

The marker file serves two purposes: (1) mtime comparison for the cache layer, and (2) persisting the Remarc session UUID and data file path so subsequent hooks can find them.

**Contents** (line-based format — avoids `jq` dependency, readable with `head`/`sed`):
```
<remarc_session_id>
<data_file_path>
```
Example:
```
a1b2c3d4-e5f6-7890-abcd-ef1234567890
/Users/x/Library/Application Support/Remarc/comments.json
```

This solves the inter-hook state problem: Claude Code hooks run as independent processes with no shared state. The `SessionStart` hook writes the marker file from `create-session` output. Subsequent hooks read line 1 (`head -1`) for the session UUID and line 2 (`sed -n '2p'`) for the data file path, then pass them to CLI commands. No `jq` or JSON parsing required.

**Lifecycle:**
- Created by `SessionStart` hook (extracts `remarc_session_id` and `data_file_path` from `create-session` JSON output, writes as two lines)
- Touched after each successful `handoff` (updates mtime for cache layer)
- Deleted by `SessionEnd` hook
- Cleared by OS on reboot

### False Positives

Any change to `comments.json` triggers the CLI — even changes in other sessions. The CLI checks for `status == "open"` in the specific session and returns empty if nothing to hand off. Cost: ~150ms for a no-op Node.js invocation. Acceptable.

### False Negatives

None. Every write to `comments.json` updates its mtime.

---

## 5. Hook Scripts

Three hooks configured in `~/.claude/settings.json`.

### SessionStart

**Triggers:** `startup`, `resume`, `compact`, `clear`

The hook shell script reads `source` from the stdin JSON (via `python3 -c` or grep — see below) and branches:

**Behavior by source:**

| Source | Behavior |
|--------|----------|
| `startup` | `create-session --source startup` → write marker file from output → output integration context via `hookSpecificOutput.additionalContext`. |
| `resume` | `create-session --source resume` → write/update marker file → `handoff --recovery` → output integration context + outstanding comments. |
| `compact` | Read existing marker file → `handoff --recovery` → output integration context + outstanding comments. |
| `clear` | Same as `compact`. |

**Reading stdin JSON without `jq`:** The hook script uses `python3` (ships with macOS) to parse the small JSON from stdin:
```bash
INPUT=$(cat)
SOURCE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('source',''))")
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))")
```

**Integration context** (injected on startup, resume, compact, and clear — Claude needs this to know how to interact with Remarc):
> "A Remarc session has been created for this Claude Code session. Comments made in Remarc will be automatically attached to your messages. When you address a comment, use the `remarc_set_status` MCP tool to mark it as inProgress or resolved."

### UserPromptSubmit

**Triggers:** Every user message (no matcher support)

**Behavior:**
1. Read `session_id` from stdin JSON (via `python3 -c`, same pattern as SessionStart)
2. Construct marker file path: `/tmp/remarc-claude-<session_id>.marker`
3. If marker file doesn't exist → exit 0 (integration not active for this session)
4. Read `remarc_session_id` from marker file line 1 (`head -1`) and `data_file_path` from line 2 (`sed -n '2p'`)
5. Compare `data_file_path` mtime vs marker file mtime (shell `test -nt`, ~1ms)
6. If unchanged → exit 0 (no output, no context injected)
7. If changed → `node remarc-cli.js handoff --session-id <remarc_session_id>`
8. Touch marker file (updates mtime for next comparison)
9. Pass the CLI's stdout through as the hook's stdout (Claude Code reads `hookSpecificOutput.additionalContext`)

### SessionEnd

**Triggers:** Session termination

**Behavior:**
1. Read `session_id` from stdin JSON
2. Read `remarc_session_id` from marker file
3. `node remarc-cli.js wind-down --session-id <remarc_session_id>`
4. Delete marker file

---

## 6. Settings: Claude Code Section

New section in `PreferencesWindowController`, placed after "Chrome Extension" and before "Excluded Apps" (logically groups integrations together).

### Section Description

"Creates a Remarc session when you start a Claude Code session. Comments you make are automatically attached to your messages so Claude can see and address them. Sessions are cleaned up when the session ends. Powered by Claude Code hooks."

### Settings

**Enable Claude Code integration** (toggle, default: off)
- On: registers hooks in `~/.claude/settings.json`, installs CLI
- Off: removes hooks from config

**Claude Code SessionEnd behavior** (picker, default: "Delete session")
- **Delete session** — delete session and all its comments
- **Keep session** — leave session as-is
- **Delete session, move unresolved comments to Inbox** — delete session but preserve `open`, `handedOff`, and `inProgress` comments by moving them to Inbox

**Automatically mark injected comments as Handed Off** (toggle, default: on)
- On: `handoff` CLI command sets status to `handedOff`
- Off: comments stay `open` after injection (re-injected every message)

**Status row** (read-only, three states)
- "Hooks: Registered" — integration is active
- "Hooks: Not registered" — integration enabled but hooks missing (user removed manually or registration failed)
- "Claude Code not found" — `claude` binary not on PATH

### Storage

All settings stored via `SettingsManager` + UserDefaults, following existing `@Published` + `didSet` pattern. Keys prefixed with `claudeCode` (e.g., `claudeCodeSessionEndBehavior`).

### ClaudeCodeManager Service

New service (similar to `MCPManager`) responsible for:
- Detecting Claude Code installation (checks for `claude` binary)
- Registering/deregistering hooks in `~/.claude/settings.json`
- Copying CLI to stable path alongside MCP server
- Re-registering on app launch (idempotent, fixes stale paths after upgrades)

---

## 7. Hook Registration (Config Management)

### Identifying Remarc Hooks

All Remarc hook entries include a consistent command prefix or identifiable path so they can be found and replaced without disturbing user-created hooks.

### Registration Flow

1. Read `~/.claude/settings.json` (create if doesn't exist)
2. Parse existing hooks object
3. Append Remarc entries to `SessionStart`, `UserPromptSubmit`, `SessionEnd` arrays (never overwrite)
4. Write back atomically (backup original first)

### Deregistration Flow

1. Read `~/.claude/settings.json`
2. Remove entries containing the Remarc CLI path from all hook arrays
3. Write back atomically

### Edge Cases

| Edge case | Mitigation |
|-----------|-----------|
| File doesn't exist | Create with only Remarc hooks |
| `~/.claude/` doesn't exist | Claude Code not installed; no-op, show status in settings |
| Existing hooks in arrays | Append, never overwrite |
| User manually removes hooks | Respect removal. Show "Not registered" in settings status. Don't silently re-add. |
| Stale CLI path after app upgrade | Re-register on every launch (path recomputed from current bundle) |
| Concurrent writes | Atomic read-merge-write with backup |

---

## 8. Edge Cases and Resilience

### Config Management
- Hooks identified by Remarc CLI path so they can be found/replaced
- Re-register on every app launch (idempotent)
- Graceful no-op if Claude Code not installed
- Respect manual removal — surface in status row, don't silently re-add

### Session Lifecycle
- **Crash/force-quit Claude Code**: Session persists with Claude logo (orange). No auto-deletion. User cleans up manually or it reconnects on resume.
- **Crash/force-quit Remarc**: CLI still reads/writes `comments.json`. `notifyRemarcReload()` silently fails. App reloads from disk on relaunch.
- **Laptop restart**: `/tmp` cleared (marker files gone). Sessions persist in `comments.json`. User starts fresh next Claude Code session.
- **Resume after crash**: `SessionStart` with `source: "resume"` matches `session_id` to existing Remarc session, reconnects.
- **Deleted session mid-Claude-session**: CLI returns empty gracefully. Hook outputs nothing. Claude continues.

### Comment Lifecycle
- **User reopens handed-off comment**: Status goes back to `open`. Hook re-injects on next message (queries `status == "open"`).
- **User deletes comment after handoff**: No impact. Hook queries by status, not by ID.
- **Context compaction**: `SessionStart` with `source: "compact"` re-injects `handedOff` + `inProgress` comments for recovery.

### Multiple Simultaneous Claude Code Sessions
Last `SessionStart` to fire wins the active Remarc session. Comments go to whichever session was most recently activated. Documented limitation for v1.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│ Claude Code                                             │
│                                                         │
│  SessionStart hook ──→ remarc-cli create-session        │
│                         → creates Remarc session        │
│                         → sets active                   │
│                         → creates marker file           │
│                         → injects integration context   │
│                                                         │
│  UserPromptSubmit hook                                  │
│    1. mtime check (shell, ~1ms)                         │
│    2. if changed → remarc-cli handoff                   │
│       → reads open comments                             │
│       → marks as handedOff                              │
│       → returns additionalContext                       │
│    3. touch marker file                                 │
│                                                         │
│  Claude sees comments ──→ remarc_set_status (MCP)       │
│                           → marks inProgress/resolved   │
│                                                         │
│  SessionEnd hook ──→ remarc-cli wind-down               │
│                      → applies user preference          │
│                      → deletes marker file              │
└─────────────────────────────────────────────────────────┘
         │                              │
         │ CLI (Node.js)                │ MCP (stdio)
         ▼                              ▼
┌─────────────────────────────────────────────────────────┐
│ comments.json ← notifyRemarcReload() → Remarc App      │
│                                                         │
│  Settings: ClaudeCodeManager                            │
│    - Hook registration in ~/.claude/settings.json       │
│    - CLI bundling                                       │
│    - Integration toggle                                 │
│    - SessionEnd behavior preference                     │
└─────────────────────────────────────────────────────────┘
```

## Future Enhancements

- **Git-based session identity**: Tie sessions to repo+branch for persistence across Claude Code restarts. Eliminates orphan problem entirely.
- **Multi-agent support**: Extend hooks/CLI for Cursor, Windsurf, and other AI coding tools.
- **Connected/disconnected state**: Visual indicator in Remarc UI showing whether the Claude Code session is still alive (requires reliable process detection).
- **Bidirectional sync**: Push comment status changes from Claude Code back to Remarc in real-time (currently relies on MCP tool calls + file reload).
