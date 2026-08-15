---
title: Troubleshooting & FAQ
description: Symptom-first fixes for common Remarc problems, from a missing Comment tooltip to a silent microphone, plus quick answers.
---

Each section below is a symptom, with the cause in one sentence and the steps that fix it. Quick answers to non-problem questions are at the end of the page.

## The Comment tooltip never appears

Four different causes can suppress the tooltip, so check them in order:

1. If Accessibility permission is missing, Remarc cannot read your selection. Grant it in System Settings > Privacy & Security > Accessibility; see [permissions](/getting-started/permissions/).
2. If the menu bar icon is dimmed, Remarc is paused. Right-click the icon and choose Resume.
3. If the app you are selecting in is listed under Settings > Excluded Apps, remove it there.
4. If Detection mode is set to "Hotkey Only", the tooltip never appears on its own. Workaround: press `Ctrl+Option+C` after selecting text. Resolution: switch back to "Auto-detect + Hotkey" in Settings > General.

## Voice features are missing entirely

Dictation, Voice Input, Crit Mode, and the Voice settings tab require macOS 26 (Tahoe) or later; on older versions the controls are hidden, not broken. Everything else works on macOS 14 and up.

## The microphone records silence

macOS sometimes drops Remarc's microphone grant, so recordings produce nothing without any error.

1. Re-grant access in System Settings > Privacy & Security > Microphone.
2. If recordings are still silent, reset the permission in Terminal:

   ```
   tccutil reset Microphone com.metepolat.Remarc
   ```

3. Relaunch Remarc and grant microphone access when prompted.

## The Chrome extension stays disconnected

The extension connects only in tabs loaded after it was installed, and only when it can reach the app on its port.

1. Reload your open tabs.
2. If the tabs are fresh and it still will not connect, open Settings > Chrome Extension, which shows the connection status and port 9274. If another app holds the port, quit that app and click the Retry button.
3. Check the pause toggle in the extension's popup.

## My agent cannot see comments

A harness can list the plugin as installed even when the MCP server fails to start, so an installed plugin is not proof of a working one.

1. Reinstall from Settings > MCP Integrations (the Codex row offers Repair).
2. Ask the agent to call `remarc_list_sessions`. If that call succeeds, the integration is healthy.

## Screenshot capture fails

Screenshot comments require the Screen Recording permission. Grant it in System Settings > Privacy & Security > Screen & System Audio Recording (called Screen Recording on older macOS), then try again. If macOS offers Quit & Reopen after you change the setting, accept it.

## Quick answers

**Where is my data stored?** In `~/Library/Application Support/Remarc/`, as `comments.json` plus image files. See [data, privacy & updates](/reference/data-and-privacy/).

**Is anything sent to a server?** Remarc stores comments, screenshots, and audio on your Mac. Data can leave through agents and webhooks you explicitly use; other network activity is limited to update checks, transcription model downloads, and agent plugin installs.

**How many sessions can I have?** Up to 8 active sessions, plus the permanent Inbox that catches unfiled comments. See [Sessions & the Inbox](/basics/sessions/).

**Does Remarc work with my browser?** Text selection commenting works in any Mac app, including any browser. The [Chrome extension](/chrome-extension/)'s element and region capture works in Chromium browsers: Chrome, Arc, Brave, Edge, Vivaldi, and Opera.

## Uninstall Remarc

1. If the Cursor integration is enabled, turn it off in Settings > MCP Integrations; this removes the files Remarc wrote to `~/.cursor`. If you skip this, remove the `remarc` entry from `~/.cursor/mcp.json` and delete `~/.cursor/skills/remarc/` by hand.
2. If you installed the Claude Code or Codex plugins, uninstall them from those tools (for example `/plugin` in Claude Code).
3. Quit Remarc, delete the app, and delete `~/Library/Application Support/Remarc/` to remove all data.

## Still stuck

Remarc writes no debug log by default. To capture one for a bug report, enable [debug logging](/reference/data-and-privacy/#debug-logging), relaunch Remarc, reproduce the problem, and include the tail of `~/Library/Logs/Remarc/remarc_debug.log` when you [open a GitHub issue](https://github.com/metedata/Remarc/issues). Scrub anything you consider private first, then turn logging back off. Report security problems privately as described in the [security policy](https://github.com/metedata/Remarc/security/policy).
