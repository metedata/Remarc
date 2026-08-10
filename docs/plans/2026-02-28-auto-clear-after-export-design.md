# Auto-Clear After Export

## Problem

After Copy All / Export, the user is always prompted "Clear exported comments?" with Keep/Clear buttons. Power users who always clear want to skip this step.

## Design

### Manual Mode (default — `autoClearAfterExport = false`)

Two-row prompt replaces the footer after copy/export:

```
┌─────────────────────────────────────────┐
│ Clear exported comments?    [Keep][Clear]│
│ ☐ Always clear after copying            │
└─────────────────────────────────────────┘
```

- Row 1: question + `ConfirmationButton` (Keep=cancel, Clear=destructive)
- Row 2: checkbox in 10pt, `primary.opacity(0.45)` — toggles `autoClearAfterExport` in SettingsManager
- Checking the box persists immediately; current Keep/Clear action still applies

### Auto Mode (`autoClearAfterExport = true`)

Timed countdown bar replaces the footer — no prompt shown:

```
┌──────────────────────────────────────────────┐
│ Clearing 5 comments...  ████░░░░░░    [Undo] │
└──────────────────────────────────────────────┘
```

- Progress fill: `remarcError` at ~0.15 opacity, animates left-to-right over 3 seconds (`linear(duration: 3)`)
- Label: "Clearing N comments..." in 11pt
- Undo button: right-aligned, `remarcPrimary` text — cancels timer, restores footer
- On completion: clears all comments, shows toast "Cleared", restores footer
- Timer: `DispatchQueue.main.asyncAfter(deadline: .now() + 3)` with cancellation flag

### Flow

```
copyAll() / exportToFile()
  → if autoClearAfterExport:
      showAutoClearCountdown = true   // countdown bar
  → else:
      showClearPrompt = true          // manual prompt with checkbox
```

## Changes

### SettingsManager.swift
- New key `autoClearAfterExport` (Bool, default false)
- New `@Published` property

### PopoverContentView.swift
- `clearPrompt`: add second row with checkbox bound to `settings.autoClearAfterExport`
- New `autoClearCountdown` view: progress bar + "Clearing N comments..." + Undo button
- New state: `@State showAutoClearCountdown`, cancellation flag
- `copyAll()` / `exportToFile()`: branch on `autoClearAfterExport`
- Body: show countdown bar when `showAutoClearCountdown` is true (same slot as clearPrompt/footer)
