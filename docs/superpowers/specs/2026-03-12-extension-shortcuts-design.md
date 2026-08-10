# Extension Shortcuts — Configurable from App

**Date:** 2026-03-12
**Status:** Approved

## Problem

The Chrome Extension's keyboard shortcuts (grab element, region select) are hardcoded in `manifest.json` and can only be changed via Chrome's buried `chrome://extensions/shortcuts` page. Users should be able to configure these shortcuts directly from the Remarc app settings.

## Approach

Replace Chrome's `commands` API as the primary shortcut mechanism with custom `keydown` listeners in the content script. The Remarc app becomes the single source of truth for shortcut configuration, syncing to the extension via the existing WebSocket connection.

This is the same approach used by Vimium and Surfingkeys — proven at scale.

## Design

### Data Model & Storage

**App side — `ExtensionShortcut` struct + `SettingsManager`:**

New `Codable` struct in a dedicated file (e.g., `Models/ExtensionShortcut.swift`):
```swift
struct ExtensionShortcut: Codable, Equatable {
    let key: String          // Web-compatible key name (e.g., "G", "X", "F2")
    let modifiers: [String]  // Web modifier names: "Alt", "Shift", "Control", "Meta"
}
```

This uses **web `event.key` names**, not macOS `CGKeyCode` values. The shortcut recorder widget must capture NSEvent key presses and convert to web key names (e.g., `kVK_ANSI_G` → `"G"`, modifier flags → `["Alt", "Shift"]`).

Display conversion: `["Alt", "Shift"] + "G"` → `"⌥⇧G"` using a simple symbol mapping.

`SettingsManager` properties:
- `extensionGrabElementShortcut: ExtensionShortcut` — persisted as JSON in UserDefaults. Default: `ExtensionShortcut(key: "G", modifiers: ["Alt", "Shift"])`
- `extensionRegionSelectShortcut: ExtensionShortcut` — Default: `ExtensionShortcut(key: "R", modifiers: ["Alt", "Shift"])`

Sync trigger: `WebSocketService` observes these properties via Combine (`SettingsManager.$extensionGrabElementShortcut` / `$extensionRegionSelectShortcut`) and calls `sendShortcutConfig()` on change. This keeps the dependency direction correct: WebSocketService depends on SettingsManager, not the reverse.

**Extension side — `chrome.storage.local`:**
```json
{
  "shortcuts": {
    "grab-element": { "key": "G", "modifiers": ["Alt", "Shift"] },
    "region-select": { "key": "R", "modifiers": ["Alt", "Shift"] }
  }
}
```

Loaded by content script on injection. Updated when WebSocket receives new config.

### Sync & Staleness Prevention

Three sync points ensure the extension never has stale shortcuts:

1. **WebSocket connects** — app sends current `shortcutConfig` immediately. Handles browser restarts, extension reloads, reconnections.
2. **User changes shortcut** — app sends `shortcutConfig` over active WebSocket. Extension updates `chrome.storage.local` and swaps active listeners in real-time.
3. **Content script injects on new page** — loads from `chrome.storage.local` (already up-to-date from points 1 or 2).

**Edge cases:**
- **Extension loads before WebSocket connects:** falls back to `chrome.storage.local` from last sync. First-ever install uses hardcoded defaults.
- **App changes shortcuts while disconnected:** next WebSocket connection triggers sync (point 1), overwrites stale storage.
- **Multiple Chrome tabs:** each content script registers a `chrome.storage.onChanged` listener. When one tab's WebSocket handler writes to `chrome.storage.local`, Chrome automatically fires this event in every other content script instance — no explicit broadcast needed. Each listener updates its in-memory config object.
- **Extension reinstalled:** `chrome.storage.local` is cleared. Falls back to defaults until WebSocket reconnects.

**Fallback chain:** WebSocket config → `chrome.storage.local` → hardcoded defaults.

Note: hardcoded defaults in the content script match the old `suggested_key` values (`Alt+Shift+G`, `Alt+Shift+R`) so there is no gap when `suggested_key` is removed from the manifest — first-time users get working shortcuts immediately before any WebSocket sync.

### Settings UI

**Shortcuts tab — "Extension Shortcuts" section:**
- Below existing app shortcuts
- Two rows: "Grab Element" and "Region Select"
- Custom shortcut recorder widget (click to record, press combo, validates at least one modifier)
- Displays formatted shortcut (e.g., "⌥⇧G")
- "Reset to Default" per shortcut
- Conflict detection: reads currently configured `KeyboardShortcuts` shortcuts via `KeyboardShortcuts.getShortcut(for:)` and warns (non-blocking) if the chosen combo matches an existing app shortcut. Does not check Chrome-level or system-level conflicts.
- Subtle connection status indicator or "Requires Chrome Extension" label

**Chrome Extension tab — "Shortcuts" section:**
- Same two recorders, above existing "Web Context Metadata" toggles
- Binds to same `SettingsManager` properties — editing in either location stays in sync

### Content Script Keyboard Handling

**Listener setup (`content.js`, `document_start`):**
- Load shortcuts from `chrome.storage.local`, fall back to defaults
- Register single `keydown` listener on `document` with `{ capture: true }`
- Match logic: `event.key.toUpperCase()` vs stored key, check `altKey`, `shiftKey`, `ctrlKey`, `metaKey` against stored modifiers
- On match: `preventDefault()`, `stopPropagation()`, trigger action
- **Input suppression:** skip shortcut activation if `event.target` is an `<input>`, `<textarea>`, or `contenteditable` element — prevents accidental triggers while typing in form fields

**Hot-swapping:**
- Single listener reads from an in-memory config object on each keypress
- WebSocket `shortcutConfig` message: update `chrome.storage.local` + in-memory config
- `chrome.storage.onChanged`: other tabs pick up changes immediately

**Manifest changes:**
- Remove `suggested_key` from both commands
- Keep command names and descriptions (user-assignable fallback in Chrome's UI)

**Background service worker:**
- Continue listening for `chrome.commands.onCommand` — relay to content script via `chrome.tabs.sendMessage`
- Free fallback if user manually assigns shortcuts in Chrome's UI

### WebSocket Protocol

**New message (app → extension):**
```json
{
  "type": "shortcutConfig",
  "data": {
    "grab-element": { "key": "G", "modifiers": ["Alt", "Shift"] },
    "region-select": { "key": "R", "modifiers": ["Alt", "Shift"] }
  }
}
```

Sent on connection establishment and on every shortcut change.

No new extension → app messages. Extension is a passive consumer.

### Changes by File

**App — modify:**
- `SettingsManager.swift` — 2 new `@Published` properties with `didSet` triggering sync
- `WebSocketService.swift` — `sendShortcutConfig()` method, called in `handleNewConnection()` and via Combine observation of SettingsManager shortcut properties
- `PreferencesWindowController.swift` — shortcut recorder UI in Shortcuts and Chrome Extension sections

**Extension — modify:**
- `manifest.json` — remove `suggested_key` from commands
- `content.js` — `keydown` listener with capture, shortcut config loading, `chrome.storage.onChanged` handler, new `shortcutConfig` case in `ws.onmessage` handler
- `background.js` — `chrome.commands.onCommand` relay to active tab
- `popup.html` + `popup.js` — replace hardcoded shortcut labels (`⌥⇧G`, `⌥⇧R`) with dynamic rendering from `chrome.storage.local` shortcut config

**New files:**
- `Models/ExtensionShortcut.swift` — `ExtensionShortcut` struct (Codable, Equatable)

**No changes to:**
- `WebContext` model
- Existing WebSocket message types
- `main-world.js`
