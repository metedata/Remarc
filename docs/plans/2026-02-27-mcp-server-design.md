# Remarc MCP Server — Design Document

**Date:** 2026-02-27
**Status:** Approved

## Overview

A TypeScript MCP (Model Context Protocol) server that gives Claude Code direct read/write access to Remarc comments. Users leave comments in Remarc, tell Claude to read them, and Claude resolves them with summaries of what was done — all without copy-pasting.

## Scope (MVP)

### MCP Tools (5)

| Tool | Params | Description |
|---|---|---|
| `remarc_list_sessions` | — | Returns all active (non-deleted) sessions |
| `remarc_list_comments` | `session_id?`, `status?` | Returns comments, filterable by session and open/resolved |
| `remarc_get_comment` | `comment_id` | Single comment with full detail |
| `remarc_resolve` | `comment_id`, `summary` | Marks comment as resolved with summary of what was done |
| `remarc_reopen` | `comment_id` | Reopens a resolved comment |

### Data Model Changes (Swift)

**Rename:** `Stack` → `Session` throughout (model, JSON keys, UI references).

**Multi-session support:** Users can have multiple active sessions. Each session is an independent collection of comments.

**New fields on Comment:**
- `status: CommentStatus` — enum `.open` | `.resolved`, defaults to `.open`
- `resolutionSummary: String?` — what was done to resolve
- `resolvedBy: String?` — e.g. `"claude"`
- `resolvedAt: Date?`

Backward compatible: old comments without `status` decode as `.open`.

## Architecture

### MCP Server (TypeScript, stdio transport)

Lives at `mcp/` in the repo root:

```
mcp/
├── package.json
├── tsconfig.json
├── esbuild.config.ts
└── src/
    ├── index.ts        # Server setup, stdio transport
    ├── tools.ts        # 5 tool definitions
    ├── data.ts         # Read/write comments.json, TypeScript types
    └── notify.ts       # DistributedNotification helper via osascript
```

**Stack:** `@modelcontextprotocol/sdk` (McpServer + StdioServerTransport), Zod for input schemas.

**Data access:** Reads/writes `~/Library/Application Support/Remarc/comments.json` directly.

### Write Coordination

1. MCP server reads file, deserializes, modifies in memory
2. Writes atomically (write to `.tmp`, rename over original)
3. Posts `DistributedNotification` (`com.metepolat.Remarc.reload`) via `osascript` to trigger UI reload

**Remarc app side:** `PersistenceManager` adds a `DistributedNotificationCenter` observer for `com.metepolat.Remarc.reload`. On notification, reloads `comments.json` from disk and publishes the updated state.

**Race conditions:** MCP tool calls are sequential from Claude's perspective. The atomic write + notification pattern is safe in practice. The app's 250ms debounced save doesn't conflict because the notification triggers a reload that overwrites in-memory state with the file truth.

## Distribution & Integration

### Bundled Single JS File

esbuild bundles the TypeScript into a single `dist/index.js` (~50-100KB) checked into git. The Xcode build phase copies it to `Remarc.app/Contents/Resources/remarc-mcp.js`. No `node_modules` needed at runtime — just `node`.

### Programmatic Registration via Claude Code CLI

The Remarc app registers/unregisters the MCP server using the Claude Code CLI:

- **Enable:** `claude mcp add-json --scope user remarc '{"command":"<node-path>","args":["<bundled-js-path>"]}'`
- **Disable:** `claude mcp remove --scope user remarc`
- **Check:** `claude mcp get remarc`

`<node-path>` is resolved via `bash -l -c 'which node'` (handles NVM, Homebrew, etc.).
`<bundled-js-path>` is `Bundle.main.url(forResource: "remarc-mcp", withExtension: "js")`.

### Settings Toggle

New "Enable MCP Server" toggle in Preferences → General tab. Mirrors the `launchAtLogin` pattern — a computed property that reads/writes external state (Claude Code CLI), not UserDefaults.

**Dependency detection on toggle ON:**

1. Check for `node` via `bash -l -c 'which node'`
2. Check for `claude` via `bash -l -c 'which claude'`
3. **If both found:** register MCP server, toggle turns on
4. **If `node` missing:** toggle stays off, show inline alert:
   > "Node.js is required for the MCP server. Install it from nodejs.org or via Homebrew: `brew install node`"

   With a "Check Again" button.
5. **If `claude` missing:** toggle stays off, show inline alert:
   > "Claude Code CLI is required. Install it from claude.ai/download"

   With a "Check Again" button.

Both checks run when Preferences opens so the toggle state is accurate from the start.

## Not in MVP

- Reply threading (conversation happens in Claude Code terminal)
- Claude Code skill or `UserPromptSubmit` hook
- "Paste into Claude Code" button (`claude --resume`)
- Creating comments or sessions from MCP
- Screenshot/image support in MCP responses
- `.mcpb` bundle format (Claude Desktop only, not supported in Claude Code yet)

## Reference

**Agentation** (similar tool) uses: MCP tools for read/resolve/dismiss, HTTP API, SSE for real-time updates, React component detection for locating source files. Our approach is simpler — file-based data access with DistributedNotification for UI sync.
