---
title: Comment on text selections
description: Select text in any macOS app and attach a Remarc comment that quotes the selection and records which app it came from.
---

Remarc's core feature: select text in any app and attach a comment to it. The comment quotes the selection and records which app it came from.

## Create a comment

1. Select text in any app.
2. A small **Comment** tooltip appears near the selection. Click it, or press `Ctrl+Option+C`.
3. The composer opens, quoting the selected text. Write your comment and press `Cmd+Return` to save.

The saved comment lands in the session shown in the composer's session picker, and its card shows the quote, your comment, and the source app. See [sessions](/basics/sessions/) for how comments are grouped.

:::note
Reading selections from other apps requires the Accessibility permission. See [permissions](/getting-started/permissions/).
:::

## The composer

Beyond the text field, the composer offers:

- **Session picker** - choose which session the comment goes to.
- **Image attachments** - click the paperclip to attach PNG, JPEG, HEIC, or WebP files, or paste an image directly into the text field.
- `Cmd+Return` saves, `Escape` closes without saving.

## Detection settings

Five settings control when and where Remarc detects selections:

| Setting | Options | What it does |
| --- | --- | --- |
| Detection mode | Auto-detect + Hotkey (default), Hotkey Only | Auto-detect shows the tooltip whenever you select text. Hotkey Only waits for `Ctrl+Option+C`. |
| Tooltip position | Above selection, Below selection | Where the Comment tooltip appears. |
| Clean up whitespace | On/off | Normalizes whitespace in the quoted text. |
| Excluded Apps | Per-app list | Apps where Remarc never detects selections. Managed in the Excluded Apps tab. |
| Pause | Right-click menu | Stops selection detection entirely until you resume. The menu bar icon dims while paused. |

:::tip
If the tooltip appears too often, switch Detection mode to Hotkey Only. Remarc then waits for `Ctrl+Option+C` instead of reacting to every selection.
:::
