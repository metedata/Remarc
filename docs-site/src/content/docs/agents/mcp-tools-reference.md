---
title: MCP tools reference
description: Reference for the seven MCP tools Remarc exposes to agents, with status strings, filters, and deliberate limits.
---

The Remarc MCP (Model Context Protocol) server exposes seven tools. Every connected agent gets the same set regardless of how it was installed; setup paths are in the [agent overview](/agents/overview/).

## Tools

Each tool and what it does:

| Tool | What it does |
| --- | --- |
| `remarc_list_sessions` | Lists active sessions, marks the active one, and shows open, in-progress, and resolved counts. |
| `remarc_list_comments` | Lists comments, optionally filtered by `session_id`, `status`, or `type`. Types: `comment`, `screenshot`, `quickNote`, `critMode`, `webElement`. |
| `remarc_get_comment` | Returns one comment by full UUID or the 5-character short ID shown on the card. Includes the image path for screenshot comments and the CSS selector, component name, and file path for web element comments. |
| `remarc_set_status` | Sets one comment's status. `resolved` requires a summary of what was done, which appears on the card in Remarc. |
| `remarc_bulk_set_status` | Sets the status of many comments at once, with a shared summary or per-comment summaries. |
| `remarc_rename_session` | Renames a session. |
| `remarc_create_session` | Creates a session paired to the current agent conversation and makes it active. |

## Statuses

Agents use these exact status strings:

| Status | Meaning |
| --- | --- |
| `open` | Not yet accepted by the agent. |
| `handedOff` | You handed the comment to the agent to address. |
| `inProgress` | The agent is actively working this comment. |
| `resolved` | Done, with a resolution summary. |

These map to the Open, Handed Off, In-Progress, and Resolved dots on comment cards; see [statuses and history](/basics/statuses-and-history/).

## Deliberate limits

No tool deletes or closes sessions. Session cleanup happens in the app (or through your integration's conversation-cleared setting), so an agent can never destroy a container of your feedback.

Agents should not edit `comments.json` directly. The MCP tools are the only safe write path; hand-editing the data file risks losing comments to concurrent writes.
