# Debug Settings Section

**Date:** 2026-03-23
**Status:** Approved

## Summary

Add a Debug section to the Remarc settings sidebar, visible only in debug builds (`#if DEBUG`). This section consolidates developer-facing tools: channel notifications, vocabulary hints editing, and reset actions.

## Motivation

Several debug/development features are either hidden (license/data reset only accessible programmatically), gated awkwardly (channel notifications buried in Claude Integration as "Experimental"), or have no UI at all (vocabulary hints require editing source code). A dedicated debug section keeps these accessible during development without shipping them to users.

## Design

### Sidebar Entry

- New `debug` case added unconditionally to `SettingsSection` enum (can't use `#if DEBUG` on individual cases because `CaseIterable` synthesizes `allCases` at compile time)
- Filtered out of `visibleSections` in release builds using `#if DEBUG` (same pattern as `voice`/`license` filtering)
- Icon: `ladybug` (SF Symbols)
- Label: "Debug" with an "Internal" badge (same style as Claude Integration's "Beta" badge)
- Appears last in the sidebar, after About
- The `debugSection` view body is gated with `#if DEBUG` in the switch statement

### Section 1: Channel Notifications

Move the "Real-time Notifications" block from Claude Integration to Debug. Simplify the framing - drop the "Experimental" badge and tooltip since the entire section is debug-only.

Contents (same as current):
- Toggle: "Enable channel notifications" (bound to `claudeCodeChannelEnabled`, disabled when Claude Code integration is off)
- Conditional help text showing the `--dangerously-load-development-channels` launch command
- Description text about how it works

### Section 2: Vocabulary Hints

Editable list of words/phrases that bias WhisperKit's decoder toward domain-specific terms.

**UI:**
- Section header: "Vocabulary Hints" with description "Words and phrases that improve speech recognition accuracy."
- List of current hints, each with a delete (x) button
- Text field + "Add" button to add new hints
- No empty state needed - the defaults are always populated on first launch

**Storage:**
- New `vocabularyHints: [String]` property in `SettingsManager`, persisted to UserDefaults
- Default value: `["Remarc", "Claude Code"]` (current hardcoded values)
- `VocabularyHints.swift` reads from `SettingsManager.shared.vocabularyHints` instead of the static array
- `promptPhrase` and `whisperPromptTokens()` remain computed properties, just sourced from the dynamic list

### Section 3: Reset Actions

Surface the existing debug reset functionality from `AppController` as buttons in the UI.

**UI:**
- Section header: "Reset" with description "Debug reset actions. These are destructive."
- "Reset License" button - calls `LicenseManager.shared.resetForTesting()`, shows confirmation dialog
- "Reset Data" button - deletes data files (existing code does not relaunch - logs "restart app to reset"), shows confirmation dialog
- Both buttons use destructive styling (red tint or similar)

**Implementation:**
- The logic already exists in `AppController.resetLicenseForTesting()` and `resetDataForTesting()`
- Extract the reset logic so it can be called from the settings view, or call through `AppController`

## Files Changed

| File | Change |
|------|--------|
| `PreferencesWindowController.swift` | Add `debug` case to `SettingsSection`, add `debugSection` view, move channel notifications block from Claude section |
| `SettingsManager.swift` | Add `vocabularyHints: [String]` property with UserDefaults persistence |
| `VocabularyHints.swift` | Read from `SettingsManager` instead of hardcoded array |
| `AppController.swift` | Make reset methods accessible from settings view (or keep and call through shared instance) |

## Out of Scope

- MCP server changes for debug gating - the UI toggle not existing in release builds is sufficient
- Persisting vocabulary hints to a file (UserDefaults is fine for a small list)
- Any changes to the channel notification protocol itself
