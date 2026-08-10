# Design: smart compact timestamps on comment cards

Status: APPROVED v4 (incorporates Codex adversarial review, Remarc session "timestamp" feedback, and final consolidation of settings placement)
Date: 2026-05-14

## Problem

`CommentCardView.metadataText` (app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift:190-196) builds a metadata string like:

```
Google Chrome - May 13, 2026 at 3:45 PM
```

via `comment.createdAt.formatted(date: .abbreviated, time: .shortened)`, then renders it in `metadataView` with `.lineLimit(1)`. The string is too long for the card width, so it truncates to `Google Chrome - May 13, 2026 at...` in the non-hovered state. In the hovered state it is worse: the `shortID` chip and 4 action buttons appear in the same `HStack`, stealing more horizontal space.

## Goal

Replace the verbose `CommentCardView` timestamp with a compact, two-tier format that fits the card. This is a DISPLAY-ONLY change for the card. Copy / export / MCP paths keep the full, detailed timestamp.

## Scope

In scope: `CommentCardView` only.

Out of scope:
- `CommentEditorView` -- the floating editor has more space, so it keeps the full timestamp. (Per Remarc comment 00d4e.)
- `ExportManager` / MCP -- clipboard, file export, and MCP previews stay full and detailed.
- `HistoryCardView` -- shows `deletedAt` with a "Deleted " prefix, different semantics, not reported.
- `TranscriptionHistoryView` -- already uses `.relative`, and operates on transcriptions not comments.

## Timestamp policy (two tiers, card only)

Decided relative to an injected `now`:

- `createdAt` is less than 24h before `now`: time of day, formatted per the `timeFormat` setting -- `15:45` (24-hour) or `3:45 PM` (12-hour).
- `createdAt` is 24h+ old: date, formatted per the `exportDateFormat` setting (`short` / `medium` / `long` / `iso` / `european`).

The 24h+ tier reuses the existing `exportDateFormat` setting rather than a hardcoded `MM/dd`. (Per Remarc comment 3758a, interpreted as: make the display date format configurable and surface it in settings, paralleling the `timeFormat` decision.)

This supersedes v2's hardcoded `MM/dd` / `MM/dd/yy` tiering. Codex's adversarial review flagged that a yearless `MM/dd` makes prior-year comments ambiguous; with a user-chosen `exportDateFormat` the year-bearing formats (`medium`, `long`, `iso`, `european`) are available, the choice is explicit, and the `.help()` tooltip below is a full-precision backstop regardless of the chosen format.

## Approach

### 1. Shared date-formatting helper (testable, `now` injected)

Add a `Date` extension in `app/RemarcPackage/Sources/RemarcFeature/Utilities/Constants.swift` (alongside the existing `appDisplayName` free function):

```swift
extension Date {
    /// Compact timestamp for CommentCardView display. Display only -- exports/MCP keep full dates.
    /// `now` is injected so the value is deterministic for tests and so a periodic
    /// refresh can re-evaluate the tier as time passes.
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
            // 24h+ tier: reuse the existing exportDateFormat formatting rather
            // than duplicating its format strings.
            return ExportManager.shared.formatDate(self, format: dateFormat)
        }
    }
}
```

Notes:
- `now` is an injected parameter (defaulted) so the time-tier decision is deterministic for tests and so the periodic refresh below can drive it. (Codex adversarial review: testability.)
- The 24h+ tier delegates to `ExportManager.formatDate` so the date format strings live in exactly one place. If calling `ExportManager.shared` from this helper proves awkward under Swift 6 isolation (it is `@MainActor`-bound), the implementation plan may instead lift the canonical format strings onto `ExportDateFormat` as a small shared method -- a minor DRY refactor of code already being touched. Either way the helper stays unit-testable with an injected `now`.
- The `<24h` time formatter uses `en_US_POSIX` so `HH:mm` / `h:mm a` are deterministic across system locales and across CI.

### 2. Periodic refresh so the tier does not go stale

The tier boundary (24h since creation) is evaluated against `now`. A card left visible could otherwise cross the boundary and keep showing the time tier until some unrelated state change re-renders it -- the comment list is a persistent `ScrollView` of cards. (Codex adversarial review.)

Fix: in `CommentCardView`, wrap the timestamp `Text` in a `TimelineView` and feed `context.date` into the helper as `now`:

```swift
TimelineView(.periodic(from: .now, by: timestampRefreshInterval)) { context in
    Text(metadataText(now: context.date))
        // ... existing modifiers
}
```

- `TimelineView` + `TimelineSchedule.periodic(from:by:)` are available macOS 12.0+ (project targets 14.4+). Verified against Apple docs.
- SwiftUI coalesces and may reduce the frequency of these updates when the system is inactive (`TimelineScheduleMode`). Worst case is a re-render of a single `Text` on the interval -- negligible.
- `timestampRefreshInterval` is a named constant (proposed: 60s), easy to tune.

### 3. Full-timestamp backstop (hover tooltip)

The compact format intentionally drops precision. Add to the timestamp `Text` in `CommentCardView`:

- `.help(comment.createdAt.formatted(date: .abbreviated, time: .shortened))` -- hover tooltip with the full, locale-aware date and time. On-pattern with the app's other tooltips (SwiftUI `.help()`).

A separate `.accessibilityLabel()` was considered but dropped: the Remarc feedback (comment 88cb1) was "simple `.help` is fine", and the `exportDateFormat` outputs (`May 13`, `May 13, 2026`, `2026-05-13`, etc.) read acceptably to VoiceOver, unlike the v2 bare `MM/dd`.

### 4. Reuse the existing `timeFormat` and `exportDateFormat` settings

Both `SettingsManager.TimeFormat` (`.twelve` / `.twentyFour`, with `use24Hour: Bool`) and `SettingsManager.ExportDateFormat` (`short` / `medium` / `long` / `iso` / `european`) already exist and currently drive `ExportManager` formatting only. Display format is inherently a global preference, so the card reads the same two settings rather than introducing new ones.

### 5. Move the "Time format" and "Date format" pickers to General settings

Today both pickers live only in Preferences -> Export tab -> Clipboard Format section: `exportDateFormat` ("Date format", PreferencesWindowController.swift:1181, always shown) and `timeFormat` ("Time format", :1183, gated behind `if settings.includeTime`). Now that both also drive card display, they are global preferences, not export-only.

Move both `pickerRow`s to the General tab -> App section (after "Tooltip position", around PreferencesWindowController.swift:312) and remove them from the Export tab. One picker per setting, one location -- no duplication across tabs. (Per user direction: "no separate time format settings, just one".)

The `includeTime` toggle stays in the Export tab; it controls whether time is included in exports at all, which is separate from the 12h/24h format choice. The `timeFormat` picker, formerly gated behind `includeTime`, is ungated in its new General location since it now also governs card display.

### 6. Apply the helper at the one display site

- `CommentCardView.swift` -- `metadataText` becomes `metadataText(now:)`; add `@ObservedObject private var settings = SettingsManager.shared` (matches the existing `persistence` reference); wrap the timestamp `Text` in `TimelineView`; add `.help()`.
- While editing this line: replace the em dash in `"\(app) — \(date)"` with a hyphen, per the project copy-style rule (no em dashes).

## Files touched

1. `Utilities/Constants.swift` -- new `Date.remarcCompactTimestamp(dateFormat:use24Hour:now:)` extension.
2. `Views/CommentCardView.swift` -- `TimelineView` wrap, `metadataText(now:)`, `settings` reference, `.help()`, em dash -> hyphen.
3. `Views/PreferencesWindowController.swift` -- move the "Time format" + "Date format" pickers from the Export tab to General -> App (ungated). The `includeTime` toggle stays in the Export tab.
4. `Tests/RemarcFeatureTests/CompactTimestampTests.swift` -- NEW. Auto-discovered by the existing `RemarcFeatureTests` target (uses `exclude:`, not an explicit source list), so no Package.swift change. Covers: <24h in 12h and 24h modes, exactly-24h boundary, just-over-24h with a representative `exportDateFormat`, and a boundary-crossing case (same `createdAt`, two different `now` values).

(`CommentEditorView.swift` was in v2 scope but is removed per Remarc comment 00d4e.)

## Resolved by adversarial review

- Stale tier while a card stays open -> periodic `TimelineView` refresh (Approach 2).
- Yearless `MM/dd` ambiguity -> superseded; the 24h+ tier now uses the configurable `exportDateFormat`, whose year-bearing options plus the `.help()` backstop remove the hidden ambiguity (Timestamp policy, Approach 3).
- Testability -> `now` is an injected parameter; dedicated unit test file (Approach 1, Files 4).
- Lost precision -> `.help()` tooltip backstop (Approach 3).

## Resolved by Remarc session "timestamp" feedback

- 88cb1 -> `.help()` hover tooltip kept; `.accessibilityLabel()` dropped ("simple `.help` is fine").
- 3758a -> 24h+ tier reuses `exportDateFormat`; "Date format" picker added to General settings.
- 00d4e -> `CommentEditorView` removed from scope; it keeps the full timestamp.
- e16c1 -> superseded by later user direction: rather than both tabs, the pickers move to General only (one location per setting, no duplication).

## Status notes

Approved by the user on 2026-05-14.

- Comment 3758a interpretation confirmed: the 24h+ tier reuses the existing `exportDateFormat` setting, surfaced as a picker in General settings.
- `.help()` tooltip on the card timestamp confirmed.
- Settings placement consolidated: one picker per setting, in General only (no duplication across tabs).

Ready for implementation planning.
