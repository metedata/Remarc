# Remark ID System — Design

## Problem

When users copy Remarc comments and paste them into AI chats, the AI has no way to reference specific comments back to Remarc. The MCP tools exist (resolve, reopen, get) but exported text doesn't include identifiers that map to them.

## Solution

Add a human-friendly, globally sequential **Remark ID** (`#R-1`, `#R-2`, ...) to each comment. Include these IDs in exports with a passive hint pointing AI agents to the Remarc MCP tools. The MCP server provides full usage context.

## Design

### 1. Data Model

- Add `remarkID: Int` field to `Comment` struct
- Assigned from a global counter at creation time, incrementing `totalCommentsCreated`
- Counter resets to 1 when it exceeds 10,000 to keep IDs short
- UUID remains the canonical identifier; `remarkID` is the human-friendly shorthand
- **Migration:** Existing comments get retroactive IDs assigned by `createdAt` order (oldest = 1)

### 2. Collision Handling (Post-Reset)

After a reset, multiple comments may share the same `remarkID`. When MCP looks up by remark ID:
- Search non-deleted comments first
- Return the most recent match
- In practice, old comments with the same ID are long resolved/deleted by the time the counter wraps

### 3. UI — Comment Card Metadata

Replace the source app name in the metadata row with the remark ID:

- **Before:** `Finder — Feb 28, 2:45 PM`
- **After:** `#R-42 — Feb 28, 2:45 PM`

The source app context is already clear from the reference text above the comment.

### 4. Export Format

Remark IDs appear in the metadata line of exported comments (not before the comment text):

```
> "The padding feels off here"
Comment: Reduce the top margin by 4pt to align with the grid.
#R-42 | Finder | Feb 28, 2:45 PM

---

> "This color doesn't match the brand guide"
Comment: Switch from #3B82F6 to the brand blue token.
#R-43 | Finder | Feb 28, 2:45 PM

<!-- To update these comments, use the Remarc MCP tools (remarc_resolve, remarc_reopen). -->
```

The AI hint footer is appended **only if the MCP server is running**.

### 5. Export Settings

Two new toggles:

| Setting | Default | Description |
|---------|---------|-------------|
| Include Remark IDs | On | Adds `#R-N` to the metadata line in exports |
| Include AI hint | On (when MCP active) | Appends MCP instruction footer. Only visible when MCP server is running |

### 6. MCP Server Changes

**Tool parameter updates** — `remarc_resolve`, `remarc_reopen`, and `remarc_get_comment` accept either:
- `comment_id` (UUID) — existing behavior
- `remark_id` (integer) — the `#R-N` number, new alternative

**Server-level instruction update:**
> Comments have human-friendly Remark IDs (#R-N). When users paste Remarc comments into chat, look for these IDs and use them to track and update comment status as you address each one. Call `remarc_resolve` with the remark_id and a brief summary of what you did.

The MCP is the single source of truth for how AI agents interact with Remarc. The export hint is intentionally minimal — just a pointer.

### 7. Settings — Comment Counter

Add a read-only stat in settings: `"Total remarks: 847"`. Displays the total number of comments ever created. Fun informational display, no interaction.

## Flow

```
User creates comment → remarkID assigned from counter → shown in UI metadata
User copies/exports → #R-N in metadata line + optional AI hint footer
User pastes into AI chat → AI reads IDs + hint → connects to Remarc MCP
AI addresses comment → calls remarc_resolve(remark_id: 42, summary: "...")
Remarc app reloads → comment shows as resolved with summary
```

## Non-Goals

- No new MCP tools — existing tools are extended with `remark_id` parameter
- No dedicated skill for AI agents in v1 — convention-based hint is sufficient
- No per-session ID scoping — global sequential keeps it simple
