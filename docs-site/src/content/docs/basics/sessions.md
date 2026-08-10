---
title: Sessions & the Inbox
description: Group Remarc comments into sessions, switch between them from the session bar, and understand the permanent Inbox.
---

Sessions group related comments, such as one review pass or one agent conversation. Up to 8 sessions can be active at a time.

## The Inbox

The **Inbox** is a permanent session that catches comments not filed anywhere else. It cannot be renamed or deleted, and it is never auto-deleted.

## The session bar

The session bar sits at the top of the [popover](/basics/menu-bar-and-popover/). Each session is a pill showing its name and comment count. Click a pill to switch to that session.

- **Create**: click the **+** button. New sessions are named automatically (Session A, Session B, ...) and open ready to rename. At the 8-session limit the button shows a "Session limit reached" toast instead.
- **Rename**: double-click a pill, or right-click it and choose Rename.
- **Delete**: right-click a pill and choose Delete.

When saving a comment, the composer's session picker chooses which session it goes to. Move an existing comment between sessions from its card actions - see [statuses and history](/basics/statuses-and-history/).

## Agent-created sessions

Agent integrations create sessions of their own, so an agent conversation gets a matching Remarc session. These carry a small origin badge next to the session name: the Claude logo for Claude Code sessions, the Codex logo for Codex sessions. See [agent integrations](/agents/overview/).

## Auto-delete inactive sessions

Settings has an **Auto-delete inactive sessions** toggle, off by default. When enabled, sessions with no recent activity are deleted after a chosen interval, from After 30 min to After 24 hours (default: After 4 hours). Their comments move to History, where they can be restored.

Only the Inbox is exempt. Any new or updated comment counts as activity and resets a session's timer, but a session left untouched past the interval is deleted even if it is the current one or still has unresolved comments.
