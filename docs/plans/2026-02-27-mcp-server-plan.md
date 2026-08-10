# Remarc MCP Server — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give Claude Code direct read/write access to Remarc comments via an MCP server, with an enable/disable toggle in Preferences.

**Architecture:** TypeScript stdio MCP server at `mcp/`, bundled to a single JS file via esbuild. Reads/writes `~/Library/Application Support/Remarc/comments.json` directly. Notifies the running Remarc app via `DistributedNotificationCenter` to reload. Registered programmatically via `claude mcp add-json`.

**Tech Stack:** TypeScript + `@modelcontextprotocol/sdk` + Zod (MCP server), Swift 6.0 + SwiftUI (app-side changes), esbuild (bundling).

**Critical JSON format notes:**
- Dates use Swift's `.deferredToDate` — encoded as `Double` (seconds since 2001-01-01). Offset from Unix epoch: **978307200 seconds**.
- UUIDs are uppercase hyphenated strings: `"A1B2C3D4-E5F6-..."`
- `CommentReference` enum encodes as: `{"textSelection":{"text":"hello"}}` or `{"quickNote":{}}`

---

## Task 1: Rename Stack → Session (Swift)

**Files:**
- Rename: `app/RemarcPackage/Sources/RemarcFeature/Models/Stack.swift` → `Session.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/AppState.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/Comment.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift`
- Modify: All views that reference `Stack` or `stackID`

This is a mechanical rename. Use find-and-replace across the codebase.

**Step 1: Rename the model file and struct**

Rename `Stack.swift` → `Session.swift`. Rename the struct:

```swift
public struct Session: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var isDeleted: Bool
    public var deletedAt: Date?
    public var isAutoDismissed: Bool
    public var autoDismissedAt: Date?

    // Backward-compatible: decode both "stacks" and "sessions" JSON keys
    // No CodingKeys needed here — the key rename happens at AppState level
}
```

**Step 2: Update AppState with backward-compatible CodingKeys**

```swift
public struct AppState: Codable, Sendable {
    public var sessions: [Session]
    public var comments: [Comment]
    public var activeSessionID: UUID?
    public var totalCommentsCreated: Int

    private enum CodingKeys: String, CodingKey {
        case sessions, comments, activeSessionID, totalCommentsCreated
        // Legacy keys for migration
        case stacks, activeStackID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try new key first, fall back to legacy
        if let s = try container.decodeIfPresent([Session].self, forKey: .sessions) {
            sessions = s
        } else {
            sessions = try container.decodeIfPresent([Session].self, forKey: .stacks) ?? []
        }

        comments = try container.decode([Comment].self, forKey: .comments)

        if let id = try container.decodeIfPresent(UUID.self, forKey: .activeSessionID) {
            activeSessionID = id
        } else {
            activeSessionID = try container.decodeIfPresent(UUID.self, forKey: .activeStackID)
        }

        totalCommentsCreated = try container.decode(Int.self, forKey: .totalCommentsCreated)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(comments, forKey: .comments)
        try container.encodeIfPresent(activeSessionID, forKey: .activeSessionID)
        try container.encode(totalCommentsCreated, forKey: .totalCommentsCreated)
    }

    public init(
        sessions: [Session] = [],
        comments: [Comment] = [],
        activeSessionID: UUID? = nil,
        totalCommentsCreated: Int = 0
    ) {
        self.sessions = sessions
        self.comments = comments
        self.activeSessionID = activeSessionID
        self.totalCommentsCreated = totalCommentsCreated
    }

    public static func defaultState() -> AppState {
        AppState()
    }
}
```

**Step 3: Update Comment.stackID → sessionID with backward compat**

In `Comment.swift`, add `sessionID` to CodingKeys with fallback:

```swift
// In CodingKeys:
case id, reference, selectedText, commentText, source, appBundleID
case createdAt, updatedAt, sessionID, stackID, isDeleted, deletedAt

// In init(from:):
if let sid = try container.decodeIfPresent(UUID.self, forKey: .sessionID) {
    sessionID = sid
} else {
    sessionID = try container.decode(UUID.self, forKey: .stackID)
}

// In encode(to:):
try container.encode(sessionID, forKey: .sessionID)
// Do NOT encode stackID — always write new key
```

**Step 4: Rename all references across the codebase**

Apply these renames across ALL files in `app/RemarcPackage/Sources/RemarcFeature/`:

| Old | New |
|---|---|
| `Stack` (type) | `Session` |
| `stacks` (property) | `sessions` |
| `stackID` (property) | `sessionID` |
| `activeStackID` | `activeSessionID` |
| `activeStack` | `activeSession` |
| `activeStacks` | `activeSessions` |
| `maxActiveStacks` | `maxActiveSessions` |
| `createStack` | `createSession` |
| `renameStack` | `renameSession` |
| `deleteStack` | `deleteSession` |
| `restoreStack` | `restoreSession` |
| `dismissStack` | `dismissSession` |
| `permanentlyDeleteStack` | `permanentlyDeleteSession` |
| `deletedStacks` | `deletedSessions` |
| `for stackID:` | `for sessionID:` |

Use Grep to find all occurrences: `Stack`, `stack`, `stackID`, `activeStack` across `*.swift` files.

The auto-created session name in `PersistenceManager.createComment` changes from `"Stack 1"` to `"Session 1"`.

**Step 5: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

**Step 6: Commit**

```bash
git add -A app/RemarcPackage/Sources/
git commit -m "refactor: rename Stack → Session throughout codebase"
```

---

## Task 2: Add CommentStatus and Resolution Fields

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Models/CommentStatus.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/Comment.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift`

**Step 1: Create the CommentStatus enum**

Create `app/RemarcPackage/Sources/RemarcFeature/Models/CommentStatus.swift`:

```swift
import Foundation

public enum CommentStatus: String, Codable, Sendable, CaseIterable {
    case open
    case resolved
}
```

**Step 2: Add status fields to Comment**

Add these fields to `Comment`:

```swift
public var status: CommentStatus
public var resolutionSummary: String?
public var resolvedBy: String?
public var resolvedAt: Date?
```

Update the `init(...)`:

```swift
public init(
    id: UUID = UUID(),
    reference: CommentReference,
    commentText: String,
    source: String,
    appBundleID: String?,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    sessionID: UUID,
    isDeleted: Bool = false,
    deletedAt: Date? = nil,
    status: CommentStatus = .open,
    resolutionSummary: String? = nil,
    resolvedBy: String? = nil,
    resolvedAt: Date? = nil
) { ... }
```

Update CodingKeys:

```swift
case id, reference, selectedText, commentText, source, appBundleID
case createdAt, updatedAt, sessionID, stackID, isDeleted, deletedAt
case status, resolutionSummary, resolvedBy, resolvedAt
```

Update `init(from decoder:)` — decode status with default `.open` for old data:

```swift
status = try container.decodeIfPresent(CommentStatus.self, forKey: .status) ?? .open
resolutionSummary = try container.decodeIfPresent(String.self, forKey: .resolutionSummary)
resolvedBy = try container.decodeIfPresent(String.self, forKey: .resolvedBy)
resolvedAt = try container.decodeIfPresent(Date.self, forKey: .resolvedAt)
```

Update `encode(to:)`:

```swift
try container.encode(status, forKey: .status)
try container.encodeIfPresent(resolutionSummary, forKey: .resolutionSummary)
try container.encodeIfPresent(resolvedBy, forKey: .resolvedBy)
try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
```

**Step 3: Add resolve/reopen methods to PersistenceManager**

```swift
public func resolveComment(_ id: UUID, summary: String, resolvedBy: String) {
    guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
    appState.comments[index].status = .resolved
    appState.comments[index].resolutionSummary = summary
    appState.comments[index].resolvedBy = resolvedBy
    appState.comments[index].resolvedAt = Date()
    appState.comments[index].updatedAt = Date()
    scheduleSave()
    debugLog("PersistenceManager: Resolved comment \(id)")
}

public func reopenComment(_ id: UUID) {
    guard let index = appState.comments.firstIndex(where: { $0.id == id }) else { return }
    appState.comments[index].status = .open
    appState.comments[index].resolutionSummary = nil
    appState.comments[index].resolvedBy = nil
    appState.comments[index].resolvedAt = nil
    appState.comments[index].updatedAt = Date()
    scheduleSave()
    debugLog("PersistenceManager: Reopened comment \(id)")
}
```

**Step 4: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

**Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Models/CommentStatus.swift
git add app/RemarcPackage/Sources/RemarcFeature/Models/Comment.swift
git add app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift
git commit -m "feat: add CommentStatus with resolve/reopen support"
```

---

## Task 3: Add DistributedNotification Reload to PersistenceManager

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift`

**Step 1: Add the notification observer**

Add to the end of `PersistenceManager.init()`:

```swift
// Listen for external reload requests (from MCP server)
DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("com.metepolat.Remarc.reload"),
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.reloadFromDisk()
}
```

**Step 2: Add the reloadFromDisk method**

Add to PersistenceManager:

```swift
private func reloadFromDisk() {
    guard let data = try? Data(contentsOf: fileURL),
          let state = try? JSONDecoder().decode(AppState.self, from: data) else {
        debugLog("PersistenceManager: Failed to reload from disk")
        return
    }
    appState = state
    debugLog("PersistenceManager: Reloaded from disk (\(state.comments.count) comments, \(state.sessions.count) sessions)")
}
```

Note: since `appState` is `@Published`, this automatically triggers all UI updates.

**Step 3: Build and verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift
git commit -m "feat: add DistributedNotification reload for MCP integration"
```

---

## Task 4: Create TypeScript MCP Server

**Files:**
- Create: `mcp/package.json`
- Create: `mcp/tsconfig.json`
- Create: `mcp/src/data.ts`
- Create: `mcp/src/notify.ts`
- Create: `mcp/src/tools.ts`
- Create: `mcp/src/index.ts`
- Create: `mcp/.gitignore`

### Step 1: Project setup

Create `mcp/.gitignore`:

```
node_modules/
```

Create `mcp/package.json`:

```json
{
  "name": "@remarc/mcp-server",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "esbuild src/index.ts --bundle --platform=node --target=node18 --format=esm --outfile=dist/index.js --banner:js='#!/usr/bin/env node' --external:zod",
    "dev": "tsx src/index.ts",
    "test": "vitest run"
  },
  "dependencies": {
    "@modelcontextprotocol/sdk": "^1.12.0",
    "zod": "^3.25.0"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "esbuild": "^0.25.0",
    "tsx": "^4.19.0",
    "typescript": "^5.7.0",
    "vitest": "^3.0.0"
  }
}
```

Create `mcp/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "bundler",
    "strict": true,
    "esModuleInterop": true,
    "outDir": "dist",
    "rootDir": "src",
    "declaration": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

Run: `cd mcp && npm install`

### Step 2: Create data layer (`mcp/src/data.ts`)

```typescript
import { readFile, writeFile, rename } from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Apple epoch offset: seconds between 1970-01-01 and 2001-01-01
const APPLE_EPOCH_OFFSET = 978307200;

export function appleToUnix(appleTimestamp: number): Date {
  return new Date((appleTimestamp + APPLE_EPOCH_OFFSET) * 1000);
}

export function unixToApple(date: Date): number {
  return date.getTime() / 1000 - APPLE_EPOCH_OFFSET;
}

export function formatDate(date: Date): string {
  return date.toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC");
}

// --- Types matching Swift Codable output ---

interface RawCommentReference {
  textSelection?: { text: string };
  quickNote?: Record<string, never>;
}

interface RawComment {
  id: string;
  reference: RawCommentReference;
  commentText: string;
  source: string;
  appBundleID?: string;
  createdAt: number; // Apple epoch
  updatedAt: number;
  sessionID: string;
  isDeleted: boolean;
  deletedAt?: number;
  status?: "open" | "resolved";
  resolutionSummary?: string;
  resolvedBy?: string;
  resolvedAt?: number;
}

interface RawSession {
  id: string;
  name: string;
  createdAt: number;
  isDeleted: boolean;
  deletedAt?: number;
  isAutoDismissed: boolean;
  autoDismissedAt?: number;
}

interface RawAppState {
  // New keys
  sessions?: RawSession[];
  activeSessionID?: string;
  // Legacy keys (pre-rename)
  stacks?: RawSession[];
  activeStackID?: string;
  // Common
  comments: RawComment[];
  totalCommentsCreated: number;
}

// --- Public types (clean, with JS Dates) ---

export interface Session {
  id: string;
  name: string;
  createdAt: Date;
  isDeleted: boolean;
  deletedAt?: Date;
  isAutoDismissed: boolean;
  autoDismissedAt?: Date;
}

export interface Comment {
  id: string;
  reference: { type: "textSelection"; text: string } | { type: "quickNote" };
  commentText: string;
  source: string;
  appBundleID?: string;
  createdAt: Date;
  updatedAt: Date;
  sessionID: string;
  isDeleted: boolean;
  deletedAt?: Date;
  status: "open" | "resolved";
  resolutionSummary?: string;
  resolvedBy?: string;
  resolvedAt?: Date;
}

export interface AppState {
  sessions: Session[];
  comments: Comment[];
  activeSessionID?: string;
  totalCommentsCreated: number;
}

// --- File path ---

export function getDataFilePath(): string {
  return join(
    homedir(),
    "Library",
    "Application Support",
    "Remarc",
    "comments.json"
  );
}

// --- Parsing ---

function parseReference(
  raw: RawCommentReference
): Comment["reference"] {
  if (raw.textSelection) {
    return { type: "textSelection", text: raw.textSelection.text };
  }
  return { type: "quickNote" };
}

function parseComment(raw: RawComment): Comment {
  return {
    id: raw.id,
    reference: parseReference(raw.reference),
    commentText: raw.commentText,
    source: raw.source,
    appBundleID: raw.appBundleID,
    createdAt: appleToUnix(raw.createdAt),
    updatedAt: appleToUnix(raw.updatedAt),
    sessionID: raw.sessionID,
    isDeleted: raw.isDeleted,
    deletedAt: raw.deletedAt != null ? appleToUnix(raw.deletedAt) : undefined,
    status: raw.status ?? "open",
    resolutionSummary: raw.resolutionSummary,
    resolvedBy: raw.resolvedBy,
    resolvedAt: raw.resolvedAt != null ? appleToUnix(raw.resolvedAt) : undefined,
  };
}

function parseSession(raw: RawSession): Session {
  return {
    id: raw.id,
    name: raw.name,
    createdAt: appleToUnix(raw.createdAt),
    isDeleted: raw.isDeleted,
    deletedAt: raw.deletedAt != null ? appleToUnix(raw.deletedAt) : undefined,
    isAutoDismissed: raw.isAutoDismissed,
    autoDismissedAt:
      raw.autoDismissedAt != null
        ? appleToUnix(raw.autoDismissedAt)
        : undefined,
  };
}

// --- Read ---

export async function readAppState(): Promise<AppState> {
  const filePath = getDataFilePath();

  if (!existsSync(filePath)) {
    return {
      sessions: [],
      comments: [],
      activeSessionID: undefined,
      totalCommentsCreated: 0,
    };
  }

  const raw: RawAppState = JSON.parse(
    await readFile(filePath, "utf-8")
  );

  // Handle both new ("sessions") and legacy ("stacks") keys
  const rawSessions = raw.sessions ?? raw.stacks ?? [];
  const activeSessionID = raw.activeSessionID ?? raw.activeStackID;

  // Handle legacy comments that use stackID instead of sessionID
  const comments = raw.comments.map((c) => {
    // If sessionID is missing, try the raw object for stackID
    const rawAny = c as Record<string, unknown>;
    if (!c.sessionID && rawAny.stackID) {
      c.sessionID = rawAny.stackID as string;
    }
    return parseComment(c);
  });

  return {
    sessions: rawSessions.map(parseSession),
    comments,
    activeSessionID,
    totalCommentsCreated: raw.totalCommentsCreated,
  };
}

// --- Write ---

function serializeComment(comment: Comment): RawComment {
  const raw: RawComment = {
    id: comment.id,
    reference: comment.reference.type === "textSelection"
      ? { textSelection: { text: comment.reference.text } }
      : { quickNote: {} },
    commentText: comment.commentText,
    source: comment.source,
    createdAt: unixToApple(comment.createdAt),
    updatedAt: unixToApple(comment.updatedAt),
    sessionID: comment.sessionID,
    isDeleted: comment.isDeleted,
    status: comment.status,
  };

  if (comment.appBundleID) raw.appBundleID = comment.appBundleID;
  if (comment.deletedAt) raw.deletedAt = unixToApple(comment.deletedAt);
  if (comment.resolutionSummary) raw.resolutionSummary = comment.resolutionSummary;
  if (comment.resolvedBy) raw.resolvedBy = comment.resolvedBy;
  if (comment.resolvedAt) raw.resolvedAt = unixToApple(comment.resolvedAt);

  return raw;
}

function serializeSession(session: Session): RawSession {
  const raw: RawSession = {
    id: session.id,
    name: session.name,
    createdAt: unixToApple(session.createdAt),
    isDeleted: session.isDeleted,
    isAutoDismissed: session.isAutoDismissed,
  };

  if (session.deletedAt) raw.deletedAt = unixToApple(session.deletedAt);
  if (session.autoDismissedAt) raw.autoDismissedAt = unixToApple(session.autoDismissedAt);

  return raw;
}

export async function writeAppState(state: AppState): Promise<void> {
  const filePath = getDataFilePath();
  const tmpPath = filePath + ".tmp";

  const raw: RawAppState = {
    sessions: state.sessions.map(serializeSession),
    comments: state.comments.map(serializeComment),
    activeSessionID: state.activeSessionID,
    totalCommentsCreated: state.totalCommentsCreated,
  };

  const json = JSON.stringify(raw);
  await writeFile(tmpPath, json, "utf-8");
  await rename(tmpPath, filePath);
}
```

### Step 3: Create notification helper (`mcp/src/notify.ts`)

```typescript
import { execFile } from "node:child_process";

/**
 * Posts a macOS DistributedNotification to tell the running Remarc app to reload.
 * Uses osascript since there's no native Node.js API for DistributedNotificationCenter.
 */
export function notifyRemarcReload(): Promise<void> {
  return new Promise((resolve, reject) => {
    execFile(
      "osascript",
      [
        "-e",
        'tell application id "com.apple.systemevents" to do shell script ' +
          '"swift -e \\"import Foundation; DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(\\\\\\\"com.metepolat.Remarc.reload\\\\\\\"), object: nil, userInfo: nil, deliverImmediately: true)\\""',
      ],
      { timeout: 5000 },
      (error) => {
        if (error) {
          // Non-fatal: app might not be running
          console.error("Failed to notify Remarc:", error.message);
        }
        resolve();
      }
    );
  });
}
```

**Note:** An alternative simpler approach if the above escaping is fragile — create a tiny Swift script file at `mcp/src/notify.swift` and call it via `swift`:

Create `mcp/notify-remarc.swift`:

```swift
import Foundation
DistributedNotificationCenter.default().postNotificationName(
    NSNotification.Name("com.metepolat.Remarc.reload"),
    object: nil,
    userInfo: nil,
    deliverImmediately: true
)
```

Then in `notify.ts`:

```typescript
import { execFile } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

export function notifyRemarcReload(): Promise<void> {
  return new Promise((resolve) => {
    execFile(
      "swift",
      [join(__dirname, "..", "notify-remarc.swift")],
      { timeout: 5000 },
      (error) => {
        if (error) console.error("Failed to notify Remarc:", error.message);
        resolve();
      }
    );
  });
}
```

Use whichever approach is simpler to get working. The Swift script file approach avoids escaping hell.

### Step 4: Create tool definitions (`mcp/src/tools.ts`)

```typescript
import * as z from "zod/v4";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import {
  readAppState,
  writeAppState,
  formatDate,
  type Comment,
  type Session,
} from "./data.js";
import { notifyRemarcReload } from "./notify.js";

function formatSession(s: Session, comments: Comment[]): string {
  const active = comments.filter((c) => c.sessionID === s.id && !c.isDeleted);
  const open = active.filter((c) => c.status === "open").length;
  const resolved = active.filter((c) => c.status === "resolved").length;
  return `${s.name} (id: ${s.id})\n  ${open} open, ${resolved} resolved · Created ${formatDate(s.createdAt)}`;
}

function formatComment(c: Comment): string {
  const status = c.status === "resolved" ? "resolved" : "open";
  const ref =
    c.reference.type === "textSelection"
      ? `"${c.reference.text}"`
      : "Quick Note";
  let out = `[${status}] ${ref}\n`;
  out += `  Comment: ${c.commentText}\n`;
  out += `  Source: ${c.source} · ${formatDate(c.createdAt)}\n`;
  out += `  ID: ${c.id}`;
  if (c.status === "resolved" && c.resolutionSummary) {
    out += `\n  Resolution: ${c.resolutionSummary}`;
    if (c.resolvedBy) out += ` (by ${c.resolvedBy})`;
  }
  return out;
}

export function registerTools(server: McpServer): void {
  // --- remarc_list_sessions ---
  server.registerTool(
    "remarc_list_sessions",
    {
      title: "List Remarc Sessions",
      description:
        "List all active comment sessions in Remarc. Each session is an independent collection of comments.",
    },
    async () => {
      const state = await readAppState();
      const active = state.sessions.filter(
        (s) => !s.isDeleted && !s.isAutoDismissed
      );

      if (active.length === 0) {
        return {
          content: [{ type: "text", text: "No active sessions." }],
        };
      }

      const lines = active.map((s) => formatSession(s, state.comments));
      const activeLabel = state.activeSessionID
        ? `\nActive session: ${state.activeSessionID}`
        : "";

      return {
        content: [
          {
            type: "text",
            text: `${active.length} session(s):\n\n${lines.join("\n\n")}${activeLabel}`,
          },
        ],
      };
    }
  );

  // --- remarc_list_comments ---
  server.registerTool(
    "remarc_list_comments",
    {
      title: "List Remarc Comments",
      description:
        "List comments in Remarc, optionally filtered by session and status.",
      inputSchema: z.object({
        session_id: z
          .string()
          .optional()
          .describe(
            "Filter by session UUID. If omitted, shows comments from all sessions."
          ),
        status: z
          .enum(["open", "resolved"])
          .optional()
          .describe("Filter by status. If omitted, shows all comments."),
      }),
    },
    async ({ session_id, status }) => {
      const state = await readAppState();
      let comments = state.comments.filter((c) => !c.isDeleted);

      if (session_id) {
        comments = comments.filter((c) => c.sessionID === session_id);
      }
      if (status) {
        comments = comments.filter((c) => c.status === status);
      }

      // Sort by creation time ascending
      comments.sort(
        (a, b) => a.createdAt.getTime() - b.createdAt.getTime()
      );

      if (comments.length === 0) {
        return {
          content: [
            {
              type: "text",
              text: "No comments found matching the criteria.",
            },
          ],
        };
      }

      const lines = comments.map(
        (c, i) => `${i + 1}. ${formatComment(c)}`
      );

      return {
        content: [
          {
            type: "text",
            text: `${comments.length} comment(s):\n\n${lines.join("\n\n")}`,
          },
        ],
      };
    }
  );

  // --- remarc_get_comment ---
  server.registerTool(
    "remarc_get_comment",
    {
      title: "Get Remarc Comment",
      description: "Get full details of a single comment by ID.",
      inputSchema: z.object({
        comment_id: z.string().describe("The comment UUID"),
      }),
    },
    async ({ comment_id }) => {
      const state = await readAppState();
      const comment = state.comments.find((c) => c.id === comment_id);

      if (!comment) {
        return {
          content: [
            {
              type: "text",
              text: `Comment not found: ${comment_id}`,
            },
          ],
          isError: true,
        };
      }

      const session = state.sessions.find(
        (s) => s.id === comment.sessionID
      );

      return {
        content: [
          {
            type: "text",
            text: `${formatComment(comment)}\n  Session: ${session?.name ?? "unknown"}`,
          },
        ],
      };
    }
  );

  // --- remarc_resolve ---
  server.registerTool(
    "remarc_resolve",
    {
      title: "Resolve Remarc Comment",
      description:
        "Mark a comment as resolved with a summary of what was done.",
      inputSchema: z.object({
        comment_id: z.string().describe("The comment UUID to resolve"),
        summary: z
          .string()
          .describe(
            "A brief summary of what was done to address this comment"
          ),
      }),
    },
    async ({ comment_id, summary }) => {
      const state = await readAppState();
      const index = state.comments.findIndex((c) => c.id === comment_id);

      if (index === -1) {
        return {
          content: [
            {
              type: "text",
              text: `Comment not found: ${comment_id}`,
            },
          ],
          isError: true,
        };
      }

      const comment = state.comments[index];
      if (comment.status === "resolved") {
        return {
          content: [
            {
              type: "text",
              text: `Comment is already resolved: ${comment_id}`,
            },
          ],
        };
      }

      state.comments[index] = {
        ...comment,
        status: "resolved",
        resolutionSummary: summary,
        resolvedBy: "claude",
        resolvedAt: new Date(),
        updatedAt: new Date(),
      };

      await writeAppState(state);
      await notifyRemarcReload();

      return {
        content: [
          {
            type: "text",
            text: `Resolved: "${comment.commentText.substring(0, 60)}"\nSummary: ${summary}`,
          },
        ],
      };
    }
  );

  // --- remarc_reopen ---
  server.registerTool(
    "remarc_reopen",
    {
      title: "Reopen Remarc Comment",
      description: "Reopen a previously resolved comment.",
      inputSchema: z.object({
        comment_id: z.string().describe("The comment UUID to reopen"),
      }),
    },
    async ({ comment_id }) => {
      const state = await readAppState();
      const index = state.comments.findIndex((c) => c.id === comment_id);

      if (index === -1) {
        return {
          content: [
            {
              type: "text",
              text: `Comment not found: ${comment_id}`,
            },
          ],
          isError: true,
        };
      }

      const comment = state.comments[index];
      if (comment.status === "open") {
        return {
          content: [
            {
              type: "text",
              text: `Comment is already open: ${comment_id}`,
            },
          ],
        };
      }

      state.comments[index] = {
        ...comment,
        status: "open",
        resolutionSummary: undefined,
        resolvedBy: undefined,
        resolvedAt: undefined,
        updatedAt: new Date(),
      };

      await writeAppState(state);
      await notifyRemarcReload();

      return {
        content: [
          {
            type: "text",
            text: `Reopened: "${comment.commentText.substring(0, 60)}"`,
          },
        ],
      };
    }
  );
}
```

### Step 5: Create server entry point (`mcp/src/index.ts`)

```typescript
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerTools } from "./tools.js";

const server = new McpServer({
  name: "remarc",
  version: "0.1.0",
});

registerTools(server);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Remarc MCP server running on stdio");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
```

### Step 6: Install and test locally

```bash
cd mcp && npm install && npx tsx src/index.ts
```

The server should start and wait for stdio input. Ctrl+C to stop.

### Step 7: Commit

```bash
git add mcp/
git commit -m "feat: add TypeScript MCP server with 5 tools"
```

---

## Task 5: esbuild Bundling

**Files:**
- Modify: `mcp/package.json` (build script already defined)
- Create: `mcp/dist/index.js` (build output, checked into git)

### Step 1: Build the bundle

```bash
cd mcp && npm run build
```

This runs: `esbuild src/index.ts --bundle --platform=node --target=node18 --format=esm --outfile=dist/index.js --banner:js='#!/usr/bin/env node' --external:zod`

**Note:** If the bundle has issues with `zod` being external, change to bundling it inline by removing `--external:zod`. Or if `@modelcontextprotocol/sdk` requires a specific zod import path, adjust accordingly. Test with:

```bash
node mcp/dist/index.js
```

Should start the server on stdio without errors.

**If Zod needs bundling**, update the build script in `package.json`:

```json
"build": "esbuild src/index.ts --bundle --platform=node --target=node18 --format=esm --outfile=dist/index.js --banner:js='#!/usr/bin/env node'"
```

### Step 2: Also bundle the notify script if using the Swift file approach

If using `notify-remarc.swift`, the esbuild bundle won't include it. Ensure `dist/` also contains the swift file, or inline the notification via osascript in the bundled code.

The simplest approach: use the osascript inline method in notify.ts so everything is self-contained in one JS file.

### Step 3: Verify the bundle works

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}' | node mcp/dist/index.js
```

Should return an initialize response.

### Step 4: Check in the bundle

```bash
git add mcp/dist/index.js
git commit -m "build: add bundled MCP server for zero-install distribution"
```

---

## Task 6: MCP Toggle in Preferences

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Services/MCPManager.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

### Step 1: Create MCPManager

Create `app/RemarcPackage/Sources/RemarcFeature/Services/MCPManager.swift`:

```swift
import Foundation

/// Manages MCP server registration with Claude Code CLI.
@MainActor
public final class MCPManager: ObservableObject {
    public static let shared = MCPManager()

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var nodeStatus: DependencyStatus = .unchecked
    @Published public private(set) var claudeStatus: DependencyStatus = .unchecked

    public enum DependencyStatus: Equatable {
        case unchecked
        case found(path: String)
        case notFound
    }

    private var nodePath: String?
    private var claudePath: String?

    private init() {}

    // MARK: - Dependency Detection

    public func checkDependencies() {
        Task {
            async let node = resolveBinaryPath("node")
            async let claude = resolveBinaryPath("claude")
            let (nodePath, claudePath) = await (node, claude)

            self.nodePath = nodePath
            self.claudePath = claudePath
            self.nodeStatus = nodePath != nil ? .found(path: nodePath!) : .notFound
            self.claudeStatus = claudePath != nil ? .found(path: claudePath!) : .notFound

            // Check if already registered
            if claudePath != nil {
                self.isEnabled = await checkMCPRegistered()
            }
        }
    }

    // MARK: - Enable / Disable

    public func enable() async -> Bool {
        guard let nodePath, let claudePath else { return false }

        // Get the bundled MCP server path
        guard let mcpURL = Bundle.main.url(forResource: "remarc-mcp", withExtension: "js") else {
            debugLog("MCPManager: remarc-mcp.js not found in bundle")
            return false
        }

        let config = """
        {"command":"\(nodePath)","args":["\(mcpURL.path)"]}
        """

        let success = await runProcess(
            claudePath,
            arguments: ["mcp", "add-json", "--scope", "user", "remarc", config]
        )

        if success {
            isEnabled = true
            debugLog("MCPManager: MCP server registered")
        }
        return success
    }

    public func disable() async -> Bool {
        guard let claudePath else { return false }

        let success = await runProcess(
            claudePath,
            arguments: ["mcp", "remove", "--scope", "user", "remarc"]
        )

        if success {
            isEnabled = false
            debugLog("MCPManager: MCP server unregistered")
        }
        return success
    }

    // MARK: - Helpers

    private func resolveBinaryPath(_ binary: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-l", "-c", "which \(binary)"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus == 0, let path, !path.isEmpty {
                    continuation.resume(returning: path)
                } else {
                    continuation.resume(returning: nil)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private func checkMCPRegistered() async -> Bool {
        guard let claudePath else { return false }

        return await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = ["mcp", "get", "remarc"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    @discardableResult
    private func runProcess(_ path: String, arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
```

### Step 2: Add MCP section to PreferencesView

Add to `PreferencesView.generalTab`, below the existing toggles:

```swift
Divider()

// MCP Server section
VStack(alignment: .leading, spacing: 8) {
    Toggle("Enable Claude Code integration", isOn: Binding(
        get: { MCPManager.shared.isEnabled },
        set: { newValue in
            Task {
                if newValue {
                    await MCPManager.shared.enable()
                } else {
                    await MCPManager.shared.disable()
                }
            }
        }
    ))
    .disabled(
        MCPManager.shared.nodeStatus == .notFound ||
        MCPManager.shared.claudeStatus == .notFound
    )

    Text("Lets Claude Code read and resolve your Remarc comments directly.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)

    // Error states
    if MCPManager.shared.nodeStatus == .notFound {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
            Text("Node.js required. Install from nodejs.org or run: brew install node")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    if MCPManager.shared.claudeStatus == .notFound {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
            Text("Claude Code CLI required. Install from claude.ai/download")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    if MCPManager.shared.nodeStatus == .notFound || MCPManager.shared.claudeStatus == .notFound {
        Button("Check Again") {
            MCPManager.shared.checkDependencies()
        }
        .font(.system(size: 11))
    }
}
```

Also add an `.onAppear` to the general tab:

```swift
.onAppear {
    MCPManager.shared.checkDependencies()
}
```

### Step 3: Add Xcode build phase to copy bundled JS

In the Xcode project, add a "Copy Files" build phase to the Remarc app target:
- Destination: Resources
- File: `../../mcp/dist/index.js` renamed to `remarc-mcp.js`

Alternatively, add a Run Script build phase:

```bash
cp "${SRCROOT}/../mcp/dist/index.js" "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/remarc-mcp.js"
```

If the bundled `notify-remarc.swift` file is used, also copy that:

```bash
cp "${SRCROOT}/../mcp/notify-remarc.swift" "${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/notify-remarc.swift"
```

### Step 4: Build and verify

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`

### Step 5: Manual verification

1. Launch the built app
2. Open Preferences → General
3. Verify the "Enable Claude Code integration" toggle appears
4. If Node.js and Claude Code are installed, toggle should be interactive
5. Enable it, then verify: `claude mcp get remarc` returns the config

### Step 6: Commit

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/MCPManager.swift
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add MCP server toggle in Preferences"
```

---

## Task Dependencies

```
Task 1 (rename) ──┐
                   ├──→ Task 4 (TypeScript MCP) ──→ Task 5 (bundle) ──→ Task 6 (settings toggle)
Task 2 (status)  ──┘
Task 3 (notification) ── independent, can run in parallel with 1-2
```

Tasks 1 and 2 can be done together (same commit even). Task 3 is independent. Task 4 needs the final JSON schema from 1+2. Task 5 needs 4. Task 6 needs 5.
