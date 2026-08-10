# Extension Shortcuts — Configurable from App

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to configure Chrome Extension keyboard shortcuts (grab element, region select) directly from the Remarc app settings, synced via WebSocket.

**Architecture:** The app is the single source of truth. A new `ExtensionShortcut` model stores key + modifiers. `SettingsManager` persists them in UserDefaults. `WebSocketService` sends config on connection and on change (via Combine). The content script replaces Chrome `commands` with custom `keydown` listeners loaded from `chrome.storage.local`. The popup renders shortcut labels dynamically.

**Tech Stack:** Swift/SwiftUI (app), JavaScript/Chrome MV3 (extension), WebSocket (sync), Combine (observation)

**Spec:** `docs/superpowers/specs/2026-03-12-extension-shortcuts-design.md`

---

## File Structure

**New files:**
- `app/RemarcPackage/Sources/RemarcFeature/Models/ExtensionShortcut.swift` — Codable model for key + modifiers, display formatting, NSEvent conversion

**Modified files:**
- `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift` — 2 new @Published properties + UserDefaults persistence
- `app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift` — sendShortcutConfig(), Combine observation, send on connect
- `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift` — Shortcut recorder UI in Shortcuts + Chrome Extension sections
- `extension/manifest.json` — Remove `suggested_key` from commands
- `extension/content.js` — keydown listener, shortcut config loading, WebSocket handler, chrome.storage.onChanged
- `extension/background.js` — Ensure command relay still works (minimal change)
- `extension/popup.html` — Remove hardcoded shortcut labels
- `extension/popup.js` — Dynamic shortcut label rendering from chrome.storage.local

---

## Chunk 1: Data Model & Settings Persistence

### Task 1: ExtensionShortcut Model

**Files:**
- Create: `app/RemarcPackage/Sources/RemarcFeature/Models/ExtensionShortcut.swift`

- [ ] **Step 1: Create the ExtensionShortcut struct**

```swift
import AppKit

public struct ExtensionShortcut: Codable, Equatable, Sendable {
    public let key: String           // Web event.key name: "G", "R", "F2", etc.
    public let modifiers: [String]   // Web modifier names: "Alt", "Shift", "Control", "Meta"

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }
}

// MARK: - Display Formatting

extension ExtensionShortcut {
    /// Formats as symbol string for UI display: "⌥⇧G"
    public var displayString: String {
        let symbolMap: [String: String] = [
            "Meta": "⌘",
            "Control": "⌃",
            "Alt": "⌥",
            "Shift": "⇧",
        ]
        // Fixed order: Control, Alt, Shift, Meta, then key
        let orderedModifiers = ["Control", "Alt", "Shift", "Meta"]
        let symbols = orderedModifiers
            .filter { modifiers.contains($0) }
            .compactMap { symbolMap[$0] }
        return symbols.joined() + key.uppercased()
    }

    /// Formats for Chrome popup display: "⌥⇧G"
    /// Same as displayString but could diverge if needed
    public var popupDisplayString: String { displayString }
}

// MARK: - NSEvent Conversion

extension ExtensionShortcut {
    /// Creates an ExtensionShortcut from an NSEvent key press.
    /// Returns nil if no valid key could be extracted.
    public static func from(event: NSEvent) -> ExtensionShortcut? {
        guard let characters = event.charactersIgnoringModifiers?.uppercased(),
              !characters.isEmpty else { return nil }

        // Map special keys
        let key: String
        switch event.keyCode {
        case 122: key = "F1"
        case 120: key = "F2"
        case 99:  key = "F3"
        case 118: key = "F4"
        case 96:  key = "F5"
        case 97:  key = "F6"
        case 98:  key = "F7"
        case 100: key = "F8"
        case 101: key = "F9"
        case 109: key = "F10"
        case 103: key = "F11"
        case 111: key = "F12"
        default:  key = characters
        }

        var modifiers: [String] = []
        if event.modifierFlags.contains(.control) { modifiers.append("Control") }
        if event.modifierFlags.contains(.option)  { modifiers.append("Alt") }
        if event.modifierFlags.contains(.shift)   { modifiers.append("Shift") }
        if event.modifierFlags.contains(.command) { modifiers.append("Meta") }

        return ExtensionShortcut(key: key, modifiers: modifiers)
    }

    /// Validates that the shortcut has at least one modifier key
    public var isValid: Bool {
        !key.isEmpty && !modifiers.isEmpty
    }

    /// Carbon virtual key code for conflict detection with KeyboardShortcuts library.
    /// Maps web key names to macOS Carbon key codes (kVK_ANSI_* values).
    public var carbonKeyCode: Int? {
        let map: [String: Int] = [
            "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
            "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
            "Y": 16, "T": 17, "O": 31, "U": 32, "I": 34, "P": 35,
            "L": 37, "J": 38, "K": 40, "N": 45, "M": 46,
        ]
        return map[key.uppercased()]
    }
}

// MARK: - Defaults

extension ExtensionShortcut {
    public static let defaultGrabElement = ExtensionShortcut(key: "G", modifiers: ["Alt", "Shift"])
    public static let defaultRegionSelect = ExtensionShortcut(key: "R", modifiers: ["Alt", "Shift"])
}
```

- [ ] **Step 2: Verify the file is in the correct location**

Run: `ls app/RemarcPackage/Sources/RemarcFeature/Models/ExtensionShortcut.swift`
Expected: File exists

- [ ] **Step 3: Build to verify compilation**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Models/ExtensionShortcut.swift
git commit -m "feat: add ExtensionShortcut model with display formatting and NSEvent conversion"
```

---

### Task 2: SettingsManager Properties

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift`

- [ ] **Step 1: Add UserDefaults keys**

In the `Keys` enum (around line 11-50), add:
```swift
static let extensionGrabElementShortcut = "extensionGrabElementShortcut"
static let extensionRegionSelectShortcut = "extensionRegionSelectShortcut"
```

- [ ] **Step 2: Add @Published properties**

After the last `@Published` property (line ~190, after `webContextIdentityEnabled`), add:
```swift
@Published public var extensionGrabElementShortcut: ExtensionShortcut {
    didSet {
        if let data = try? JSONEncoder().encode(extensionGrabElementShortcut) {
            defaults.set(data, forKey: Keys.extensionGrabElementShortcut)
        }
    }
}
@Published public var extensionRegionSelectShortcut: ExtensionShortcut {
    didSet {
        if let data = try? JSONEncoder().encode(extensionRegionSelectShortcut) {
            defaults.set(data, forKey: Keys.extensionRegionSelectShortcut)
        }
    }
}
```

- [ ] **Step 3: Initialize from UserDefaults in init()**

In the private `init()` (around line 210+), add before the closing brace:
```swift
if let data = defaults.data(forKey: Keys.extensionGrabElementShortcut),
   let shortcut = try? JSONDecoder().decode(ExtensionShortcut.self, from: data) {
    self.extensionGrabElementShortcut = shortcut
} else {
    self.extensionGrabElementShortcut = .defaultGrabElement
}
if let data = defaults.data(forKey: Keys.extensionRegionSelectShortcut),
   let shortcut = try? JSONDecoder().decode(ExtensionShortcut.self, from: data) {
    self.extensionRegionSelectShortcut = shortcut
} else {
    self.extensionRegionSelectShortcut = .defaultRegionSelect
}
```

- [ ] **Step 4: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift
git commit -m "feat: add extension shortcut settings to SettingsManager with UserDefaults persistence"
```

---

## Chunk 2: WebSocket Sync

### Task 3: WebSocketService Shortcut Sync

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift`

- [ ] **Step 1: Add Combine import and cancellable storage**

Add `import Combine` at the top of the file (if not already present).

Add a private property for Combine subscriptions:
```swift
private var shortcutCancellables = Set<AnyCancellable>()
```

- [ ] **Step 2: Add sendShortcutConfig() method**

Add after `requestRegionContext()` (around line 260):
```swift
public func sendShortcutConfig() {
    let settings = SettingsManager.shared
    let config: [String: Any] = [
        "type": "shortcutConfig",
        "data": [
            "grab-element": [
                "key": settings.extensionGrabElementShortcut.key,
                "modifiers": settings.extensionGrabElementShortcut.modifiers,
            ],
            "region-select": [
                "key": settings.extensionRegionSelectShortcut.key,
                "modifiers": settings.extensionRegionSelectShortcut.modifiers,
            ],
        ]
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: config),
          let connection = activeConnection
    else { return }

    let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
    let context = NWConnection.ContentContext(identifier: "shortcutConfig", metadata: [metadata])
    connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    debugLog("WebSocketService: Sent shortcut config")
}
```

- [ ] **Step 3: Send config on new connection**

In `handleNewConnection()`, inside the `.ready` case (around line 137), add after `debugLog("WebSocketService: Client connected")`:
```swift
self?.sendShortcutConfig()
```

- [ ] **Step 4: Observe SettingsManager shortcut changes via Combine**

Add a method to set up Combine observation, called from `start()` or `init`:
```swift
private func observeShortcutSettings() {
    shortcutCancellables.removeAll()
    let settings = SettingsManager.shared
    settings.$extensionGrabElementShortcut
        .dropFirst()
        .sink { [weak self] _ in
            Task { @MainActor in
                self?.sendShortcutConfig()
            }
        }
        .store(in: &shortcutCancellables)
    settings.$extensionRegionSelectShortcut
        .dropFirst()
        .sink { [weak self] _ in
            Task { @MainActor in
                self?.sendShortcutConfig()
            }
        }
        .store(in: &shortcutCancellables)
}
```

Call `observeShortcutSettings()` at the end of the `start()` method. The `shortcutCancellables.removeAll()` at the top prevents duplicate observers if `start()` is called multiple times (e.g., on retry). The `Task { @MainActor in }` wrapper ensures Swift 6 strict concurrency compliance since the Combine `.sink` closure does not inherit `@MainActor` isolation.

- [ ] **Step 5: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift
git commit -m "feat: add WebSocket shortcut config sync with Combine observation"
```

---

## Chunk 3: Settings UI

### Task 4: Shortcut Recorder View

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

- [ ] **Step 1: Add the ExtensionShortcutRecorder view**

Add a private view struct inside or near `PreferencesView`. This is a custom recorder that captures key events and converts to `ExtensionShortcut`:

```swift
private struct ExtensionShortcutRecorder: View {
    @Binding var shortcut: ExtensionShortcut
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var conflictWarning: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(isRecording ? "Press shortcut..." : shortcut.displayString)
                    .font(.system(size: 12, design: .rounded))
                    .frame(minWidth: 80)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .onDisappear { stopRecording() }

            if let conflictWarning {
                Text(conflictWarning)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private func startRecording() {
        isRecording = true
        conflictWarning = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape — cancel
                stopRecording()
                return nil
            }
            if let newShortcut = ExtensionShortcut.from(event: event), newShortcut.isValid {
                shortcut = newShortcut
                conflictWarning = checkConflict(newShortcut)
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Check for conflicts with app's global keyboard shortcuts (non-blocking warning).
    /// KeyboardShortcuts.Key.rawValue is a Carbon virtual key code (Int), so we
    /// convert our web key name to a Carbon key code for comparison.
    private func checkConflict(_ candidate: ExtensionShortcut) -> String? {
        let appShortcuts: [KeyboardShortcuts.Name] = [
            .commentOnSelection, .screenshotComment, .pasteAllComments, .voiceInput
        ]
        guard let candidateKeyCode = candidate.carbonKeyCode else { return nil }
        for name in appShortcuts {
            guard let existing = KeyboardShortcuts.getShortcut(for: name) else { continue }
            // Compare modifier flags
            var mods: [String] = []
            if existing.modifiers.contains(.command) { mods.append("Meta") }
            if existing.modifiers.contains(.control) { mods.append("Control") }
            if existing.modifiers.contains(.option)  { mods.append("Alt") }
            if existing.modifiers.contains(.shift)   { mods.append("Shift") }
            if existing.key?.rawValue == candidateKeyCode,
               Set(mods) == Set(candidate.modifiers) {
                return "Conflicts with \(name.rawValue)"
            }
        }
        return nil
    }
}
```

- [ ] **Step 2: Add extension shortcuts to the Shortcuts section**

In `shortcutsSection` (around line 312), add after the voice input row (before the closing `}`/`.padding(24)`):

```swift
Divider()
    .padding(.vertical, 4)

sectionHeader("Extension Shortcuts", description: "Keyboard shortcuts for the Chrome Extension.")

HStack(spacing: 6) {
    Circle()
        .fill(webSocketService.isClientConnected ? Color.green : Color.primary.opacity(0.25))
        .frame(width: 6, height: 6)
    Text(webSocketService.isClientConnected ? "Extension connected" : "Extension not connected")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
}

settingsRow("Grab Element") {
    ExtensionShortcutRecorder(shortcut: $settings.extensionGrabElementShortcut)
}
settingsRow("Select Region") {
    ExtensionShortcutRecorder(shortcut: $settings.extensionRegionSelectShortcut)
}

Button("Reset to Defaults") {
    settings.extensionGrabElementShortcut = .defaultGrabElement
    settings.extensionRegionSelectShortcut = .defaultRegionSelect
}
.font(.system(size: 11))
.foregroundStyle(.secondary)
.buttonStyle(.plain)
```

- [ ] **Step 3: Add shortcuts section to Chrome Extension tab**

In the Chrome Extension section (around line 624-715), add a shortcuts subsection between the `Divider()` at line 687 and the "Captured Metadata" `VStack` at line 689. Insert a new `Divider()` after the shortcuts subsection to separate it from the metadata toggles:

```swift
// Extension Shortcuts subsection
VStack(alignment: .leading, spacing: Self.itemSpacing) {
    sectionHeader("Shortcuts", description: "Configure keyboard shortcuts for element capture.")

    settingsRow("Grab Element") {
        ExtensionShortcutRecorder(shortcut: $settings.extensionGrabElementShortcut)
    }
    settingsRow("Select Region") {
        ExtensionShortcutRecorder(shortcut: $settings.extensionRegionSelectShortcut)
    }

    Button("Reset to Defaults") {
        settings.extensionGrabElementShortcut = .defaultGrabElement
        settings.extensionRegionSelectShortcut = .defaultRegionSelect
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
    .buttonStyle(.plain)
}
```

- [ ] **Step 4: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Relaunch and verify UI**

Run:
```bash
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

Verify:
- Open Preferences → Shortcuts tab: "Extension Shortcuts" section visible with Grab Element and Select Region recorders showing "⌥⇧G" and "⌥⇧R"
- Open Preferences → Chrome Extension tab: "Shortcuts" section visible with same recorders
- Click a recorder, press a key combo (e.g., ⌥⇧X) → updates in both tabs
- "Reset to Defaults" restores ⌥⇧G and ⌥⇧R

- [ ] **Step 6: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add extension shortcut recorders to Shortcuts and Chrome Extension settings"
```

---

## Chunk 4: Chrome Extension — Keyboard Handling

### Task 5: Content Script Keyboard Listeners

**Files:**
- Modify: `extension/content.js`

- [ ] **Step 1: Add shortcut config state and defaults**

At the top of the IIFE (after variable declarations, around line 5), add:
```javascript
// Shortcut configuration — loaded from chrome.storage.local, synced from app
let shortcutConfig = {
    "grab-element": { key: "G", modifiers: ["Alt", "Shift"] },
    "region-select": { key: "R", modifiers: ["Alt", "Shift"] },
};
```

- [ ] **Step 2: Load shortcuts from chrome.storage.local on injection**

After the config declaration, add:
```javascript
// Load saved shortcuts (async, non-blocking — defaults are already set above)
chrome.storage.local.get("shortcuts", (result) => {
    if (result.shortcuts) {
        shortcutConfig = result.shortcuts;
    }
});
```

- [ ] **Step 3: Add the keydown listener**

Before the `connect()` function, add:
```javascript
// Keyboard shortcut listener — capture phase, registered at document_start
document.addEventListener("keydown", (event) => {
    // Skip if typing in form fields
    const tag = event.target.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA" || event.target.isContentEditable) {
        return;
    }

    for (const [command, config] of Object.entries(shortcutConfig)) {
        const keyMatch = event.key.toUpperCase() === config.key.toUpperCase();
        const altMatch = event.altKey === config.modifiers.includes("Alt");
        const shiftMatch = event.shiftKey === config.modifiers.includes("Shift");
        const ctrlMatch = event.ctrlKey === config.modifiers.includes("Control");
        const metaMatch = event.metaKey === config.modifiers.includes("Meta");

        if (keyMatch && altMatch && shiftMatch && ctrlMatch && metaMatch) {
            event.preventDefault();
            event.stopPropagation();

            if (command === "grab-element") {
                enterGrabMode();
            } else if (command === "region-select") {
                enterRegionSelectMode();
            }
            return;
        }
    }
}, true); // capture phase
```

- [ ] **Step 4: Handle shortcutConfig WebSocket message**

In the `ws.onmessage` handler (around line 46-55), add an `else if` branch after the existing `regionQuery` check. Do NOT replace the entire handler — only add the new branch:

```javascript
// Add this else-if branch inside the existing ws.onmessage try block,
// after: if (msg.type === "regionQuery") { handleRegionQuery(msg.data); }
else if (msg.type === "shortcutConfig") {
    shortcutConfig = msg.data;
    chrome.storage.local.set({ shortcuts: msg.data });
}
```

- [ ] **Step 5: Listen for chrome.storage.onChanged (cross-tab sync)**

After the `chrome.storage.local.get` call from step 2, add:
```javascript
// Cross-tab sync: when another tab updates shortcuts via WebSocket, pick it up
chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.shortcuts?.newValue) {
        shortcutConfig = changes.shortcuts.newValue;
    }
});
```

- [ ] **Step 6: Commit**

```bash
git add extension/content.js
git commit -m "feat: add custom keydown listeners for configurable extension shortcuts"
```

---

### Task 6: Manifest and Background Updates

**Files:**
- Modify: `extension/manifest.json`
- Modify: `extension/background.js`

- [ ] **Step 1: Remove suggested_key from manifest commands**

In `manifest.json`, change the commands section (lines 34-49) from:
```json
"commands": {
    "grab-element": {
        "suggested_key": {
            "default": "Alt+Shift+G",
            "mac": "Alt+Shift+G"
        },
        "description": "Grab web element context"
    },
    "region-select": {
        "suggested_key": {
            "default": "Alt+Shift+R",
            "mac": "Alt+Shift+R"
        },
        "description": "Select region of web elements"
    }
}
```

To:
```json
"commands": {
    "grab-element": {
        "description": "Grab web element context"
    },
    "region-select": {
        "description": "Select region of web elements"
    }
}
```

- [ ] **Step 2: Verify background.js command relay**

Inspect `background.js` lines 8-13 — the `chrome.commands.onCommand` handler already relays commands to the active tab by name. This continues to work as a fallback if users manually assign shortcuts in `chrome://extensions/shortcuts`. No changes needed.

- [ ] **Step 3: Commit**

```bash
git add extension/manifest.json
git commit -m "feat: remove default suggested_key from manifest commands (now app-configured)"
```

---

### Task 7: Popup Dynamic Shortcut Labels

**Files:**
- Modify: `extension/popup.html`
- Modify: `extension/popup.js`

- [ ] **Step 1: Remove hardcoded labels from popup.html**

Change lines 34 and 39 from hardcoded values to empty spans with IDs:

```html
<button class="action-btn" id="grabBtn" disabled>
    <span class="btn-icon">⌖</span>
    <span class="btn-label">Grab Element</span>
    <span class="btn-shortcut" id="grabShortcut"></span>
</button>
<button class="action-btn" id="regionBtn" disabled>
    <span class="btn-icon">⬚</span>
    <span class="btn-label">Select Region</span>
    <span class="btn-shortcut" id="regionShortcut"></span>
</button>
```

- [ ] **Step 2: Add shortcut label rendering to popup.js**

Add a helper function and call it on popup load:
```javascript
function formatShortcut(config) {
    const symbolMap = { Meta: "\u2318", Control: "\u2303", Alt: "\u2325", Shift: "\u21E7" };
    const order = ["Control", "Alt", "Shift", "Meta"];
    const symbols = order
        .filter((m) => config.modifiers.includes(m))
        .map((m) => symbolMap[m])
        .join("");
    return symbols + config.key.toUpperCase();
}

function updateShortcutLabels() {
    const defaults = {
        "grab-element": { key: "G", modifiers: ["Alt", "Shift"] },
        "region-select": { key: "R", modifiers: ["Alt", "Shift"] },
    };

    chrome.storage.local.get("shortcuts", (result) => {
        const shortcuts = result.shortcuts || defaults;
        document.getElementById("grabShortcut").textContent = formatShortcut(
            shortcuts["grab-element"] || defaults["grab-element"]
        );
        document.getElementById("regionShortcut").textContent = formatShortcut(
            shortcuts["region-select"] || defaults["region-select"]
        );
    });
}
```

Call `updateShortcutLabels()` inside the IIFE, right after the element query declarations (around line 13, after `const statusPill = ...`). There is no `DOMContentLoaded` handler — the script runs inside an IIFE at the end of the body and executes immediately.

- [ ] **Step 3: Commit**

```bash
git add extension/popup.html extension/popup.js
git commit -m "feat: render extension shortcut labels dynamically from chrome.storage.local"
```

---

## Chunk 5: Integration Testing

### Task 8: End-to-End Verification

- [ ] **Step 1: Build and relaunch the app**

Run:
```bash
cd app && xcodebuild clean build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Then:
```bash
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

- [ ] **Step 2: Reload the Chrome extension**

Navigate to `chrome://extensions/`, find Remarc, click the reload button.

- [ ] **Step 3: Verify default shortcut sync**

1. Open Remarc Preferences → Chrome Extension tab
2. Verify connection status shows "Extension connected" (green dot)
3. Verify "Shortcuts" section shows "⌥⇧G" for Grab Element and "⌥⇧R" for Select Region
4. Open the Chrome extension popup → verify the same shortcut labels appear

- [ ] **Step 4: Verify shortcut change propagation**

1. In Remarc Preferences → Shortcuts tab → Extension Shortcuts section
2. Click the Grab Element recorder, press ⌥⇧X
3. Verify it updates to "⌥⇧X" in both Shortcuts and Chrome Extension tabs
4. Open Chrome extension popup → verify label shows "⌥⇧X"
5. Navigate to any web page in Chrome, press ⌥⇧X → grab mode activates
6. Press ⌥⇧G → nothing happens (old shortcut no longer active)

- [ ] **Step 5: Verify input field suppression**

1. Navigate to a page with a text input
2. Focus the input field
3. Press ⌥⇧G → no grab mode, normal typing behavior

- [ ] **Step 6: Verify cross-tab sync**

1. Open two Chrome tabs on different web pages
2. Change a shortcut in Remarc settings
3. Verify the new shortcut works on both tabs without reloading

- [ ] **Step 7: Verify persistence across restart**

1. Quit Remarc
2. Relaunch Remarc
3. Verify shortcuts in settings still show the custom values
4. Verify Chrome extension still responds to custom shortcuts

- [ ] **Step 8: Verify reset to defaults**

1. Click "Reset to Defaults" in either settings section
2. Verify both recorders revert to "⌥⇧G" and "⌥⇧R"
3. Verify Chrome extension popup updates
4. Verify shortcuts work on web pages

- [ ] **Step 9: Final commit (if any fixes were needed)**

Stage only the specific files that were modified during fixes, then commit:
```bash
git add <specific-files-that-were-fixed>
git commit -m "fix: address integration test findings"
```
