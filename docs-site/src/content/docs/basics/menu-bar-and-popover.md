---
title: Menu bar & popover
description: Open Remarc's popover from the menu bar icon or with Ctrl+Option+R, and use the right-click menu and detached floating window.
---

Remarc lives in your menu bar. Left-click the icon to open the popover with your comments, right-click it for a utility menu, or press `Ctrl+Option+R` to open the popover from anywhere.

## Menu bar icon

The menu bar icon shows a count badge when you have comments. When a new comment lands, the badge bounces with the updated count.

When Remarc is paused, the icon dims and selection detection stops. Pause and resume from the right-click menu.

## Popover

The popover lists comment cards for the active session, with a session bar for switching between [sessions](/basics/sessions/). Move focus between cards with the up and down arrow keys.

The header has five buttons:

| Button | What it does |
| --- | --- |
| Search | Search across all sessions by quoted text, comment text, source app, or session name |
| History (clock icon) | Open deleted-comment history |
| New quick note | Open the composer for a standalone note |
| Screenshot comment | Start a screen region capture |
| Crit Mode (mic icon) | Record spoken feedback (macOS 26 or later only) |

The footer holds session-wide actions:

| Button | What it does |
| --- | --- |
| Copy All | Copy every comment in the session to the clipboard |
| MCP | Show MCP (Model Context Protocol) status and a sample agent prompt |
| Resolve All | Mark every comment in the session resolved, after confirmation |
| Delete All | Delete every comment in the session, after confirmation |
| Export to file | Save the session's comments to a file |
| Settings | Open the Settings window |

The MCP button carries a status dot: green means an agent can read your comments, orange means a dependency is missing (click for details), red means MCP is not connected. See [agent integrations](/agents/overview/).

## Right-click menu

Right-click the menu bar icon for quick actions:

- **Copy All** - copy the active session's comments
- **New Quick Note** - open the composer
- **Detach Window** / **Re-attach Window** - toggle the floating window
- **Pause** / **Resume** - stop or restart selection detection
- **Preferences...** - open the Settings window
- **Quit**

## Detached window

Detach Window turns the popover into a floating window that stays available while you work. A pin button appears in its top-right corner: pin the window to keep it on top of other windows, unpin to let it behave normally. Choose Re-attach Window from the right-click menu to return to the popover.
