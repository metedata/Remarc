# Auto-Clear After Export — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an "Always clear after copying" checkbox to the clear prompt, and a 3-second countdown bar that auto-clears when the setting is on.

**Architecture:** New `autoClearAfterExport` bool in SettingsManager persisted via UserDefaults. PopoverContentView gets two new views: an expanded two-row clearPrompt with checkbox, and an autoClearCountdown bar with progress fill + undo. The footer slot branches between three states: footer, clearPrompt, or autoClearCountdown.

**Tech Stack:** SwiftUI, UserDefaults, SettingsManager singleton

---

### Task 1: Add `autoClearAfterExport` to SettingsManager

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift`

**Step 1: Add the key**

In the `Keys` enum (line 11–25), add after `deleteResolvedComments`:

```swift
static let autoClearAfterExport = "autoClearAfterExport"
```

**Step 2: Add the published property**

After the `deleteResolvedComments` property (line 67–69), add:

```swift
@Published public var autoClearAfterExport: Bool {
    didSet { defaults.set(autoClearAfterExport, forKey: Keys.autoClearAfterExport) }
}
```

**Step 3: Initialize in `init()`**

After `self.deleteResolvedComments = defaults.bool(forKey: Keys.deleteResolvedComments)` (line 125), add:

```swift
self.autoClearAfterExport = defaults.bool(forKey: Keys.autoClearAfterExport)
```

**Step 4: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```
feat: add autoClearAfterExport setting to SettingsManager
```

---

### Task 2: Expand clearPrompt with checkbox row

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`

**Step 1: Add SettingsManager observation**

At the top of PopoverContentView (near line 16, with other @ObservedObject), add:

```swift
@ObservedObject private var settings = SettingsManager.shared
```

**Step 2: Replace the clearPrompt view**

Replace the current `clearPrompt` computed property (the `HStack` with "Clear exported comments?" + Keep/Clear buttons) with a `VStack` containing two rows:

```swift
private var clearPrompt: some View {
    VStack(spacing: 6) {
        HStack {
            Text("Clear exported comments?")
                .font(.system(size: 11))
            Spacer()
            ConfirmationButton(label: "Keep", role: .cancel) {
                showClearPrompt = false
            }
            ConfirmationButton(label: "Clear", role: .destructive) {
                if let sessionID = persistence.appState.activeSessionID {
                    persistence.clearAllComments(in: sessionID)
                }
                showClearPrompt = false
            }
        }
        HStack {
            Button {
                settings.autoClearAfterExport.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: settings.autoClearAfterExport ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11))
                        .foregroundStyle(settings.autoClearAfterExport ? Color.remarcPrimary(for: colorScheme) : .primary.opacity(0.45))
                    Text("Always clear after copying")
                        .font(.system(size: 10))
                        .foregroundStyle(.primary.opacity(0.45))
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
}
```

**Step 3: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet`
Expected: BUILD SUCCEEDED

**Step 4: Kill, relaunch, verify visually**

Trigger Copy All, confirm the two-row prompt appears with the checkbox. Toggle it, confirm it persists across app restarts.

**Step 5: Commit**

```
feat: add "Always clear after copying" checkbox to clear prompt
```

---

### Task 3: Build the auto-clear countdown bar

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`

**Step 1: Add new state variables**

Near the existing `@State private var showClearPrompt` (line 18), add:

```swift
@State private var showAutoClearCountdown = false
@State private var autoClearProgress: CGFloat = 0
@State private var autoClearCancelled = false
@State private var autoClearCommentCount = 0
```

**Step 2: Add the autoClearCountdown view**

Add a new computed property after the `clearPrompt` view:

```swift
// MARK: - Auto-Clear Countdown

private var autoClearCountdown: some View {
    HStack {
        Text("Clearing \(autoClearCommentCount) comment\(autoClearCommentCount == 1 ? "" : "s")...")
            .font(.system(size: 11))
        Spacer()
        Button("Undo") {
            cancelAutoClear()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.remarcPrimary(for: colorScheme))
        .buttonStyle(.plain)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(alignment: .leading) {
        GeometryReader { geo in
            Rectangle()
                .fill(Color.remarcError(for: colorScheme).opacity(0.15))
                .frame(width: geo.size.width * autoClearProgress)
        }
    }
    .onAppear {
        startAutoClear()
    }
}

private func startAutoClear() {
    autoClearCancelled = false
    autoClearProgress = 0
    withAnimation(.linear(duration: 3)) {
        autoClearProgress = 1
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        guard !autoClearCancelled else { return }
        if let sessionID = persistence.appState.activeSessionID {
            persistence.clearAllComments(in: sessionID)
        }
        showAutoClearCountdown = false
        ToastManager.shared.show("Cleared")
    }
}

private func cancelAutoClear() {
    autoClearCancelled = true
    withAnimation(.easeOut(duration: 0.2)) {
        autoClearProgress = 0
    }
    showAutoClearCountdown = false
}
```

**Step 3: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```
feat: add auto-clear countdown bar view
```

---

### Task 4: Wire up the flow — branch on setting, show countdown in body

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`

**Step 1: Update the body to show countdown bar**

In the body (around line 82–89), replace the footer/clearPrompt conditional:

```swift
if hasComments {
    Divider()
    if showAutoClearCountdown {
        autoClearCountdown
    } else if showClearPrompt {
        clearPrompt
    } else {
        footer
    }
}
```

**Step 2: Update `copyAll()` to branch on setting**

Replace `showClearPrompt = true` in `copyAll()` (line 404) with:

```swift
if settings.autoClearAfterExport {
    autoClearCommentCount = allComments.count
    showAutoClearCountdown = true
} else {
    showClearPrompt = true
}
```

**Step 3: Update `exportToFile()` to branch on setting**

Replace `showClearPrompt = true` in `exportToFile()` (line 411) with:

```swift
if settings.autoClearAfterExport {
    autoClearCommentCount = persistence.activeComments.count
    showAutoClearCountdown = true
} else {
    showClearPrompt = true
}
```

**Step 4: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet`
Expected: BUILD SUCCEEDED

**Step 5: Kill, relaunch, full verification**

1. With checkbox unchecked: Copy All → two-row prompt appears → Keep/Clear work
2. Check the checkbox, dismiss, Copy All again → countdown bar appears with "Clearing N comments..."
3. Let countdown finish → comments cleared, toast shown
4. Re-add comments, Copy All → countdown bar → click Undo before it finishes → comments preserved

**Step 6: Commit**

```
feat: wire auto-clear flow — branch on setting, show countdown or prompt
```
