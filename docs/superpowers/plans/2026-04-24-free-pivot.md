# Free Pivot Implementation Plan

> **For agentic workers:** Execute task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all paid-licensing and Sentry telemetry code so Remarc ships as a free, no-telemetry, no-phone-home macOS app suitable for open-source launch.

**Architecture:** Mechanical deletion of `LicenseManager`, `LicenseEntryWindowController`, `SentryService`, related models + constants + callers. Replace Sentry error capture with existing `debugLog`. No new abstractions.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Sparkle (kept). Drops: `sentry-cocoa` package, Lemon Squeezy HTTP endpoints.

---

## Phase A: Remove Sentry telemetry

### A1: Remove Sentry from Package.swift

**Files:**
- Modify: `app/RemarcPackage/Package.swift`

- [ ] Delete the `sentry-cocoa` line from `dependencies` array.
- [ ] Delete the `.product(name: "Sentry", package: "sentry-cocoa")` line from target dependencies.

### A2: Remove Sentry from app entry point

**Files:**
- Modify: `app/Remarc/RemarcApp.swift`

- [ ] Delete `import Sentry` (line 4).
- [ ] Delete the entire `SentrySDK.start { options in ... }` block (starting line 24, ~10 lines).

### A3: Delete SentryService wrapper

**Files:**
- Delete: `app/RemarcPackage/Sources/RemarcFeature/Services/SentryService.swift`

- [ ] `git rm` the file.

### A4: Replace SentryService calls in services

Each of these files calls `SentryService.capture(error, ...)` or `SentryService.captureMessage(...)`. Replace with `debugLog("...: \(error)")` or delete entirely if a `debugLog` already exists at the same site.

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ParakeetEngine.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/WhisperKitEngine.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/VoiceInputService.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/WebSocketService.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/DictationService.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ClaudeCodeManager.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ScreenCaptureService.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/FeedbackInputController.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift` (remove `SentryService.setUserContext` on line 32)

- [ ] For each file: remove `import Sentry` if present. Replace each `SentryService.capture(error, tags: [...], context: [...])` with `debugLog("error: \(error)")` (or delete if there's already an adjacent `debugLog` covering the same info). Replace `SentryService.captureMessage("X", tags: ...)` with `debugLog("X")`. Delete `SentryService.setUserContext(...)` and `SentryService.addBreadcrumb(...)` calls entirely.

### A5: Verify build compiles without Sentry

- [ ] Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -30`
- [ ] Expected: BUILD SUCCEEDED. If errors: missing SentryService reference somewhere — grep `SentryService\|SentrySDK\|import Sentry` and clean.

### A6: Commit phase A

- [ ] `git add -A && git commit -m "refactor(free-pivot): remove Sentry telemetry, replace error capture with debugLog"`

---

## Phase B: Remove License Manager + Lemon Squeezy

### B1: Delete licensing source files

**Files:**
- Delete: `app/RemarcPackage/Sources/RemarcFeature/Services/LicenseManager.swift`
- Delete: `app/RemarcPackage/Sources/RemarcFeature/Models/LicenseModels.swift`
- Delete: `app/RemarcPackage/Sources/RemarcFeature/Views/LicenseEntryWindowController.swift`

- [ ] `git rm` all three.

### B2: Remove Lemon Squeezy constants

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift`

- [ ] Delete the `// Lemon Squeezy` comment (line 115) and `public static let checkoutURL = "..."` (line 116). Also remove any adjacent Lemon Squeezy-specific constants (store ID, product ID, etc.) if present.

### B3: Update AppController.swift

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/AppController.swift`

- [ ] Line 29-30: Delete `LicenseManager.shared.setup()` and `debugLog("LicenseManager initialized")`.
- [ ] Line 32: Already deleted in A4 (SentryService.setUserContext).
- [ ] Line 58: Delete the `if LicenseManager.shared.licenseState == .licensed { ... }` gate. Keep the inner logic unconditionally (user now always has full access).
- [ ] Line 485: Delete `LicenseManager.shared.openCheckout()` and the surrounding menu item that triggered it (likely a "Buy" or "Upgrade" menu entry). Remove the whole menu item construction block.

### B4: Update SelectionTooltipView.swift

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/SelectionTooltipView.swift`

- [ ] Line 11: Delete the `if LicenseManager.shared.canComment() { ... }` guard. Keep the inner body unconditionally.

### B5: Update CommentInputWindowController.swift

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`

- [ ] Line 304: Delete `LicenseManager.shared.recordComment()`.
- [ ] Line 495: Delete `LicenseManager.shared.recordComment()`.
- [ ] Line 1109: Delete `LicenseManager.shared.openCheckout()` and the surrounding trial-exhausted / upgrade-prompt UI (likely a button or view). Keep comment-submit path clean without any upgrade prompts.

### B6: Update FloatingEditorController.swift

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/FloatingEditorController.swift`

- [ ] Line 77: Delete `LicenseManager.shared.recordComment()`.

### B7: Update PreferencesWindowController.swift

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

- [ ] Identify and delete the entire "License" tab / section. Line 1804 (`LicenseManager.shared.openCheckout()`) and line 2003 (`switch LicenseManager.shared.licenseState { ... }`) bracket the licensing UI. Read lines 1750-2050, identify the tab container / section, and delete the whole region including any tab registration/enum case for "License".
- [ ] Line 1960: Delete `LicenseManager.shared.resetForTesting()` call (likely a debug button).
- [ ] If the preferences tab enum has a `.license` case, remove it and remove any switch-exhaustiveness break.

### B8: Verify build compiles

- [ ] Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData" 2>&1 | tail -30`
- [ ] Expected: BUILD SUCCEEDED. If errors: grep remaining `LicenseManager\|LemonSqueezy\|checkoutURL\|LicenseError\|LicenseState\|canComment\|recordComment\|openCheckout\|resetForTesting` across the codebase and clean.

### B9: Commit phase B

- [ ] `git add -A && git commit -m "refactor(free-pivot): remove LicenseManager + Lemon Squeezy integration, app is now unconditionally free"`

---

## Phase C: Verify runtime + smoke test

### C1: Launch the app

- [ ] Run: `pkill -x Remarc 2>/dev/null; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`
- [ ] Expected: menu bar icon appears, no crash, no upgrade prompt on launch.

### C2: Smoke test core flow

- [ ] Select text in any app. Confirm comment tooltip appears (was gated by `canComment()`, now unconditional).
- [ ] Open comment input, write a comment, save. Confirm comment is recorded.
- [ ] Open Preferences. Confirm: no "License" tab, no "Buy" / "Upgrade" / "Activate License" buttons visible anywhere.
- [ ] Check menu bar menu. Confirm: no "Upgrade" / "Buy Remarc" menu entries.

### C3: Final commit if any follow-up fixes

- [ ] If smoke test surfaces any leftover license UI not caught by grep, fix and commit with `fix(free-pivot): remove remaining <thing>`.

### C4: Summary

- [ ] Run: `git log --oneline main..HEAD`
- [ ] Report to user: files deleted, callers updated, build passing, smoke test passing.

---

## Scope explicitly out

- Website copy update (separate concern, `website/` dir will be handled post-launch)
- Keychain migration for existing users (their stored license keys will just sit unused)
- Changelog entry (added during OSS prep phase)
- Any server-side Supabase changes (no license validation ran server-side anyway)

---

## Self-review

- [x] All 6 LicenseManager caller files covered (AppController, SelectionTooltipView, CommentInputWindowController, FloatingEditorController, PreferencesWindowController, plus LicenseEntryWindowController which is deleted)
- [x] All Sentry-using files covered (10 service/view files + AppController + RemarcApp)
- [x] Package.swift updates cover both `dependencies` and target `dependencies`
- [x] Build verification after both Phase A and Phase B
- [x] Runtime verification in Phase C
- [x] No placeholder steps
