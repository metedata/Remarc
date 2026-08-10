# Screenshot Comments Design

**Date:** 2026-02-27
**Status:** Approved

## Problem

Remarc only supports text selection comments. Users want to capture visual context — UI bugs, design issues, layout problems — and attach comments to screenshots. The exported output should include image references that coding tools (Claude Code, Codex) can locate.

## Solution

Add native region screenshot capture using ScreenCaptureKit's `SCScreenshotManager.captureImage(in: CGRect)` with a custom full-screen overlay for region selection. Screenshots are saved as PNGs, referenced in the existing comment data model via a new `CommentReference.screenshot` case, and displayed as thumbnails in the comment list.

## Capture Flow

```
User presses screenshot hotkey OR clicks button in popover
    |
[ScreenCaptureService] Check Screen Recording permission
    |
    +-- Not granted --> Show permission panel (CaAML pattern)
    |                   Deep link: System Settings > Screen Recording
    |                   Poll CGPreflightScreenCaptureAccess() every 0.5s
    |                   On grant: dismiss panel, proceed with capture
    |
    +-- Granted --> Create full-screen overlay NSPanel
                    - Screen-sized, borderless, .screenSaver level
                    - Semi-transparent dark background (black @ 30%)
                    - Crosshair cursor
                    |
                    User drags to select region
                    - Live rubber-band rectangle during drag
                    - Selected region shown as clear cutout
                    - Escape to cancel
                    |
                    User releases mouse
                    - Overlay dismissed immediately
                    - SCScreenshotManager.captureImage(in: selectedCGRect)
                    - Save PNG to ~/Library/Application Support/Remarc/images/{uuid}.png
                    - If "copy to clipboard" setting enabled, also copy to pasteboard
                    |
                    [CommentInputController] show comment panel
                    - Positioned adjacent to selectedCGRect
                    - Thumbnail preview in quote area
                    - User types comment, saves
                    |
                    Comment created with .screenshot(imagePath:) reference
```

## Data Model

### CommentReference (new case)

```swift
public enum CommentReference: Codable, Equatable, Sendable {
    case textSelection(text: String)
    case quickNote
    case screenshot(imagePath: String)  // relative to App Support/Remarc/
}
```

`imagePath` is stored as a relative path (e.g. `images/A1B2C3D4.png`). Image files live at `~/Library/Application Support/Remarc/images/{uuid}.png`.

PersistenceManager already creates the `images/` directory on init — no storage changes needed.

### Cleanup

When a screenshot comment is permanently deleted (`permanentlyDeleteComment`), also delete the image file from disk.

## UI

### CommentCardView (popover list)

- Thumbnail (max ~320pt wide, aspect-preserved, rounded corners) where quoted text normally goes
- **Click** thumbnail: opens full-size preview panel (separate NSPanel, native resolution, comment text below, dismiss on click outside)
- **Right-click** thumbnail: context menu with:
  - "Copy Image" — copies to clipboard
  - "Save Image As..." — NSSavePanel to export PNG

### CommentInputView (panel after capture)

- Same layout as text selection comments
- Quote area shows small thumbnail of captured screenshot instead of italic text
- Comment text input below

### CommentEditorView (edit existing comment)

- Larger screenshot preview above text editor

## Triggers

### Hotkey

Register `KeyboardShortcuts.Name.screenshotComment` with a default (e.g. Cmd+Shift+S). Configurable via `KeyboardShortcuts.Recorder` in Settings General tab (second recorder row).

### Button

Camera/screenshot icon button in the popover header. Triggers the same overlay capture flow.

## Settings

New toggle in General tab: **"Copy screenshot to clipboard on capture"** (default: off). When enabled, the captured image is placed on the clipboard immediately after capture, before the comment panel appears.

## Permissions

Adapts the CaAML/Relinq permissions pattern for Screen Recording:

- **Check:** `CGPreflightScreenCaptureAccess()` — returns bool, no prompt
- **Trigger:** Lazy — on first screenshot attempt, if not granted, show permission panel
- **Panel UI:** State machine: `needsPermission` -> `waitingForGrant` -> `granted`
- **Deep link:** `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
- **Poll:** Timer every 0.5s checking `CGPreflightScreenCaptureAccess()` until granted
- **Grant detected:** Dismiss panel, proceed with capture
- **Skip/denied:** Cancel, return to normal app state

No change to the onboarding flow.

## Export

- **Markdown:** `![screenshot](images/{uuid}.png)` followed by comment text
- **JSON:** `"imagePath": "images/{uuid}.png"` field in export object
- Cloud upload deferred to follow-up feature

## Key Technical Decisions

- **ScreenCaptureKit over CGWindowListCreateImage:** CGWindowListCreateImage is obsoleted in macOS 15.0. SCScreenshotManager.captureImage(in: CGRect) is the replacement.
- **Screen Recording permission accepted:** Monthly nag on macOS 15+ is a trade-off for the premium custom-overlay UX. The permission is requested lazily, not during onboarding.
- **Relative image paths:** Keeps comments.json lean and data portable. No base64 embedding.
- **No annotations in MVP:** Raw capture only. Annotations (arrows, highlights) are a follow-up feature.
- **No cloud upload in MVP:** Local paths only. Cloud upload for AI web app compatibility is a follow-up.

## Files Expected to Change

| Area | Files |
|------|-------|
| Data model | `Models/CommentReference.swift` — add `.screenshot` case |
| Capture service | New `Services/ScreenCaptureService.swift` — overlay, region selection, SCScreenshotManager |
| Permission UI | New `Views/ScreenRecordingPermissionController.swift` — CaAML-style permission panel |
| Hotkey | `Utilities/GlobalHotkey.swift` — register `.screenshotComment` shortcut |
| Comment input | `Views/CommentInputWindowController.swift` — accept screenshot, show thumbnail |
| Comment card | `Views/CommentCardView.swift` — thumbnail display, click preview, right-click menu |
| Comment editor | `Views/CommentEditorView.swift` — larger screenshot preview |
| Preview panel | New `Views/ScreenshotPreviewController.swift` — full-size image preview |
| Settings | `Views/PreferencesWindowController.swift` — second Recorder row, clipboard toggle |
| Settings storage | `Services/SettingsManager.swift` — `copyScreenshotToClipboard` bool |
| Export | `Services/ExportManager.swift` — handle screenshot references |
| Persistence | `Services/PersistenceManager.swift` — delete image on comment delete |
| App controller | `AppController.swift` — register screenshot hotkey, wire popover button |
