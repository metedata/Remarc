---
title: Settings
description: A tab-by-tab reference of every Remarc setting, with the default value and available options for each one.
---

This page lists every Remarc setting with its default, tab by tab. Open Settings from the gear button in the popover footer, or right-click the menu bar icon and choose "Preferences...".

## General

### App

These settings control startup, selection detection, and how dates appear on comment cards.

| Setting | Default | Notes |
| --- | --- | --- |
| Launch at Login | On after onboarding | Remarc registers itself as a login item when onboarding completes. |
| Show in Dock | Off | When off, the Dock icon appears only while the Settings or Permissions windows are open. |
| Detection mode | Auto-detect + Hotkey | "Hotkey Only" disables automatic selection detection; the composer opens only via `Ctrl+Option+C`. |
| Tooltip position | Above selection | Or "Below selection". |
| Date format | Short (e.g. "Aug 8") | Five styles, shown as sample dates in the picker. |
| Time format | 12-hour | Or 24-hour. |

### Clipboard

Two settings shape what ends up on the clipboard.

| Setting | Default | Notes |
| --- | --- | --- |
| Clean up whitespace | On | Normalizes whitespace in the quoted selection text. |
| Add screenshots to clipboard | Off | Also copies the captured image when you save a screenshot comment. |

### Retention

Retention settings decide how long Remarc keeps history, images, and resolved comments.

| Setting | Default | Notes |
| --- | --- | --- |
| History retention | 1 day | Options: 1 day, 1 week, 1 month. |
| Image retention | 1 week | Options: 1 week, 2 weeks, 1 month. Images are kept longer than history so exported references stay valid. |
| Delete resolved | Never | Options: Never, Immediately, After 15 min, After 1 hour, After 1 day. |
| Auto-delete inactive sessions | Off | When on, a "Delete after" picker appears: After 30 min through After 24 hours, default After 4 hours. The Inbox, the current session, and sessions with unresolved comments are never deleted. |

## Shortcuts

Rebind global shortcuts here; Remarc flags conflicts between its own shortcuts as you record them, and a Reset button restores the defaults. The Chrome extension shortcuts also appear here. The one exception is the hands-free dictation binding, which is rebound in Settings > Voice. Full list: [keyboard shortcuts](/reference/keyboard-shortcuts/).

## Voice

:::note
The Voice tab appears only on macOS 26 (Tahoe) or later.
:::

### Transcription engine

The engine settings choose which on-device model transcribes your speech; details are on [transcription engines](/voice/transcription-engines/).

| Setting | Default | Notes |
| --- | --- | --- |
| Engine | Apple Speech | Options: Apple Speech, WhisperKit, Parakeet. |
| Model (WhisperKit) | Balanced (217 MB) | Options: Fast (75 MB), Balanced (217 MB), Max (954 MB). |
| Model (Parakeet) | Multilingual (~1.2 GB) | Options: English, Multilingual. |
| Keep model in memory | Off | Faster responses, uses roughly 200-500 MB of RAM. Recommended with 16 GB+ RAM. |
| Load model on launch | Off | Appears only when "Keep model in memory" is on. |

Models download in-app with a progress bar and can be deleted later. Remarc falls back to Apple Speech until a download finishes.

### Behavior

These settings control what happens while you record.

| Setting | Default | Notes |
| --- | --- | --- |
| Sound effects | On | Start and stop sounds for recording. |
| Mute audio while recording | Off | Mutes system audio when recording starts, restores it when you stop. |
| Prefer Mac built-in mic | On | Uses known studio USB mics when present; otherwise prefers the built-in microphone over AirPods and headset mics. |
| Auto-save voice notes | Off | Saves comments created with the voice shortcut automatically. Delay picker: 1s to 5s, default 2s. |

### Dictation

Dictation settings cover the system-wide dictation shortcuts and transcription history.

| Setting | Default | Notes |
| --- | --- | --- |
| Enable dictation | On | When off, dictation shortcuts are ignored entirely. |
| Push to talk | `Ctrl+Option+D` | A "Use fn key" toggle (off by default) binds it to the fn/globe key instead. |
| Hands-free mode | Single tap | Options: Single tap, Double tap, Custom shortcut. |
| Paste last dictation | `Ctrl+Option+L` | Re-pastes the most recent transcription. |
| History retention | 1 week | Options: 1 day, 1 week, 1 month, 3 months. |

## Export

Export settings control how Copy All and file exports format your comments, with a live preview on the right; hover a control to highlight what it changes. See [copy and export](/basics/export-comments/) for how the output is used.

| Setting | Default | Notes |
| --- | --- | --- |
| Reference prefix | Blockquote | Options: Blockquote, Re: Prefix, Quoted. |
| Comment prefix | Comment: | Options: Comment:, Note:, Dash, Arrow, None. |
| List style | Numbered | Options: Numbered, Bulleted, None. |
| Comment dividers | Blank Line | Options: Rule, Double, Dotted, Blank Line. |
| Metadata divider | Pipe | Options: Pipe, Dash, Dot, Comma. |
| Include: Type | On | |
| Include: Source app | On | |
| Include: Date | On | |
| Include: Include time | Off | Enabled only when Date is on. |
| Include: Status | Off | |
| Include: Comment ID | On | Agents use these short IDs to resolve comments. |
| Include: MCP hint | On | Adds a line telling agents how to work with the comments. |
| After copying | Always Ask | Options: Always Ask, Always Keep, Always Delete. |
| File export format | Markdown | Or JSON. |

## Chrome Extension

This tab manages the [Chrome extension](/chrome-extension/)'s connection and capture behavior:

- **Connection**: live status with the port number (9274). If another app holds the port, a Retry button appears.
- **Chrome Shortcuts**: Grab Element (`Option+Shift+G`) and Select Region (`Option+Shift+R`), with a Reset to Defaults button.
- **Captured Metadata**: five toggles, all on by default, disabled until the extension has connected once: React components, Computed styles, Accessibility, Layout & structure, Element identity.

## MCP Integrations

MCP (Model Context Protocol) is how [agents](/agents/overview/) read and resolve your comments; this tab has shared delivery controls followed by setup sections for integrations Remarc manages directly.

- **Instant delivery**: "Allow comments to wake paired agent sessions" is off by default. When enabled, Send Instantly appears only for the selected Remarc session when its paired agent owns a live wake connection. The section links to [OMP setup](/agents/omp/).
- **[Claude Code](/agents/claude-code/)**: install the required `remarc` plugin and the optional, experimental `remarc-hooks` plugin. Each row shows the exact CLI commands it runs, with a copy button. Once `remarc-hooks` is installed, its Claude-specific settings cover automatic session creation and what happens when a conversation is cleared.
- **[Codex](/agents/codex/)**: an Install button (or Repair, if the plugin is present but unhealthy) plus copyable manual commands.
- **[OMP](/agents/omp/)**: the Instant delivery section links to setup. Installation and updates stay in OMP's own public marketplace; Remarc does not edit OMP profiles, scan installation directories, or show a file-derived status row.
- **[Cursor](/agents/cursor/)**: an "Enable integration" toggle with Skill and MCP server status rows. Turning it off uninstalls.
- **[Claude Desktop](/agents/claude-desktop-and-mcp-clients/)**: a ready-made JSON snippet to paste into Claude Desktop's config.
- **Other MCP clients**: a generic MCP server JSON snippet and the full skill content, for any JSON-config MCP client.

## Webhooks

This tab holds the [webhooks](/agents/webhooks/) that send comment events as HTTP POST requests to any endpoint. Each webhook has a name, URL, event checkboxes, an optional signing secret, an optional custom payload template, a test button, and an enable toggle.

## Excluded Apps

Remarc never shows the Comment tooltip in the apps listed here. Add apps with the + button (an open panel starting in /Applications), remove them with -. The list is empty by default.

## About

The About tab shows the app version and build number, the total count of remarks you have created, a "Check for Updates..." button, and links to the Website, Documentation, and GitHub.
