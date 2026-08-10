---
name: remarc
description: >
  Manage Remarc session comments and contextual feedback. Use when
  the user mentions Remarc sessions, comments, handoff, triage,
  review, addressing, resolving, status updates, or summaries.
---

# Remarc Comments

Remarc comments are contextual feedback attached to a session. Infer the user's
intent from the whole request, not from one exact verb. People may say "check",
"review", "handle", "go through", "fix these", "take this", "what's left",
"triage", or many other variants.

Default to an addressing workflow when the user asks you to take responsibility
for the comments. Use a read-only workflow when the user asks only to inspect,
list, summarize, count, audit, or recommend without changing the underlying
artifact or comment statuses.

## Session Lifecycle

Remarc sessions are containers for contextual feedback. They may be created by
the user from the Remarc app, created by chat through MCP, or created by an
installed integration. Do not assume the session's origin.

Use `remarc_create_session` only when the user asks to start a Remarc session
mid-conversation and the current Claude Code session ID is available. Do not
invent a session ID. For existing work, list sessions first and reuse the
matching or active session when appropriate.

There is no exposed MCP tool to stop, close, or delete a session. If the user
asks to stop a session, explain that MCP cannot do that directly and point them
to the Remarc app's session controls or their configured integration cleanup.

## Choose a Mode

Before changing any status, decide which mode the user requested:

- **Read-only**: Inspect, list, count, summarize, audit, or recommend. Do not
  change statuses.
- **Addressing**: Take responsibility for comments, update the artifact or
  produce the requested response, and move comments through the status lifecycle.
- **Status-only**: Change Remarc statuses exactly as requested without doing
  additional artifact work.

If the request is ambiguous and status changes would surprise the user, ask a
brief clarifying question. If the user has clearly handed you the comments to
work through, use addressing mode.

## Tool Reference

Use the Remarc MCP tools directly; do not edit Remarc's data file by hand.

### `remarc_list_sessions`

Use to orient before session-specific work. It lists active, non-deleted,
non-auto-dismissed sessions, marks the active session, and shows open,
in-progress, and resolved counts.

Call this first when the user names a session, says "active/current session",
asks what sessions exist, or asks you to review/address Remarc comments without
providing a session ID.

### `remarc_list_comments`

Use to fetch comments, optionally filtered by `session_id`, `status`, or `type`.
Comment types are `comment`, `screenshot`, `quickNote`, `critMode`, and
`webElement`. Statuses are `open`, `handedOff`, `inProgress`, and `resolved`.

For read-only summaries, fetch the requested comments and preserve statuses. For
addressing work, fetch `open`, `handedOff`, and `inProgress` comments for the
session so resumed work is not missed. Omit the status filter when you need a
complete view or when integration-provided comments may already be `handedOff`.

### `remarc_get_comment`

Use when a listed comment is ambiguous, long, screenshot-based, already
resolved, or needs exact metadata. It accepts a full UUID or the short ID shown
by Remarc.

For screenshot comments, use the returned image path with the platform's image
viewing tool when visual inspection matters.

For web-element comments, use the selector to grep the codebase, or the
component name and file path to jump straight to source.

### `remarc_set_status`

Use for one comment at a time. Set `handedOff` when accepting an open comment
from the user, `inProgress` when actively working it, `resolved` only after the
requested action is complete, and `open` to reopen a comment.

Always include a concise `summary` when setting `resolved`; the tool requires
one. Prefer `remarc_bulk_set_status` for batch handoff or batch resolution.

### `remarc_bulk_set_status`

Use for status updates across multiple comments. Prefer this over repeated
`remarc_set_status` calls when accepting all open comments in a session,
resolving several comments after one coherent action, or reopening/updating a
known set.

Pass explicit `comments` when each comment needs its own summary. Pass
`session_id` to target unresolved comments in a session. When resolving, provide
either a shared `summary` or per-comment summaries.

### `remarc_rename_session`

Use after the task context is clear and the current session name is generic,
stale, or misleading. Choose a short descriptive name, usually 1-3 words. Do not
rename a session just because you listed it; rename only when it improves
future identification or the user asks.

### `remarc_create_session`

Use when the user asks to start a Remarc session during an existing
conversation. Provide a short session name and the current Claude Code session
ID from session context. The new session becomes active, and future Remarc
comments can attach to subsequent messages through the Remarc integration.

Do not create a new session just because the user asks to inspect, summarize, or
address existing comments. List sessions first and use the matching session. If
the current Claude Code session ID is unavailable, say that you cannot create a
linked session from MCP without it.

## Status Lifecycle

Use the exact status strings below:

```text
open -> handedOff -> inProgress -> resolved
```

- `open`: Comment is available but not yet accepted by the agent.
- `handedOff`: The user has handed the comment to the agent to address.
- `inProgress`: The agent is actively working this specific comment now.
- `resolved`: The requested response is complete, checked in a way appropriate
  to the work, and summarized in Remarc.

Never mark a comment `resolved` just because you understand it, agree with it,
or have summarized it. Resolve only after you have taken the requested action,
or after confirming the comment is obsolete/invalid and explaining that in the
resolution summary.

## Workflow

1. Call `remarc_list_sessions` to get all sessions.
2. Identify the session:
   - If the user named one, fuzzy-match that name.
   - If the user says "active/current session", choose the active session when
     the tool exposes one.
   - If multiple sessions plausibly match, ask the user to disambiguate before
     changing statuses.
3. Fetch comments for the session:
   - Always fetch `open` comments.
   - Also fetch `handedOff` and `inProgress` comments so resumed work is not
     lost or duplicated.
4. Choose the mode. For read-only requests, skip status updates and answer from
   the fetched comments.
5. In addressing mode, immediately mark every fetched `open` comment as
   `handedOff` with a short summary such as "Accepted by Codex for addressing."
   Use `remarc_bulk_set_status` when available; otherwise call
   `remarc_set_status` for each comment.
6. Work one comment at a time:
   - Choose existing `inProgress` comments first, then `handedOff` comments in
     their displayed or created order.
   - Before starting a `handedOff` comment, set it to `inProgress` with a brief
     summary of the work you are beginning.
   - Read the comment text and quoted reference carefully.
   - Identify the target artifact and what "done" means for this comment.
   - Take the smallest coherent action that addresses the feedback.
   - Check the result in a way that fits the work:
     - If editing code, run the relevant tests, build, lint, app launch, or
       project-specific verification.
     - If editing prose or creative output, reread the changed passage against
       the comment and preserve the intended voice, structure, and constraints.
     - If editing visual/design work, inspect the rendered result or screenshot
       when available.
     - If the comment asks for research, triage, or a recommendation, cite the
       basis for the conclusion and update the relevant artifact if one exists.
   - Only then call `remarc_set_status` with `status: "resolved"` and a concise
     summary of what changed or what conclusion was reached.
7. If one action addresses multiple comments, still process the comments
   individually: set each to `inProgress`, confirm the completed work satisfies
   that comment, then resolve it with its own summary.
8. If a comment is ambiguous, blocked, or appears wrong:
   - Do not resolve it silently.
   - Leave it `inProgress` if you already started it, or `handedOff` if you have
     not started it.
   - Ask the user for the missing decision or explain the blocker.
9. After all addressable comments are resolved, give a short summary including:
   - How many comments were resolved.
   - Any comments left `handedOff` or `inProgress` and why.
   - Verification performed.
