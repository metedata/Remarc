# Web Context Grabbing for Remarc

**Date:** 2026-03-05
**Status:** Approved

## Problem

When commenting on web content, Remarc captures only the selected text and window title. Developers collaborating with AI need richer context: which React component they're looking at, its source file path, the element HTML, and the component hierarchy.

## Inspiration

[react-grab](https://github.com/aidenybai/react-grab) — an npm script that captures React component metadata (name, file path, hierarchy, HTML) for AI coding agents. Uses [bippy](https://github.com/aidenybai/bippy) to hook into React's fiber tree via `__REACT_DEVTOOLS_GLOBAL_HOOK__`.

## Scope

Replicate react-grab's context capture integrated into Remarc with:

- **Enriched text selection** — when selecting text in a Chromium browser, automatically attach web context (component name, file path, hierarchy, element HTML)
- **Enriched screenshots** — when screenshotting a browser window, attach web context for elements in the captured region
- **Element grab** — new mode to hover + click a specific DOM element, creating a comment with full web context

### Out of Scope (v1)

- Extension popup/settings UI
- Vue/Svelte/Angular framework support (graceful degradation to HTML-only)
- Props/state capture (just identity + location)
- Visual diff or side-by-side views
- URL capture
- Production source map resolution

## Architecture

Three pieces communicating via localhost WebSocket:

```
Chrome Extension                    Remarc (macOS)
+---------------------+            +----------------------+
| MAIN world script   |            |                      |
| (React fiber access)|            |  WebSocket Server    |
|        |            |            |  (NWListener :9274)  |
|   postMessage       |            |        |             |
|        v            |  ws://     |        v             |
| ISOLATED content    |<---------->|  Merge web context   |
| script (WebSocket)  | localhost  |  with comment        |
+---------------------+            +----------------------+
```

## Chrome Extension

Manifest V3, minimal permissions (`activeTab`, `scripting`). Two coordinated scripts per page:

### Main-world script (`"run_at": "document_start"`, `"world": "MAIN"`)

- Registers `__REACT_DEVTOOLS_GLOBAL_HOOK__` before React loads (same mechanism as React DevTools)
- Provides fiber tree walking: given a DOM element, walks up the fiber chain to collect component names, `_source` file paths, and hierarchy
- Posts data to the isolated script via `window.postMessage`

### Isolated content script

- Holds the WebSocket connection to Remarc (`ws://localhost:9274`)
- Listens for three triggers:
  - `selectionchange` (debounced ~200ms): grabs context around selected text, sends to Remarc
  - Keyboard shortcut (`Cmd+Shift+G`): enters element grab mode (CSS highlight overlay on hover, click to capture)
  - Remarc requesting screen region context (for screenshot enrichment)

## WebSocket Protocol

Remarc runs an `NWListener`-based WebSocket server on `localhost:9274`.

### Extension -> Remarc

```json
{ "type": "selectionContext", "data": { "componentName": "LoginForm", "filePath": "src/components/login-form.tsx:46", "hierarchy": "App > Layout > LoginForm > Button", "elementHTML": "<button class=\"btn\">Submit</button>" } }
```

```json
{ "type": "elementGrab", "data": { "componentName": "LoginForm", "filePath": "src/components/login-form.tsx:46", "hierarchy": "App > Layout > LoginForm > Button", "elementHTML": "<button class=\"btn\">Submit</button>" } }
```

```json
{ "type": "regionContext", "data": { "elements": [...] } }
```

### Remarc -> Extension

```json
{ "type": "regionQuery", "data": { "screenX": 100, "screenY": 200, "width": 400, "height": 300 } }
```

## Data Model Changes

### New CommentType case

```swift
case webElement(componentName: String?, filePath: String?)
```

With matching `displayName` ("Web Element"), `iconName` (`chevron.left.forwardslash.chevron.right`), `identifier` ("webElement").

### New WebContext struct

```swift
struct WebContext: Codable, Equatable, Sendable {
    var componentName: String?  // "LoginForm"
    var filePath: String?       // "src/components/login-form.tsx:46"
    var hierarchy: String?      // "App > Layout > LoginForm > Button"
    var elementHTML: String?    // "<button class=\"btn\">Submit</button>"
}
```

### New optional property on Comment

```swift
var webContext: WebContext?
```

Attaches to any comment type:
- `.comment(text:)` from browser: `webContext` populated automatically
- `.screenshot(imagePath:)` from browser: `webContext` populated with elements in captured region
- `.webElement(...)` from element grab: new type + full `webContext`

## Integration Flows

### Text selection (enriched)

1. User selects text in Chrome
2. Extension detects `selectionchange`, grabs surrounding web context, sends `selectionContext` via WebSocket
3. Remarc detects selection via AX (existing flow), sees Chromium `appBundleID`
4. Matches pending web context -> attaches to comment's `webContext`
5. No UI change needed

### Screenshot (enriched)

1. User triggers screenshot; Remarc notes frontmost app is Chromium
2. After region selection, sends screen coordinates to extension via WebSocket (`regionQuery`)
3. Extension maps screen coords to viewport coords (`window.screenX/Y`), finds intersecting elements
4. Returns `regionContext`; stored on comment's `webContext`

### Element grab (new)

1. User presses `Cmd+Shift+G` in browser
2. Extension activates hover overlay (CSS highlight on hover)
3. User clicks element; extension sends `elementGrab` with full context
4. Remarc creates comment with `.webElement(...)` type and `webContext`
5. Comment input pops up for user to type critique

## UI Changes (minimal)

In CommentCardView/HistoryCardView, when `webContext` is present, show a code-location badge:

```
LoginForm . login-form.tsx:46
```

For `.webElement` type: use `chevron.left.forwardslash.chevron.right` icon, display component name as reference.

No new windows, panels, or modes on the native side.

## Context Availability by Environment

| Context              | Dev mode | Production React | Non-React |
|---------------------|----------|-----------------|-----------|
| Element HTML         | Yes      | Yes             | Yes       |
| Component name       | Yes      | Minified        | N/A       |
| Source file path     | Yes      | No              | N/A       |
| Component hierarchy  | Yes      | Minified        | N/A       |

## Performance

- **Fiber tree walk**: O(depth), microseconds. Same approach as React DevTools (millions of users).
- **`selectionchange` + debounce**: ~0ms overhead (native event, fires once after stabilization).
- **Localhost WebSocket**: Sub-millisecond round-trip (~0.1-0.3ms).
- **Swift NWListener server**: Native kernel-level networking, negligible overhead.
- **Total latency**: Under 5ms from selection to context arriving in Remarc.

## Technical Notes

- Main-world script must run at `document_start` to register the DevTools hook before React initializes
- Content scripts persist as long as the page is open (no MV3 service worker lifecycle issues)
- Use plain `ws://` (not `wss://`) for localhost to avoid known Chrome TLS performance issue
- Chromium detection via known bundle IDs: `com.google.Chrome`, `company.thebrowser.Browser` (Arc), `com.brave.Browser`, `com.microsoft.edgemac`
