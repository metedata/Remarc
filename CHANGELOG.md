# Changelog

Notable changes to Remarc. The [GitHub Releases page](https://github.com/metedata/Remarc/releases) is the authoritative list going forward.

## 0.5.1 - 2026-08-06

- Fixes an update issue where the previous Claude Code integration could be removed before the new plugin was installed
- More reliable one-click plugin install when the command line prints warnings

## 0.5.0 - 2026-08-06

- Claude Code integration is now a plugin: one-click install from Preferences or onboarding, with automatic cleanup of the old integration
- Webhooks: send comment events (created, resolved, deleted) to any service as HTTP POST
- Compact timestamps on comment cards, loopback-only extension listener, and an updated speech recognition stack

## 0.4.1 - 2026-05-12

- Improvements to web context capture when commenting on web pages
- Improvements to dictation and voice notes
- Bug fixes and polish

## 0.4.0 - 2026-05-08

- Improved MCP integration logic; Remarc now auto-installs a skill for Claude / Codex / Cursor
- Added MCP integration installers for Codex and Cursor
- Improved Chrome/web context capture for comments and screenshots
- Improved dictation reliability and microphone selection; built-in mic is preferred over AirPods unless a better mic is available
- Lots of other quality-of-life improvements

## 0.3.3 - 2026-03-31

- Added Show in Dock preference for window management
- Onboarding and settings windows are now focusable and miniaturizable
- Fixed MCP/hook script paths for release builds
- Fixed tooltip dismissal on activation policy switch
- Improved settings titlebar appearance

## 0.3.2 - 2026-03-27

- Lowered minimum macOS version from 14.4 to 14.0 (Sonoma)

## 0.3.1 - 2026-03-24

- Added Chrome extension information to settings and invite page

## 0.3.0 - 2026-03-24

- New landing page for the Remarc Early Testing program
- Fixed comment and overlay positioning on external displays
- Added tooltip position setting (above or below selection)
- Added Open Remarc and Start Crit Mode global shortcuts
- Added sound effects toggle and improved dictation sound timing
- Fixed tooltip shadow clipping and AX activation fallback

## 0.2.2 - 2026-03-21

- Added mic and screen recording permission checks to onboarding
- Added paste last dictation shortcut (Ctrl-Opt-L)
- Added Claude Desktop setup section and permissions tip in settings
- Improved button contrast in dark mode
- Fixed crash when switching audio input device between recordings
- Fixed push-to-talk keyUp forwarding to comment box
- Changed default shortcuts to use Control+Option

## 0.2.1 - 2026-03-21

- Improved first-run reliability for MCP dependency detection
- Show MCP error state in main window when Node.js or Claude CLI is missing

## 0.2.0 - 2026-03-21

- Added voice input with WhisperKit and Parakeet transcription engines
- Added dictation mode with fn/globe key shortcut support
- Added Claude Code integration with MCP server, hooks, and session management
- Added in-app feedback feature
