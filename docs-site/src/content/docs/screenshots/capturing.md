---
title: Capture screenshot comments
description: Capture a screen region with Ctrl+Option+S and attach a Remarc comment to the image, adjustable until the moment you save.
---

A screenshot comment attaches your note to an image of a screen region. Press `Ctrl+Option+S` (or click the Screenshot button in the popover header) to start a capture. Capturing requires the Screen Recording permission - see [permissions](/getting-started/permissions/).

## Capture a region

1. Press `Ctrl+Option+S`. The screen dims and the cursor becomes a crosshair.
2. Drag to select a region. A white border and a live size label show the selection.
3. Release. The comment composer opens next to the region.
4. Write your comment and save it with `Cmd+Return`.

While the composer is open, the region stays adjustable: drag a corner handle to resize from that corner, drag an edge handle to resize one side, or drag anywhere outside the handles to draw a new region. Press `Escape` at any point to cancel.

Remarc captures the screen when you save the comment, so the image shows what was on screen at that moment. The composer itself never appears in the capture.

An Annotate pill sits next to the region during capture. Use it to draw arrows, shapes, and redactions on the screenshot before saving - see [annotate and redact](/screenshots/annotating-and-redacting/).

## The preview panel

The preview panel opens when you click a screenshot thumbnail on a comment card. It shows the full image with four controls: Copy Image, Save As, Annotate, and Close. Press `Escape` to close it.

## Settings

Two screenshot settings live in Settings > General:

| Setting | Default | Notes |
| --- | --- | --- |
| Add screenshots to clipboard | Off | Also copies the image to the clipboard when a capture is saved |
| Image retention | 1 week | 1 week, 2 weeks, 1 month |

Remarc keeps images longer than comment history so exported references stay valid.

## Screenshot & Send Instantly

A second shortcut, Screenshot & Send Instantly, captures the same way but hands the saved comment to a live Claude Code session immediately instead of waiting for the agent's next prompt.

The shortcut is unassigned by default, and its row appears in Settings > Shortcuts only when "Allow comments to wake Claude Code sessions" is enabled - see [Claude Code](/agents/claude-code/).
