---
title: Statuses & history
description: Track Remarc comment statuses from Open to Resolved, act on individual cards, and restore deleted comments from History.
---

Every comment has a status that tracks where it is in your workflow, and deleted comments go to a searchable History instead of disappearing.

## Statuses

A comment is always in one of four statuses:

| Status | Color | Meaning |
| --- | --- | --- |
| Open | Gray | New, nothing has happened yet |
| Handed Off | Blue | Passed to an agent or someone else |
| In-Progress | Amber | Being worked on |
| Resolved | Green | Done |

Each card shows a status dot in its top-right corner. Hover to expand it into a labeled pill, click it to change the status yourself.

Agents change statuses through MCP (Model Context Protocol) tools, and must provide a short resolution summary when they resolve a comment. Resolved cards dim, and hovering the status shows the summary. See [agent integrations](/agents/overview/).

## Card actions

Hover a card to reveal its actions:

| Action | What it does |
| --- | --- |
| Copy | Copy the comment to the clipboard |
| Edit | Open the comment in the editor |
| Send to webhook | Post the comment to a [webhook](/agents/webhooks/); shown only when a webhook is enabled |
| Move to session | Move the comment to another session, or a new one |
| Delete | Delete after confirmation, with an Undo toast |

Hovering also reveals the comment's short ID; click it to copy. Agents use these IDs to reference comments.

## History

Deleted comments move to History: click the clock icon in the popover header. From there, restore a comment to the current session or permanently delete it. History is searchable and sortable by date.

Two settings control cleanup:

- **Delete resolved**: automatically delete resolved comments. Never (default), Immediately, After 15 min, After 1 hour, or After 1 day.
- **History retention**: how long History keeps deleted comments. 1 day (default), 1 week, or 1 month.

## Bulk actions

The popover footer has **Resolve All** and **Delete All** for the active session. Both ask for confirmation and show an Undo toast afterwards, so a slip is recoverable.
