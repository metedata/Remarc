# Sessions & Filters Design

**Date:** 2026-03-08
**Status:** Approved

## Problem

All comments land in a single queue regardless of which project, app, or agent session they belong to. Vibe coders working across multiple agents and projects get a polluted comment list. "Copy All" grabs everything, MCP agents can't easily scope to their relevant comments, and there's no way to organize without manual effort.

## Solution

Two orthogonal features:

1. **Filters** — automatic, zero-friction filtering by comment metadata (source app, type, status, attachment presence)
2. **Sessions** — manual organizational layer for grouping comments by agent/task/project

These compose: filters work within a session.

## Design Decisions

- **Apple Reminders model**: every comment belongs to exactly one session. "Inbox" is the permanent default session. No "All" view in MVP.
- **Filters are dynamic**: a filter dimension only appears when there's variety in the current session's comments (2+ apps, 2+ types, etc.)
- **Sessions are opt-in complexity**: single-session users see only `[Inbox] [+]` — minimal overhead.
- **Immediate moves with undo**: moving a comment between sessions takes effect immediately with a toast + undo, not deferred to save.

---

## Sessions

### Data Model

The existing `Session` model is sufficient. Key properties:
- `id` (UUID), `name` (String), `createdAt` (Date)
- `isDeleted`, `deletedAt` (soft delete)
- `isAutoDismissed`, `autoDismissedAt`

New constraint: **Inbox session** — the first session is permanent, always named "Inbox", cannot be renamed or deleted.

### Session Bar (Popover)

Horizontal row of pills between the popover header and the comment list (above filters if present). Always visible.

**Single session:**
```
[Inbox ●]  [+ New Session]
```

**Multiple sessions:**
```
[Inbox]  [Project X ●]  [Auth work]  [+ New Session]
```

- Active pill is visually highlighted (filled/bold)
- `[+]` expands on hover to show "New Session" label
- Tapping a pill switches the active session; comment list updates immediately
- Pills are horizontally scrollable if they overflow
- Filters reset when switching sessions

**Session pill interactions:**

| Action | Behavior |
|---|---|
| Tap pill | Switch active session |
| Double-click pill | Inline rename (text field replaces pill text) |
| Right-click custom session | Context menu: Rename, Delete, Merge into... |
| Right-click Inbox | No destructive options (only "Clear all" if applicable) |

**Inline rename:**
- Enter → save name
- Esc → cancel, revert to previous name
- Click outside → save name (auto-commit)
- Empty text → cancel, revert to previous name

**Creating a session via [+]:**
- Tapping [+] creates a new session with default name ("Session 2", "Session 3", etc.)
- Immediately enters inline rename on the new pill so user can type a name
- Click outside / Enter commits the name

### Session Pill in Comment Footer (Input & Editor Views)

Both `CommentInputView` (320pt) and `CommentEditorView` (440pt) get a session pill in the footer bar, on the left before the paperclip:

```
[Inbox ▾] [📎] [🎤]  ···spacer···  [Save ⌘↵]
```

Uses the existing `RemarcDropdown` / `DropdownPanelController` pattern.

**CommentInputView (new comment):**

| State | Pill shows | Dropdown contents |
|---|---|---|
| Only Inbox exists | `Inbox ▾` | Inbox (checked) + "New Session..." |
| Multiple sessions | `{active session} ▾` | All sessions (active checked) + "New Session..." |

Defaults to whichever session is selected in the popover session bar.

**CommentEditorView (editing existing comment):**

| State | Pill shows | Dropdown contents |
|---|---|---|
| Viewing/editing | `{comment's session} ▾` | All sessions (current checked) + "New Session..." |

Selecting a different session **moves the comment immediately** with a toast + undo. Editor stays open.

**"New Session..." flow (from footer pill dropdown):**
1. Dropdown dismisses
2. Pill transforms into inline text field with blinking cursor
3. Placeholder: "Session name"
4. Enter / click outside → creates session, pill shows new name
5. Esc → cancels, reverts to previous session
6. Empty text → cancels

**Voice recording active:** Pill remains interactive — user may realize mid-recording they're in the wrong session.

### Move Action on Comment Cards

Add a **move icon** (`arrow.forward.folder`) to the card's hover action row:

```
[copy] [edit] [move] [delete]
```

- Tapping the move icon opens a session picker dropdown (same `DropdownPanelController`)
- Dropdown lists all other sessions + "New Session..."
- Selecting a session moves the comment immediately with toast + undo
- Right-click context menu also has "Move to → [session list]" as an alternative

### Session Limit

Keep existing 3-session limit or bump it. TBD during implementation based on how the session bar handles overflow.

---

## Filters

### Filter Bar

Sits below the session bar in the popover, above the comment list. Only appears when there's variety in the current session's comments.

### Filter Dimensions

| Dimension | Appears when | UI |
|---|---|---|
| **Source app** | 2+ distinct apps in current session | Pill per app, multi-select |
| **Comment type** | 2+ distinct types (Comment, Screenshot, Quick Note, Crit) | Pill per type, multi-select |
| **Has attachment** | Some comments have attachments and some don't | Toggle pill |
| **Status** | Mixed statuses (Open, In Progress, Resolved) | Pill per status, multi-select |

- Each dimension only renders when it would provide meaningful filtering
- Tapping a pill toggles it on/off
- Active filters are visually highlighted
- Small "clear" button appears when any filter is active
- Comment count in header reflects filtered count (e.g., "3 of 7 remarks")
- Filters scope to the active session only
- **Filters reset when switching sessions**
- Filters are transient (reset when popover closes)

---

## Export / Copy All

**No ambiguity (single session, no filters):** "Copy All" works as today.

**Ambiguity (filters active OR multiple sessions):** "Copy All" shows a chevron. Clicking it offers:
- "Copy filtered" (if filters active) — just what's visible
- "Copy session" — everything in the active session
- Both options shown if both conditions apply

### MCP Hint with Session Name

When exporting a session, the MCP hint includes the session name:

> "These remarks are from the 'Project X' session in Remarc. Use MCP tool `remarc_list_comments` with session_id to read and resolve them."

This gives agents the breadcrumb to self-serve without setup.

---

## MCP

No new tools needed for MVP. Existing tools are already session-aware:
- `remarc_list_sessions` — lists all active sessions with comment counts
- `remarc_list_comments` — accepts `session_id` filter
- `remarc_resolve` / `remarc_reopen` — work on individual comments

Agents discover sessions via `remarc_list_sessions`, find theirs by name, and filter accordingly. The session name in the export MCP hint helps establish the link.

---

## Out of Scope (MVP)

- "All" aggregate view across sessions
- Smart/auto session creation
- Window title parsing for session naming
- Session-level metadata (tags, description)
- MCP tool for creating sessions (agents can't create sessions)
- Session analytics
