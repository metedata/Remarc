# Context Capture Research

**Date:** 2026-03-06
**Status:** Research (not yet planned)

## Goal

Explore all possible ways Remarc could capture richer contextual feedback for AI agents beyond what's already built/planned.

## What Remarc Already Captures

| Input | Context Captured |
|-------|-----------------|
| Text selection (AX API) | Selected text, window title, app bundle ID |
| Screenshot (ScreenCaptureKit) | Region image, positioned comment |
| Chrome extension (planned) | React component name, file path, hierarchy, element HTML |
| Voice (planned) | Transcribed speech as comment text |

## Design Philosophy (from discussion)

- **Smart-automatic**: silently attach useful metadata, don't dump everything
- **Signal over noise**: grab the minimum that makes a comment self-explanatory when an agent reads it
- **User discretion**: heavier context should be opt-in; lean metadata can be always-on

## Research Findings

### 1. macOS Accessibility API (AXUIElement) — Full Window Content

ChatGPT's "Work with Apps" feature uses the macOS AX API to read full window content. Key APIs:

- `kAXFocusedUIElementAttribute` — focused element
- `kAXValueAttribute` — full text content
- `kAXSelectedTextAttribute` — selected text (Remarc already uses this)
- `kAXSelectedTextRangeAttribute` — position of selection within full text
- `kAXChildrenAttribute` — walk the element tree

Requires Accessibility permission (Remarc already has this).

**App-by-app AX quality (tested on real machine):**

| App Type | AX Content Quality | Notes |
|----------|-------------------|-------|
| Warp (Electron terminal) | Full text of entire session | Single `AXTextArea` with all content |
| Native code editors (Xcode, TextEdit) | Full document text | File path in window title |
| Browsers (Chrome, Arc) | Structural only (buttons, groups) | No page text — Chrome extension is the right approach |
| iOS Simulator | Opaque | No AX tree access without `idb` or XCUITest |

### 2. Terminal Context — Warp Deep Dive

**Tested with 4 tabs open in one Warp window:**

```
AXWindow "Remarc" (2880x1590)
  AXTextArea value[49216 chars] ← ALL 4 tabs merged into one blob
  AXToolbar
  AXButton x3
```

**Finding:** Warp exposes ONE `AXTextArea` regardless of how many tabs are open. 4 tabs = 49K chars concatenated. Individual tabs/panes are NOT separate AX elements.

**Implication:** Cannot distinguish which agent session a comment relates to via AX alone. However, surrounding-context extraction (±20 lines around `kAXSelectedTextRange`) could still work — the selection position maps to a specific location within the blob, so you'd get the right tab's content around the selection.

**Verdict:** Not immediately useful. The selected text alone covers most terminal cases. Surrounding context is a possible future enhancement but low priority.

### 3. iOS Simulator Context

**Available via `xcrun simctl`:**
- Screenshots: `xcrun simctl io booted screenshot output.png`
- Screen recording: `xcrun simctl io booted recordVideo`
- Clipboard sync: `xcrun simctl pbpaste booted` / `pbcopy`
- App info: `xcrun simctl appinfo booted <bundle-id>`

**NOT available without extra tooling:**
- UI hierarchy / AX tree: requires Facebook's `idb` (`idb ui describe-all`) or XCUITest
- Element values, view hierarchy — Simulator is a black box to AX

**Possible approach:** Screenshot + Apple Vision OCR (`VNRecognizeTextRequest`) to extract visible text from simulator content. Not deep context, but better than nothing.

### 4. Other Opportunities Identified

**Low-hanging fruit:**
- **Richer metadata per comment** — parse file path from window title (Xcode: "File.swift — Project", VS Code: "file.ts — folder"), attach line number from AX selection position. Zero friction, always on.
- **Clipboard-aware comments** — "create comment from clipboard" action. If user just copied an error, image, or code, one action turns it into a comment.

**Medium effort:**
- **App-specific context profiles** — different parsing per app. Xcode: project/scheme/file. VS Code: workspace/branch/file. Figma: layer name.
- **OCR for non-accessible content** — Vision framework on screenshots for Simulator, PDF viewers, image-heavy apps.

**Higher effort:**
- **On-device auto-categorization** — Apple Foundation Models framework (macOS 26+) to auto-tag comments as bug/design/feature/question.
- **Drag-and-drop capture** — system-wide drop target in menu bar using NSItemProvider.

## Sources

- [ChatGPT Work with Apps](https://help.openai.com/en/articles/10119604-work-with-apps-on-macos) — uses AX API for screen awareness
- [AXUIElement docs](https://developer.apple.com/documentation/applicationservices/axuielement)
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/)
- [Apple Foundation Models framework](https://developer.apple.com/documentation/FoundationModels)
- [VNRecognizeTextRequest](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
- [iOS Simulator MCP](https://github.com/whitesmith/ios-simulator-mcp) — uses `idb` for UI hierarchy
- [AXorcist](https://github.com/steipete/AXorcist) — Swift wrapper for AX API
- [simctl reference](https://nshipster.com/simctl/)
