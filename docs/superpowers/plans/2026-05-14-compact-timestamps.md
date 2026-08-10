# Compact Timestamps on Comment Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the truncating verbose timestamp on Remarc comment cards with a compact, two-tier format (time of day if recent, date if older) that fits the card.

**Architecture:** A pure, `now`-injectable `Date` extension decides the tier and formats accordingly, reusing the existing `timeFormat` and `exportDateFormat` settings. `CommentCardView` calls it inside a `TimelineView` so the tier stays correct as time passes. The two format pickers move from the Export tab to General settings. Display-only: copy / export / MCP paths are untouched.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing (`import Testing`). macOS 14.4+ target.

**Spec:** `docs/superpowers/specs/2026-05-14-compact-timestamps-design.md` (APPROVED v4)

**Worktree:** This plan executes in the current worktree (`.claude/worktrees/clever-herschel-fb11be`, branch `claude/clever-herschel-fb11be`). All code changes happen here, not on `main`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift` | Shared helpers/constants | Add `Date.remarcCompactTimestamp(...)` extension + `AppConstants.cardTimestampRefreshInterval` |
| `app/RemarcPackage/Tests/RemarcFeatureTests/CompactTimestampTests.swift` | Unit tests for the helper | Create (auto-discovered by the test target) |
| `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift` | The comment card UI | Use the helper inside a `TimelineView`; add `.help()` tooltip |
| `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift` | Preferences window | Move "Date format" + "Time format" pickers from Export tab to General tab |

No `Package.swift` change: `RemarcFeatureTests` uses `exclude:`, not an explicit source list, so new test files are auto-discovered.

---

## Conventions for every build/test step

- **Run unit tests:** `cd app/RemarcPackage && swift test --filter CompactTimestampTests` (first run resolves and builds dependencies; this can take several minutes).
- **Build the app:** `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"` — success is the literal line `** BUILD SUCCEEDED **`.
- **Relaunch the app (MANDATORY after every successful build):** `pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`
- Use exact file paths. Stage only the named files (no `git add -A`).

---

## Task 1: `Date.remarcCompactTimestamp` helper + unit tests

**Files:**
- Create: `app/RemarcPackage/Tests/RemarcFeatureTests/CompactTimestampTests.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift`

The helper is `@MainActor` because its 24h+ branch calls `ExportManager.shared` (a `@MainActor` singleton). `CommentCardView` is already `@MainActor`, so this is free at the call site; the test suite is marked `@MainActor` to match.

- [ ] **Step 1: Write the failing test file**

Create `app/RemarcPackage/Tests/RemarcFeatureTests/CompactTimestampTests.swift`:

```swift
import Testing
import Foundation
@testable import RemarcFeature

@Suite("Compact timestamp formatting")
@MainActor
struct CompactTimestampTests {
    /// Arbitrary fixed reference instant. All cases position `createdAt` relative to this.
    private let now = Date(timeIntervalSince1970: 1_778_800_000)

    @Test("under 24h old, 24-hour mode: a colon time, no date separator, no meridiem")
    func recentTwentyFourHour() {
        let created = now.addingTimeInterval(-60 * 60) // 1h before now
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now)
        #expect(result.contains(":"))
        #expect(!result.contains("-"))            // not the .iso date tier (yyyy-MM-dd)
        #expect(!result.contains("AM") && !result.contains("PM"))
    }

    @Test("under 24h old, 12-hour mode: includes a meridiem")
    func recentTwelveHour() {
        let created = now.addingTimeInterval(-60 * 60)
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: false, now: now)
        #expect(result.contains(":"))
        #expect(result.contains("AM") || result.contains("PM"))
    }

    @Test("exactly 24h old falls into the date tier")
    func exactlyTwentyFourHours() {
        let created = now.addingTimeInterval(-24 * 60 * 60)
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now)
        #expect(result.contains("-"))             // .iso date tier: yyyy-MM-dd
    }

    @Test("just under 24h old stays in the time tier")
    func justUnderTwentyFourHours() {
        let created = now.addingTimeInterval(-(24 * 60 * 60 - 60)) // 23h59m before now
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now)
        #expect(!result.contains("-"))
    }

    @Test("older than 24h is formatted with the supplied exportDateFormat")
    func olderUsesDateFormat() {
        let created = now.addingTimeInterval(-48 * 60 * 60) // 2 days before now
        let result = created.remarcCompactTimestamp(dateFormat: .iso, use24Hour: true, now: now)
        // .iso produces yyyy-MM-dd: exactly two dashes, only digits and dashes.
        #expect(result.filter { $0 == "-" }.count == 2)
        #expect(result.allSatisfy { $0.isNumber || $0 == "-" })
    }

    @Test("the tier flips as `now` crosses the 24h boundary for a fixed createdAt")
    func boundaryCrossing() {
        let created = now
        let before = created.remarcCompactTimestamp(
            dateFormat: .iso, use24Hour: true, now: created.addingTimeInterval(23 * 60 * 60))
        let after = created.remarcCompactTimestamp(
            dateFormat: .iso, use24Hour: true, now: created.addingTimeInterval(25 * 60 * 60))
        #expect(!before.contains("-"))            // time tier
        #expect(after.contains("-"))              // date tier
        #expect(before != after)
    }
}
```

These assertions are timezone-independent on purpose: they check which *tier* was selected and the *shape* of the output (the bug-prone logic), not exact wall-clock strings, which would depend on the test machine's timezone.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd app/RemarcPackage && swift test --filter CompactTimestampTests`
Expected: compile failure - `value of type 'Date' has no member 'remarcCompactTimestamp'`.

- [ ] **Step 3: Add the `cardTimestampRefreshInterval` constant**

In `app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift`, find the `// Comment` section inside `enum AppConstants` (currently lines 79-81):

```swift
    // Comment
    public static let maxReferenceTextLength: Int = 80
    public static let maxActiveSessions: Int = 8
```

Replace it with:

```swift
    // Comment
    public static let maxReferenceTextLength: Int = 80
    public static let maxActiveSessions: Int = 8

    /// How often CommentCardView re-evaluates its relative timestamp tier
    /// (so a card left open updates when a comment crosses the 24h boundary).
    public static let cardTimestampRefreshInterval: TimeInterval = 60
```

- [ ] **Step 4: Implement the helper**

In the same file, append this extension at the end of the file (after the closing `}` of `enum AppConstants`):

```swift

// MARK: - Compact Timestamp (display only)

extension Date {
    /// Compact timestamp for `CommentCardView` display. Display only; copy / export /
    /// MCP paths keep the full timestamp.
    ///
    /// - Less than 24h before `now`: time of day (`15:45` or `3:45 PM`).
    /// - 24h or older: the date, formatted with `dateFormat`.
    ///
    /// `now` is injected so the tier decision is deterministic in tests and so a
    /// periodic refresh can re-evaluate it as time passes.
    @MainActor
    func remarcCompactTimestamp(
        dateFormat: SettingsManager.ExportDateFormat,
        use24Hour: Bool,
        now: Date = Date()
    ) -> String {
        if now.timeIntervalSince(self) < 24 * 60 * 60 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
            return formatter.string(from: self)
        } else {
            return ExportManager.shared.formatDate(self, format: dateFormat)
        }
    }
}
```

`SettingsManager` and `ExportManager` are in the same module (`RemarcFeature`), so no new `import` is needed.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd app/RemarcPackage && swift test --filter CompactTimestampTests`
Expected: PASS - 6 tests in suite "Compact timestamp formatting", 0 failures.

- [ ] **Step 6: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift \
        app/RemarcPackage/Tests/RemarcFeatureTests/CompactTimestampTests.swift \
        docs/superpowers/specs/2026-05-14-compact-timestamps-design.md \
        docs/superpowers/plans/2026-05-14-compact-timestamps.md
git commit -m "$(cat <<'EOF'
feat(timestamps): add Date.remarcCompactTimestamp helper

Two-tier compact timestamp for comment cards: time of day under 24h,
date (via exportDateFormat) when older. now is injected for testability.
Includes the design spec and implementation plan.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Use the helper in `CommentCardView`

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift`

This task has no unit test - it is SwiftUI view wiring. Verification is a successful build plus a visual check of the running app.

- [ ] **Step 1: Add a `settings` reference to the view**

In `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift`, find (around line 22):

```swift
    @ObservedObject private var persistence = PersistenceManager.shared
    @State private var isHovered: Bool = false
```

Replace with:

```swift
    @ObservedObject private var persistence = PersistenceManager.shared
    @ObservedObject private var settings = SettingsManager.shared
    @State private var isHovered: Bool = false
```

- [ ] **Step 2: Convert `metadataText` to a `now`-parameterised function**

Find the `metadataText` computed property (around lines 190-196):

```swift
    private var metadataText: String {
        let date = comment.createdAt.formatted(date: .abbreviated, time: .shortened)
        if let app = appDisplayName(for: comment) {
            return "\(app) — \(date)"
        }
        return date
    }
```

Replace with:

```swift
    private func metadataText(now: Date) -> String {
        let date = comment.createdAt.remarcCompactTimestamp(
            dateFormat: settings.exportDateFormat,
            use24Hour: settings.timeFormat.use24Hour,
            now: now
        )
        if let app = appDisplayName(for: comment) {
            return "\(app) - \(date)"
        }
        return date
    }
```

Note the em dash (`—`) in the original string literal is replaced with a hyphen (`-`), per the project copy-style rule.

- [ ] **Step 3: Wrap the timestamp `Text` in a `TimelineView` and add the tooltip**

Find the start of `metadataView` (around lines 198-204):

```swift
    private var metadataView: some View {
        HStack(spacing: 4) {
            Text(metadataText)
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.45))
                .lineLimit(1)

            Text(comment.shortID)
```

Replace that opening portion with:

```swift
    private var metadataView: some View {
        HStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: AppConstants.cardTimestampRefreshInterval)) { context in
                Text(metadataText(now: context.date))
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.45))
                    .lineLimit(1)
                    .help(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            Text(comment.shortID)
```

Leave the rest of `metadataView` (the `shortID` chip, `Spacer`, `cardActions`) unchanged.

- [ ] **Step 4: Build**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"`
Expected: `** BUILD SUCCEEDED **`. If it fails, read the `error:` lines and fix before continuing.

- [ ] **Step 5: Relaunch and visually verify**

Run: `pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`

Then open the menu bar popover and confirm:
- A recent comment's metadata line reads like `AppName - 3:45 PM` (or `15:45` in 24-hour mode) and is **not** truncated in the non-hovered state.
- A comment older than 24h shows a date instead of a time.
- Hovering the timestamp shows a `.help()` tooltip with the full date and time (e.g. `May 13, 2026 at 3:45 PM`).
- The hovered state (ID chip + action buttons visible) still lays out cleanly.

If you cannot exercise the running UI, say so explicitly rather than claiming success.

- [ ] **Step 6: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift
git commit -m "$(cat <<'EOF'
feat(timestamps): use compact timestamp on comment cards

CommentCardView renders createdAt via remarcCompactTimestamp inside a
TimelineView so the time/date tier refreshes as the comment ages. Full
timestamp remains available on hover via .help().

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Move the format pickers to General settings

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

The `timeFormat` and `exportDateFormat` settings now drive card display, so their pickers belong in General settings rather than buried in the Export tab. The underlying settings are unchanged - this only moves the UI controls. The `includeTime` toggle stays in the Export tab (it governs whether time appears in exports at all, a separate concern).

- [ ] **Step 1: Remove the two pickers from the Export tab**

In `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`, find this block in `exportSection` (around lines 1180-1185):

```swift
                    pickerRow("Metadata divider", selection: $settings.metadataDividerStyle, highlight: .metadataDivider) { $0.label }
                    pickerRow("Date format", selection: $settings.exportDateFormat, highlight: .dateFormat) { $0.label }
                    if settings.includeTime {
                        pickerRow("Time format", selection: $settings.timeFormat, highlight: .dateFormat) { $0.label }
                    }
                }
```

Replace it with (drop the "Date format" and "Time format" rows; "Metadata divider" becomes the last picker in that section):

```swift
                    pickerRow("Metadata divider", selection: $settings.metadataDividerStyle, highlight: .metadataDivider) { $0.label }
                }
```

- [ ] **Step 2: Add the two pickers to the General tab's App section**

In the same file, find the end of the App section in `generalSection` (around lines 312-313):

```swift
                    pickerRow("Tooltip position", selection: $settings.tooltipPosition) { $0.label }
                }
```

Replace it with:

```swift
                    pickerRow("Tooltip position", selection: $settings.tooltipPosition) { $0.label }
                    pickerRow("Date format", selection: $settings.exportDateFormat) { $0.label }
                    pickerRow("Time format", selection: $settings.timeFormat) { $0.label }
                }
```

These General-tab rows omit the `highlight:` argument (there is no export preview to highlight in this tab), matching the other `pickerRow` calls in `generalSection`.

- [ ] **Step 3: Build**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Relaunch and visually verify**

Run: `pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`

Open Preferences and confirm:
- **General tab → App section:** "Date format" and "Time format" pickers appear after "Tooltip position".
- **Export tab → Clipboard Format section:** "Date format" and "Time format" pickers are gone; "Metadata divider" is the last picker. The "Include time" toggle is still present in the "Include in Export" section.
- Changing "Time format" in General re-renders a recent comment card's time between 12-hour and 24-hour.

- [ ] **Step 5: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "$(cat <<'EOF'
feat(timestamps): move time/date format pickers to General settings

timeFormat and exportDateFormat now drive card display, so their pickers
move from Export to General. Underlying settings unchanged; the Export
"Include time" toggle stays put.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Final integration verification

No code changes. Confirm the whole feature works end to end and nothing regressed.

- [ ] **Step 1: Clean build from the current worktree state**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$(pwd)/DerivedData"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run the unit test suite**

Run: `cd app/RemarcPackage && swift test --filter CompactTimestampTests`
Expected: PASS - 6 tests, 0 failures.

- [ ] **Step 3: Relaunch and run the full visual checklist**

Run: `pkill -x Remarc; sleep 0.5; open app/DerivedData/Build/Products/Debug/Remarc.app`

Confirm all of:
- Comment card timestamps are compact and not truncated, in both light and dark mode.
- A `< 24h` comment shows time of day; a `>= 24h` comment shows a date.
- Hover tooltip shows the full date/time; hovered card layout (ID chip + actions) is clean.
- Preferences: "Date format" + "Time format" pickers are in General → App, and absent from the Export tab.
- Copy a comment to the clipboard (card copy button) and confirm the **exported** text still contains the full, detailed date - the compact format is display-only and must not have leaked into exports.

If any check fails, treat it as a bug, return to the relevant task, and fix before declaring done.

---

## Self-Review (completed by plan author)

**Spec coverage:**
- Timestamp policy (two tiers, `<24h` time / `>=24h` date via `exportDateFormat`) → Task 1 helper + tests.
- Periodic refresh (`TimelineView`) → Task 2 Step 3.
- `.help()` tooltip backstop → Task 2 Step 3.
- Reuse `timeFormat` / `exportDateFormat`; no new settings → Task 1 helper signature; Task 2 Step 2.
- Move both pickers to General, remove from Export, `includeTime` stays → Task 3.
- Em dash → hyphen on the touched line → Task 2 Step 2.
- `CommentEditorView` out of scope → not touched by any task (correct).
- New test file auto-discovered, no `Package.swift` change → Task 1 Step 1 + File Structure note.

**Placeholder scan:** none - every code step contains complete code; every command has expected output.

**Type consistency:** `remarcCompactTimestamp(dateFormat:use24Hour:now:)` is defined in Task 1 Step 4 and called with exactly those argument labels in Task 1 Step 1 (tests) and Task 2 Step 2. `AppConstants.cardTimestampRefreshInterval` defined in Task 1 Step 3, used in Task 2 Step 3. `metadataText(now:)` defined and called consistently within Task 2.
