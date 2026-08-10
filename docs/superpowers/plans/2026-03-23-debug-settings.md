# Debug Settings Section Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a debug-only settings section consolidating channel notifications, vocabulary hints editing, and reset actions.

**Architecture:** Add `debug` case to `SettingsSection` enum (unconditionally, filtered from sidebar in release builds via `visibleSections`). Add `vocabularyHints` to `SettingsManager` for persistence. Update `VocabularyHints.swift` to read from settings. Build the debug section view with three subsections.

**Tech Stack:** SwiftUI, AppKit, UserDefaults

**Spec:** `docs/superpowers/specs/2026-03-23-debug-settings-design.md`

**Worktree:** `.worktrees/send-to-claude` (branch already exists with channel notification work)

**Build command:** `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -5`

**Relaunch command:** `pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`

---

### Task 1: Add `vocabularyHints` to SettingsManager

**Files:**
- Modify: `.worktrees/send-to-claude/app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift`

- [ ] **Step 1: Add UserDefaults key**

In the `Keys` enum (after line 77 `claudeCodeChannelEnabled`), add:

```swift
static let vocabularyHints = "vocabularyHints"
```

- [ ] **Step 2: Add published property**

After the `claudeCodeChannelEnabled` property (line 347), add:

```swift
@Published public var vocabularyHints: [String] {
    didSet { defaults.set(vocabularyHints, forKey: Keys.vocabularyHints) }
}
```

- [ ] **Step 3: Initialize in init()**

After `self.claudeCodeChannelEnabled` initialization (line 611), add:

```swift
self.vocabularyHints = defaults.stringArray(forKey: Keys.vocabularyHints) ?? ["Remarc", "Claude Code"]
```

- [ ] **Step 4: Build to verify**

Run build command. Expected: success, no errors.

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift
git commit -m "feat: add vocabularyHints to SettingsManager"
```

---

### Task 2: Update VocabularyHints to read from SettingsManager

**Files:**
- Modify: `.worktrees/send-to-claude/app/RemarcPackage/Sources/RemarcFeature/Services/VocabularyHints.swift`

- [ ] **Step 1: Replace static array with SettingsManager read**

Replace the entire file contents with:

```swift
import Foundation
@preconcurrency import WhisperKit

enum VocabularyHints {
    @MainActor
    static var words: [String] {
        SettingsManager.shared.vocabularyHints
    }

    @MainActor
    static var promptPhrase: String {
        words.joined(separator: ", ")
    }

    @MainActor
    static func whisperPromptTokens(using tokenizer: WhisperTokenizer) -> [Int] {
        tokenizer.encode(text: promptPhrase)
    }
}
```

Note: All properties become computed and `@MainActor`-isolated since `SettingsManager.shared` is `@MainActor`. The call site in `WhisperKitEngine.swift` (line 149) is already in a `@MainActor` context (`WhisperKitModelManager`), so this is safe.

- [ ] **Step 2: Build to verify**

Run build command. Expected: success. If there are actor isolation errors at the call site, the caller is not on `@MainActor` - check `WhisperKitEngine.swift:149`.

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/VocabularyHints.swift
git commit -m "feat: VocabularyHints reads from SettingsManager"
```

---

### Task 3: Add `debug` case to SettingsSection and build debugSection view

**Files:**
- Modify: `.worktrees/send-to-claude/app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

- [ ] **Step 1: Add enum case**

After `case about = "About"` (line 136), add:

```swift
case debug = "Debug"
```

- [ ] **Step 2: Add icon**

In the `icon` computed property switch (before closing `}`), add:

```swift
case .debug: return "ladybug"
```

- [ ] **Step 3: Filter from release builds in visibleSections**

Replace the `visibleSections` computed property (lines 155-161). Use `#available` (not `#unavailable`) to match the existing codebase pattern:

```swift
private var visibleSections: [SettingsSection] {
    SettingsSection.allCases.filter { section in
        if section == .license { return false }
        #if !DEBUG
        if section == .debug { return false }
        #endif
        if #available(macOS 26, *) { return true }
        return section != .voice
    }
}
```

- [ ] **Step 4: Add sidebar label with "Internal" badge**

In the sidebar `ForEach` (around line 168), the existing code has a special case for `.claudeCode`. Add a similar case for `.debug` inside the `ForEach` body. After the `if section == .claudeCode { ... }` block and before the `else` block, add an `else if`:

```swift
} else if section == .debug {
    Label {
        HStack(spacing: 6) {
            Text(section.rawValue)
            Text("Internal")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.orange.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    } icon: {
        Image(systemName: section.icon)
    }
    .font(.system(size: 13))
    .tag(section)
```

- [ ] **Step 5: Add switch case for debug section in detail pane**

In the `switch selectedSection` block (lines 209-222), add before the closing `}`:

```swift
case .debug:
    #if DEBUG
    debugSection
    #else
    EmptyView()
    #endif
```

- [ ] **Step 6: Add state for vocabulary hint input and confirmations**

Near the other `@State` properties at the top of `PreferencesView` (look for existing `@State` declarations), add:

```swift
@State private var newVocabHint: String = ""
@State private var showResetLicenseConfirm = false
@State private var showResetDataConfirm = false
```

- [ ] **Step 7: Create the debugSection computed property**

Add the following after the `aboutSection` computed property (find it with `private var aboutSection`). Wrap in `#if DEBUG`:

**Files:**
- Modify: `.worktrees/send-to-claude/app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

- [ ] **Step 1: Add state for vocabulary hint input**

Near the other `@State` properties at the top of `PreferencesView` (look for existing `@State` declarations), add:

```swift
@State private var newVocabHint: String = ""
@State private var showResetLicenseConfirm = false
@State private var showResetDataConfirm = false
```

- [ ] **Step 2: Create the debugSection computed property**

Add the following after the `aboutSection` computed property (find it with `private var aboutSection`). Wrap in `#if DEBUG`:

```swift
#if DEBUG
private var debugSection: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {

            // --- Channel Notifications ---
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                sectionHeader(
                    "Channel Notifications",
                    description: "Push new comments directly into your Claude Code session as they're created, instead of waiting for the next prompt."
                )

                toggleRow("Enable channel notifications", isOn: $settings.claudeCodeChannelEnabled, disabled: !settings.claudeCodeEnabled)

                if settings.claudeCodeChannelEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To activate, launch Claude Code with:")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.6))

                        Text("claude --dangerously-load-development-channels server:remarc")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.7))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.primary.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                            )

                        Text("Comments you create in Remarc will appear in Claude's conversation immediately. Claude Code must be logged in via claude.ai (not API key).")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            // --- Vocabulary Hints ---
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                sectionHeader(
                    "Vocabulary Hints",
                    description: "Words and phrases that improve speech recognition accuracy. These bias the WhisperKit decoder toward domain-specific terms."
                )

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(settings.vocabularyHints, id: \.self) { hint in
                        HStack {
                            Text(hint)
                                .font(.system(size: 13))
                            Spacer()
                            Button {
                                settings.vocabularyHints.removeAll { $0 == hint }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }

                HStack(spacing: 8) {
                    TextField("Add word or phrase", text: $newVocabHint)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onSubmit { addVocabHint() }

                    Button("Add") { addVocabHint() }
                        .disabled(newVocabHint.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Divider()

            // --- Reset ---
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                sectionHeader(
                    "Reset",
                    description: "Debug reset actions. These are destructive."
                )

                HStack(spacing: 12) {
                    Button("Reset License") {
                        showResetLicenseConfirm = true
                    }
                    .foregroundStyle(.red)
                    .alert("Reset License", isPresented: $showResetLicenseConfirm) {
                        Button("Cancel", role: .cancel) {}
                        Button("Reset", role: .destructive) {
                            LicenseManager.shared.resetForTesting()
                        }
                    } message: {
                        Text("This will reset your license to the free tier.")
                    }

                    Button("Reset Data") {
                        showResetDataConfirm = true
                    }
                    .foregroundStyle(.red)
                    .alert("Reset Data", isPresented: $showResetDataConfirm) {
                        Button("Cancel", role: .cancel) {}
                        Button("Reset", role: .destructive) {
                            resetDataForTesting()
                        }
                    } message: {
                        Text("This will delete all comments and sessions. Restart the app to complete the reset.")
                    }
                }
            }
        }
        .padding(20)
    }
}

private func addVocabHint() {
    let trimmed = newVocabHint.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !settings.vocabularyHints.contains(trimmed) else { return }
    settings.vocabularyHints.append(trimmed)
    newVocabHint = ""
}

private func resetDataForTesting() {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let commentsFile = appSupport.appendingPathComponent("Remarc/comments.json")
    let legacyFile = appSupport.appendingPathComponent("Remarc/data.json")
    try? FileManager.default.removeItem(at: commentsFile)
    try? FileManager.default.removeItem(at: legacyFile)
    debugLog("Data file removed - restart app to reset")
}
#endif
```

- [ ] **Step 8: Build to verify**

Run build command. Expected: success. If `LicenseManager.shared.resetForTesting()` has access issues (it's `#if DEBUG` gated in LicenseManager too), verify it's accessible.

- [ ] **Step 9: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: add Debug settings section with channel, vocab hints, and reset"
```

---

### Task 4: Remove channel notifications from Claude Integration section

**Files:**
- Modify: `.worktrees/send-to-claude/app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

- [ ] **Step 1: Remove the Real-time Notifications block from claudeCodeSection**

In `claudeCodeSection`, remove the entire block from the `Divider` before "Real-time Notifications" through the closing `}` of that subsection (lines 1498-1539). This includes:
- The divider at line 1498-1499
- The "Real-time Notifications" VStack (lines 1501-1539)

Keep the divider and `claudeDesktopSection` that follow (lines 1541-1544).

- [ ] **Step 2: Build to verify**

Run build command. Expected: success.

- [ ] **Step 3: Relaunch and verify**

Run relaunch command. Verify:
- Debug section appears in sidebar with ladybug icon and "Internal" badge
- Channel notifications toggle works in Debug section
- Vocabulary hints can be added/removed
- Reset buttons show confirmation dialogs
- Claude Integration section no longer has the channel notifications block

- [ ] **Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "refactor: move channel notifications from Claude Integration to Debug section"
```

---

### Task 5: Clean up AppController reset methods

**Files:**
- Modify: `.worktrees/send-to-claude/app/RemarcPackage/Sources/RemarcFeature/AppController.swift`

- [ ] **Step 1: Remove duplicate reset methods from AppController**

The `resetLicenseForTesting()` and `resetDataForTesting()` methods (lines 530-543) are now duplicated in the debug section view. Remove them from `AppController` since they were only called from menu items that likely no longer exist, or keep them if they're referenced elsewhere. Check for references first:

Search for `resetLicenseForTesting` and `resetDataForTesting` in the codebase. If only referenced in AppController itself (as `@objc` methods for menu items), they can be removed.

- [ ] **Step 2: Build to verify**

Run build command. Expected: success.

- [ ] **Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/AppController.swift
git commit -m "refactor: remove AppController reset methods (moved to Debug settings)"
```
