# Auto-Save Voice Notes Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in setting that automatically saves voice-invoked comments after a 2-second fill animation on the Save button, with cancellation on any interaction.

**Architecture:** New `autoSaveVoiceNotes` setting in SettingsManager, `isVoiceInvoked` flag + countdown timer in CommentInputController, fill/shake animations in VoiceAwareSaveButton. Escape interception in KeyablePanel.

**Tech Stack:** SwiftUI, AppKit (NSPanel, NSEvent monitors), Swift concurrency (Task), KeyboardShortcuts

---

## Chunk 1: Setting + Invocation Tracking

### Task 1: Add `autoSaveVoiceNotes` setting to SettingsManager

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift`

- [ ] **Step 1: Add UserDefaults key**

In the `Keys` enum (after `hasSeenCritModeOnboarding`), add:

```swift
static let autoSaveVoiceNotes = "autoSaveVoiceNotes"
```

- [ ] **Step 2: Add published property**

After the `hasSeenCritModeOnboarding` property (line ~148), add:

```swift
@Published public var autoSaveVoiceNotes: Bool {
    didSet { defaults.set(autoSaveVoiceNotes, forKey: Keys.autoSaveVoiceNotes) }
}
```

- [ ] **Step 3: Initialize in init()**

After `self.hasSeenCritModeOnboarding = ...` (line ~336), add:

```swift
self.autoSaveVoiceNotes = defaults.bool(forKey: Keys.autoSaveVoiceNotes)
```

- [ ] **Step 4: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift
git commit -m "feat: add autoSaveVoiceNotes setting to SettingsManager"
```

### Task 2: Add toggle to Preferences → Shortcuts section

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

- [ ] **Step 1: Add toggle below Voice Input row**

In `shortcutsSection` (line ~325), inside the existing `if #available(macOS 26, *)` block, after the Voice Input `settingsRow`, add:

```swift
VStack(alignment: .leading, spacing: 3) {
    toggleRow("Auto-save voice notes", isOn: $settings.autoSaveVoiceNotes)
    Text("Automatically saves comments created with the voice shortcut. Does not apply to comments invoked manually.")
        .font(.system(size: 11))
        .foregroundStyle(.primary.opacity(0.35))
        .fixedSize(horizontal: false, vertical: true)
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add auto-save voice notes toggle to Shortcuts preferences"
```

### Task 3: Add `isVoiceInvoked` flag to CommentInputController

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`

- [ ] **Step 1: Add published property**

After the `@Published public var targetSessionID: UUID?` line (~26), add:

```swift
@Published public var isVoiceInvoked: Bool = false
```

- [ ] **Step 2: Reset to false in all show methods**

Add `isVoiceInvoked = false` at the top of each show method body:

In `showForSelection(_:)` — after `SelectionTooltipWindowController.shared.dismiss()` (line ~60):
```swift
isVoiceInvoked = false
```

In `showStandaloneNote()` — after `SelectionTooltipWindowController.shared.dismiss()` (line ~86):
```swift
isVoiceInvoked = false
```

In `showForScreenshot(imagePath:captureRect:)` — after `SelectionTooltipWindowController.shared.dismiss()` (line ~99):
```swift
isVoiceInvoked = false
```

In `showForWebElement(_:)` — after the debugLog line (~116):
```swift
isVoiceInvoked = false
```

- [ ] **Step 3: Reset to false in dismiss()**

In `dismiss()`, after `panel?.orderOut(nil)` (line ~474), add:

```swift
isVoiceInvoked = false
```

- [ ] **Step 4: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift
git commit -m "feat: add isVoiceInvoked flag to CommentInputController"
```

### Task 4: Set `isVoiceInvoked = true` in GlobalHotkey

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/GlobalHotkey.swift`

- [ ] **Step 1: Set flag after show methods in handleVoiceInputKeyDown**

In `handleVoiceInputKeyDown()`, after the block that opens the comment panel (lines ~182-188), add:

```swift
CommentInputController.shared.isVoiceInvoked = true
```

This must come AFTER the `showForSelection()`/`showStandaloneNote()` calls (which reset it to false).

The block should look like:
```swift
// Open comment panel if not already visible
if !CommentInputController.shared.isVisible {
    if let selection = SelectionMonitor.shared.readCurrentSelection() {
        CommentInputController.shared.showForSelection(selection)
    } else {
        CommentInputController.shared.showStandaloneNote()
    }
}
CommentInputController.shared.isVoiceInvoked = true
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/GlobalHotkey.swift
git commit -m "feat: set isVoiceInvoked flag in voice hotkey handler"
```

## Chunk 2: Auto-Save Timer + Cancellation Logic

### Task 5: Add auto-save timer to CommentInputController

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`

- [ ] **Step 1: Add published properties for countdown state**

After `@Published public var isVoiceInvoked: Bool = false`, add:

```swift
@Published public var autoSaveCountdownActive: Bool = false
@Published public var autoSaveProgress: Double = 0
@Published public var shakeAutoSave: Bool = false
private var autoSaveTask: Task<Void, Never>?
private var autoSaveClickMonitor: Any?
private var autoSaveStartTime: Date?
```

- [ ] **Step 2: Add startAutoSaveCountdown method**

After the `appendVoiceText(_:)` method (~line 112), add:

```swift
public func startAutoSaveCountdown() {
    guard isVoiceInvoked,
          SettingsManager.shared.autoSaveVoiceNotes,
          !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }

    cancelAutoSaveCountdown()
    autoSaveCountdownActive = true
    autoSaveProgress = 0
    autoSaveStartTime = Date()

    // Install click monitor to cancel on any click in the panel
    autoSaveClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        self?.cancelAutoSave()
        return event
    }

    let duration: TimeInterval = 2.0
    let steps = 120 // ~60fps for 2 seconds
    let interval = duration / Double(steps)

    autoSaveTask = Task { [weak self] in
        for i in 1...steps {
            try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.autoSaveProgress = Double(i) / Double(steps)
            }
        }
        guard !Task.isCancelled else { return }
        await MainActor.run {
            self?.performAutoSave()
        }
    }

    debugLog("CommentInputController: Auto-save countdown started (2s)")
}

private func performAutoSave() {
    guard autoSaveCountdownActive else { return }
    cleanupAutoSaveState()
    saveComment(text: currentText, attachments: currentAttachments)
    debugLog("CommentInputController: Auto-saved voice comment")
}

public func cancelAutoSave() {
    guard autoSaveCountdownActive else { return }
    cleanupAutoSaveState()
    shakeAutoSave = true
    // Reset shake after animation completes
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.shakeAutoSave = false
    }
    debugLog("CommentInputController: Auto-save cancelled")
}

/// Remaining seconds in the countdown (for reduce-motion text label).
public var autoSaveRemainingSeconds: Int {
    guard autoSaveCountdownActive, let start = autoSaveStartTime else { return 0 }
    let elapsed = Date().timeIntervalSince(start)
    return max(0, Int(ceil(2.0 - elapsed)))
}

public func cancelAutoSaveCountdown() {
    autoSaveTask?.cancel()
    autoSaveTask = nil
    cleanupAutoSaveState()
}

private func cleanupAutoSaveState() {
    autoSaveTask?.cancel()
    autoSaveTask = nil
    autoSaveCountdownActive = false
    autoSaveProgress = 0
    autoSaveStartTime = nil
    if let monitor = autoSaveClickMonitor {
        NSEvent.removeMonitor(monitor)
        autoSaveClickMonitor = nil
    }
}
```

- [ ] **Step 3: Cancel countdown on dismiss**

In `dismiss()`, before `panel?.orderOut(nil)`, add:

```swift
cancelAutoSaveCountdown()
```

- [ ] **Step 4: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift
git commit -m "feat: add auto-save countdown timer with click cancellation"
```

### Task 6: Wire Escape key to cancel auto-save instead of dismiss

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`

- [ ] **Step 1: Update KeyablePanel.cancelOperation**

Replace the existing `cancelOperation` override:

```swift
override func cancelOperation(_ sender: Any?) {
    if CommentInputController.shared.autoSaveCountdownActive {
        CommentInputController.shared.cancelAutoSave()
    } else {
        CommentInputController.shared.dismiss()
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift
git commit -m "feat: escape cancels auto-save countdown instead of dismissing"
```

## Chunk 3: UI — Fill Animation + Shake + Trigger

### Task 7: Add fill animation and shake to VoiceAwareSaveButton

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/VoiceInputViews.swift`

- [ ] **Step 1: Add controller observation and shake state**

In `VoiceAwareSaveButton`, add an `@ObservedObject` for the controller:

```swift
@ObservedObject private var controller = CommentInputController.shared
```

- [ ] **Step 2: Add shake offset modifier**

Add a computed property for shake offset:

```swift
private var shakeOffset: CGFloat {
    controller.shakeAutoSave ? 3 : 0
}
```

- [ ] **Step 3: Modify the idle-state Save button to show fill overlay**

Replace the idle-state button (the `if voiceInput.state == .idle` branch) with:

```swift
if voiceInput.state == .idle {
    Button(action: {
        if controller.autoSaveCountdownActive {
            controller.cancelAutoSave()
        } else {
            onSave()
        }
    }) {
        HStack(spacing: 6) {
            if controller.autoSaveCountdownActive && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                Text("Saving... \(controller.autoSaveRemainingSeconds)s")
                    .font(.system(size: 12, weight: .medium))
            } else {
                Text("Save")
                    .font(.system(size: 12, weight: .medium))
                Text("⌘↵")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12)
        .frame(minWidth: buttonMinWidth, minHeight: buttonHeight)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.15))
        )
        .background(
            GeometryReader { geo in
                Color.remarcBrandGradient(for: colorScheme)
                    .frame(width: geo.size.width * controller.autoSaveProgress)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        )
        .background(
            Color.remarcBrandGradient(for: colorScheme).opacity(
                controller.autoSaveCountdownActive ? 0.3 : 1.0
            ),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .opacity(isSaveHovered || controller.autoSaveCountdownActive ? 1.0 : 0.85)
    }
    .buttonStyle(.plain)
    .onHover { hovering in isSaveHovered = hovering }
    .animation(.easeInOut(duration: 0.15), value: isSaveHovered)
    .offset(x: shakeOffset)
    .animation(
        controller.shakeAutoSave
            ? .spring(response: 0.1, dampingFraction: 0.3).repeatCount(3, autoreverses: true)
            : .default,
        value: controller.shakeAutoSave
    )
    .accessibilityIdentifier("remarc.commentInput.submitButton")
    .zIndex(1)
    .transition(.blurReplace)
}
```

- [ ] **Step 4: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/VoiceInputViews.swift
git commit -m "feat: add fill animation and shake to VoiceAwareSaveButton"
```

### Task 8: Trigger auto-save countdown from CommentInputView + typing cancellation

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputView.swift`

- [ ] **Step 1: Add onChange for pendingVoiceText to trigger countdown**

In the existing `.onChange(of: controller.pendingVoiceText)` block (line ~131), after `controller.pendingVoiceText = nil`, add the countdown trigger:

```swift
.onChange(of: controller.pendingVoiceText) {
    if let text = controller.pendingVoiceText, !text.isEmpty {
        appendTranscribedText(text)
        controller.pendingVoiceText = nil
        // Start auto-save countdown after voice transcription completes
        if #available(macOS 26, *), VoiceInputService.shared.state == .idle {
            controller.startAutoSaveCountdown()
        }
    }
}
```

- [ ] **Step 2: Add typing cancellation**

In the existing `.onChange(of: commentText)` block (line ~125), add:

```swift
.onChange(of: commentText) {
    controller.currentText = commentText
    // Cancel auto-save if user types during countdown
    if controller.autoSaveCountdownActive {
        controller.cancelAutoSave()
    }
}
```

- [ ] **Step 3: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Relaunch and manually test**

```bash
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

Test:
1. Open Settings → Shortcuts, verify toggle appears below Voice Input
2. Enable auto-save toggle
3. Use voice shortcut (Cmd+Shift+V), dictate, release — verify 2s fill animation on Save button
4. Test Escape cancels (shake, panel stays open)
5. Test clicking during fill cancels
6. Test typing during fill cancels
7. Let it complete — verify comment saves with genie animation
8. Disable toggle — verify voice comments behave as before (no auto-save)
9. Use manual shortcut (Cmd+Shift+C) with toggle on — verify no auto-save

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputView.swift
git commit -m "feat: trigger auto-save countdown on voice transcription completion"
```

### Task 9: Handle edge case — new recording restarts countdown

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/GlobalHotkey.swift`

- [ ] **Step 1: Cancel countdown when voice hotkey is pressed**

In `handleVoiceInputKeyDown()`, after the paused guard (line ~163) and before the recording state check, add:

```swift
// Cancel any active auto-save countdown (new recording supersedes)
CommentInputController.shared.cancelAutoSaveCountdown()
```

This is the right place because: SwiftUI's `.onChange` can't observe a computed property backed by a non-observed object (`VoiceInputService` is not `@ObservedObject` in `CommentInputView`). Instead, we cancel at the source — `handleVoiceInputKeyDown()` is always called when a new voice recording starts via the hotkey. The countdown silently cancels (no shake) since `cancelAutoSaveCountdown()` doesn't set `shakeAutoSave`.

- [ ] **Step 2: Build to verify**

Run:
```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/GlobalHotkey.swift
git commit -m "feat: cancel auto-save countdown when new voice recording starts"
```

### Task 10: Final relaunch and verification

- [ ] **Step 1: Clean build and relaunch**

```bash
cd app && xcodebuild clean -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -3
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5
pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app
```

Full test matrix:
1. **Setting off (default)**: Voice shortcut → no auto-save, normal manual flow
2. **Setting on + voice shortcut**: Dictate → transcription appears → 2s fill → auto-saves
3. **Cancel with Escape**: Fill stops, shake, panel stays open, can edit and save manually
4. **Cancel with click**: Click anywhere during fill → cancels with shake
5. **Cancel with typing**: Type during fill → cancels with shake
6. **Empty transcription**: No auto-save, panel stays in manual mode
7. **Manual shortcut with setting on**: Cmd+Shift+C → no auto-save (isVoiceInvoked is false)
8. **Multiple recordings**: Second recording cancels first countdown, new countdown starts after second transcription
9. **Reduce motion**: Fill replaced with "Saving..." text label
