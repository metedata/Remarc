# Configurable Shortcut Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the disabled hardcoded Cmd+Shift+C hotkey with a user-configurable global shortcut using the KeyboardShortcuts library.

**Architecture:** Add sindresorhus/KeyboardShortcuts as an SPM dependency. Define a `.commentOnSelection` shortcut name with Cmd+Shift+C as default. Rewrite GlobalHotkey to use `KeyboardShortcuts.onKeyDown`. Add a Recorder widget to the General tab in Preferences.

**Tech Stack:** Swift 6.0, KeyboardShortcuts (SPM), SwiftUI, AppKit

---

### Task 1: Add KeyboardShortcuts SPM dependency

**Files:**
- Modify: `app/RemarcPackage/Package.swift`

**Step 1: Add the package dependency and target dependency**

In `Package.swift`, add to the `dependencies` array:

```swift
.package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0")
```

And add to the `RemarcFeature` target's `dependencies` array:

```swift
.product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
```

**Step 2: Resolve packages**

Run: `cd app && xcodebuild -resolvePackageDependencies -workspace Remarc.xcworkspace -scheme Remarc`
Expected: Resolves successfully, KeyboardShortcuts downloaded.

**Step 3: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add app/RemarcPackage/Package.swift
git commit -m "feat: add KeyboardShortcuts SPM dependency"
```

---

### Task 2: Define the shortcut name and rewrite GlobalHotkey

**Files:**
- Rewrite: `app/RemarcPackage/Sources/RemarcFeature/Utilities/GlobalHotkey.swift`

**Step 1: Rewrite GlobalHotkey.swift**

Replace the entire file with:

```swift
import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let commentOnSelection = Self(
        "commentOnSelection",
        initial: .init(.c, modifiers: [.command, .shift])
    )
}

@MainActor
public final class GlobalHotkey {
    public static let shared = GlobalHotkey()

    private init() {}

    /// Register the configurable global hotkey for comment-on-selection
    public func register() {
        KeyboardShortcuts.onKeyDown(for: .commentOnSelection) { [weak self] in
            Task { @MainActor in
                self?.handleHotkey()
            }
        }
        debugLog("GlobalHotkey: Registered (KeyboardShortcuts)")
    }

    public func unregister() {
        KeyboardShortcuts.disable(.commentOnSelection)
        debugLog("GlobalHotkey: Unregistered")
    }

    private func handleHotkey() {
        guard !SettingsManager.shared.isPaused else { return }

        if let selection = SelectionMonitor.shared.readCurrentSelection() {
            CommentInputController.shared.showForSelection(selection)
        } else {
            CommentInputController.shared.showStandaloneNote()
        }
    }
}
```

**Step 2: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/GlobalHotkey.swift
git commit -m "feat: rewrite GlobalHotkey to use KeyboardShortcuts library"
```

---

### Task 3: Re-enable GlobalHotkey in AppController

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift:56-58`

**Step 1: Uncomment the hotkey registration**

Replace lines 56-58:

```swift
        // Global hotkey (Cmd+Shift+C) disabled — conflicts with Figma shortcuts
        // GlobalHotkey.shared.register()
        // debugLog("GlobalHotkey registered")
```

With:

```swift
        GlobalHotkey.shared.register()
        debugLog("GlobalHotkey registered")
```

**Step 2: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/AppController.swift
git commit -m "feat: re-enable global hotkey registration (now configurable)"
```

---

### Task 4: Add shortcut recorder to Preferences General tab

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Add KeyboardShortcuts import**

Add at the top of the file, after the existing imports:

```swift
import KeyboardShortcuts
```

**Step 2: Add the Recorder to the General tab**

In the `generalTab` computed property, add a `KeyboardShortcuts.Recorder` row after the "Pause selection detection" toggle and before the "Detection mode" picker. The updated `generalTab`:

```swift
    private var generalTab: some View {
        Form {
            Toggle("Launch at Login", isOn: Binding(
                get: { settings.launchAtLogin },
                set: { settings.launchAtLogin = $0 }
            ))
            Toggle("Pause selection detection", isOn: $settings.isPaused)
            KeyboardShortcuts.Recorder("Comment shortcut:", name: .commentOnSelection)
            Picker("Detection mode", selection: $settings.selectionDetectionMode) {
                ForEach(SettingsManager.SelectionDetectionMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            Toggle("Clean up terminal whitespace", isOn: $settings.normalizeWhitespace)
        }
    }
```

**Step 3: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add configurable shortcut recorder to Preferences"
```

---

### Task 5: Manual verification

**Step 1: Kill existing Remarc and launch fresh build**

```bash
pkill -x Remarc || true
# Extract DerivedData path from build output
BUILD_DIR=$(xcodebuild build -workspace app/Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | grep -oE '/Users/[^ ]*DerivedData/Remarc-[^/]+' | head -1)
open "$BUILD_DIR/Build/Products/Debug/Remarc.app"
```

**Step 2: Verify default shortcut works**

1. Select text in any app (e.g. TextEdit, browser)
2. Press Cmd+Shift+C
3. Expected: Comment input panel appears with the selected text as reference
4. Press Cmd+Shift+C with no selection
5. Expected: Quick note panel appears

**Step 3: Verify Settings recorder**

1. Right-click Remarc menu bar icon → Preferences
2. Go to General tab
3. Expected: "Comment shortcut:" row showing ⌘⇧C
4. Click the recorder, press a new combo (e.g. ⌃⇧N)
5. Expected: Recorder updates, old shortcut stops working, new one works immediately

**Step 4: Verify no Figma conflict**

1. Open Figma
2. Press Cmd+Shift+C in Figma
3. Expected: Remarc comment input opens; Figma does NOT receive the keystroke (Carbon hotkey consumes it)
