# Visual Verification Toolkit Design

**Date:** 2026-02-19
**Status:** Approved

## Problem

When Claude Code makes changes to Remarc, there is no way to verify visual correctness or behavioral integrity without the developer manually building, launching, and inspecting the app. This creates a bottleneck where every change requires human-in-the-loop verification.

## Solution

A shell-based verification toolkit that allows Claude Code to autonomously build, launch, interact with, screenshot, and inspect the running Remarc app after making changes.

## Architecture

### Components

| Component | Type | Purpose |
|-----------|------|---------|
| `scripts/verify.sh` | Shell script | Build, launch, orchestrate verification |
| `tools/ax-inspect/` | Swift CLI (SPM) | AX element inspection & interaction |
| `tests/screenshots/` | Directory (gitignored) | Screenshot storage |
| Accessibility identifiers | Code changes | Added to key SwiftUI views for reliable element lookup |

### Build & Launch

1. Build the app with `xcodebuild build` using the Debug scheme and workspace
2. Kill any running instance of Remarc (`killall Remarc`)
3. Launch the fresh build from DerivedData
4. Poll for process readiness + short delay for UI initialization

The app is `LSUIElement=YES` (menu bar agent, no dock icon), so it runs without stealing focus.

### UI Interaction

Two complementary tools:

**AppleScript (`osascript`)** for high-level actions:
- Click menu bar status items
- Trigger keyboard shortcuts (global hotkey for comment input)
- Type text into fields
- Navigate menus

**Swift CLI (`ax-inspect`)** for AX-based inspection:
- Find windows by title, role, or subrole (critical for borderless NSPanel floating windows)
- Read element hierarchy, values, positions, sizes
- Click/interact with specific AX elements by identifier
- Dump AX tree to JSON for analysis
- Report window frames for targeted screenshot cropping

The Swift CLI is necessary because AppleScript cannot reliably target borderless floating `NSPanel` windows that Remarc uses for its tooltip, comment input, corner widget, and viewer.

### Screenshot Capture

- `screencapture -x` for silent full-screen or region capture
- Saved to `tests/screenshots/` with timestamped filenames (e.g., `2026-02-19_14-30-00_corner-widget.png`)
- Claude Code views screenshots via the Read tool (multimodal image support)
- AX tool reports window frames to enable cropped captures of specific panels

### Accessibility Identifiers

Currently zero `accessibilityIdentifier` values exist in the codebase. We add them to key views:

- `remarc.tooltip` — Selection tooltip
- `remarc.commentInput` — Comment input panel
- `remarc.commentInput.textField` — Comment text field
- `remarc.commentInput.submitButton` — Submit button
- `remarc.cornerWidget` — Corner widget (collapsed)
- `remarc.cornerWidget.expanded` — Corner widget (expanded)
- `remarc.cornerWidget.commentCount` — Comment count label
- `remarc.viewer` — Viewer window
- `remarc.viewer.commentList` — Comment list in viewer
- `remarc.viewer.commentDetail` — Comment detail pane

### Verification Workflow

After making code changes, Claude Code runs:

```
1. Edit code
2. Build (xcodebuild)
3. Launch app
4. Run verification steps:
   a. Screenshot the corner widget -> verify it appears
   b. Simulate text selection (AppleScript) -> screenshot tooltip
   c. Click "Add Comment" -> screenshot input panel
   d. Type comment + submit -> screenshot corner widget (count updated)
   e. Open Viewer via menu -> screenshot viewer with comment listed
5. Inspect AX tree for key elements (correct text, correct counts)
6. Report results with screenshots as evidence
```

### ax-inspect CLI Design

Swift Package Manager executable (~200 lines):

```
ax-inspect list-windows --app "Remarc"
ax-inspect tree --window <id> [--identifier <id>]
ax-inspect find --app "Remarc" --identifier "remarc.cornerWidget"
ax-inspect read --app "Remarc" --identifier "remarc.cornerWidget.commentCount"
ax-inspect click --app "Remarc" --identifier "remarc.commentInput.submitButton"
ax-inspect frame --app "Remarc" --identifier "remarc.viewer"
```

Uses `ApplicationServices` framework / `AXUIElement` API.

## What This Does NOT Cover

- Automated baseline screenshot comparison (can be added later)
- CI/CD integration (this is a local development tool)
- XCUITest-based regression suite (can be layered on later)
- Testing on multiple macOS versions

## File Layout

```
Remarc/
  scripts/
    verify.sh              # Main orchestration script
  tools/
    ax-inspect/
      Package.swift        # SPM package
      Sources/
        main.swift         # CLI entry point
        AXHelpers.swift    # AX utility functions
  tests/
    screenshots/           # gitignored
      .gitkeep
```
