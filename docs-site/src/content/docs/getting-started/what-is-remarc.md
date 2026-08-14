---
title: What is Remarc
description: Remarc is a free, open source macOS menu bar app for capturing contextual comments anywhere and handing them off to AI agents.
---

Remarc is a free, open source macOS menu bar app for contextual commenting: select text, capture a screenshot, grab a web element, or speak your feedback anywhere on your Mac, then hand the resulting comments to an AI agent. It lives in the menu bar with no dock icon by default, and the code is at [github.com/metedata/Remarc](https://github.com/metedata/Remarc).

## The core loop

1. Capture context. Select text in any app and click the Comment tooltip that appears, drag out a screenshot region, grab an element on a web page, or start talking.
2. Write (or dictate) what you think. Remarc records the quoted text, the source app, and any image or web context alongside your note.
3. Hand off. Copy everything to the clipboard for an agent prompt, let Claude Code, Codex, OMP, or Cursor read and resolve comments directly over MCP (Model Context Protocol), export to Markdown or JSON, or fire webhooks to your automation tools. See the [agent integrations overview](/agents/overview/).

## Comment types

Each comment card records where it came from:

| Type | Where it comes from |
|---|---|
| Comment | A text selection in any app |
| Screenshot | A captured screen region, with annotation and redaction tools |
| Quick Note | A standalone note, no selection needed |
| Crit | Crit Mode, which splits spoken feedback into separate comment cards |
| Web Element | The Chrome extension, with CSS selectors, React component info, and page context |

Comments are grouped into [sessions](/basics/sessions/) and carry a [status](/basics/statuses-and-history/) (Open, Handed Off, In-Progress, Resolved). Everything is [stored locally on your Mac](/reference/data-and-privacy/).

## System requirements

- macOS 14 or later.
- Voice features (Dictation, Voice comments, Crit Mode) require macOS 26 (Tahoe) or later. On older versions those controls are hidden; everything else works.

To try it, [install Remarc](/getting-started/installation/).
