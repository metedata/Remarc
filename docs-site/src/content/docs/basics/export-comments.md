---
title: Copy & export comments
description: Copy a Remarc session's comments to the clipboard for an agent prompt, or save them to a Markdown or JSON file with full format control.
---

Get a session's comments out of Remarc in two ways: copy them to the clipboard, formatted for pasting into an agent prompt or a doc, or save them to a Markdown or JSON file. Both act on the active session.

## Copy All

Click **Copy All** in the popover footer. Remarc copies every comment in the active session to the clipboard as Markdown, formatted according to your Export settings, and shows a toast confirming the count. Copy All is also available from the menu bar icon's right-click menu.

The `Ctrl+Option+P` shortcut (listed as **Paste All** in the Shortcuts tab) goes one step further: it copies the session in your File Export format and pastes it straight into the app you are working in.

## Export to a file

Click the export button in the popover footer to save the session to a file. A save dialog appears with the session name as the filename. The file format defaults to Markdown; change it under **File Export** in the Export settings tab.

JSON export wraps the comments in an object with the session name and an export timestamp. Each comment includes its number, selected text, comment text, type, source app, timestamp, and any attachments or web context.

## Format settings

The **Export** tab in Settings controls the clipboard and Markdown format. A live preview on the right updates as you change options; hover a control to highlight what it affects.

| Setting | Options | Default |
| --- | --- | --- |
| Reference prefix | Blockquote, Re: Prefix, Quoted | Blockquote |
| Comment prefix | Comment:, Note:, Dash, Arrow, None | Comment: |
| List style | Numbered, Bulleted, None | Numbered |
| Comment dividers | Rule (`---`), Double (`===`), Dotted, Blank Line | Blank Line |
| Metadata divider | Pipe, Dash, Dot, Comma | Pipe |
| Date format | 5 styles, including `Feb 28` and `2026-02-28` | Short (`Feb 28`) |
| Time format | 12-hour, 24-hour | 12-hour |

**Include in Export** toggles choose what metadata is attached to each comment:

| Toggle | Default |
| --- | --- |
| Type | On |
| Source app | On |
| Date | On |
| Include time | Off |
| Status | Off |
| Comment ID | On |
| MCP hint | On |

The MCP hint appends a short HTML comment telling an agent which session the remarks came from and to use the `remarc_list_comments` MCP (Model Context Protocol) tool to read and resolve them. Remarc only adds it when an [agent integration](/agents/overview/) is enabled.

## After copying

The **After copying** setting decides what happens to the comments once they are copied or exported:

- **Always Ask** (default): a "Clear exported comments?" prompt appears in the popover with Keep and Clear buttons. It dismisses itself after a few seconds if you do nothing, keeping the comments.
- **Always Keep**: comments stay put.
- **Always Delete**: a short countdown clears the session's comments, with an **Undo** button to cancel.

:::caution
Always Delete removes comments right after copying, so MCP tools will no longer find them to resolve. Settings shows a warning when this is combined with the MCP hint.
:::
