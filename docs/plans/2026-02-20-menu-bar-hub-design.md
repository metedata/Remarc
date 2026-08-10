# Menu Bar Hub Redesign

Date: 2026-02-20

## Problem

Remarc has too many UI surfaces for managing comments: floating pill, expanded mini-viewer, full viewer, and menu bar dropdown. That's four management surfaces for a tool whose primary use case is capture & export (select text, comment, eventually copy all to clipboard). The interaction model should be radically simpler.

## Decision

Replace all comment management surfaces with a single **menu bar popover**. The only floating element is the tooltip for capturing comments near text selections. Everything else lives in the menu bar.

## Surfaces

### What exists after this redesign

| Surface | Purpose | Trigger |
|---|---|---|
| Tooltip | Capture — appears near text selection | Auto on text select (0.5s delay) |
| Comment Input | Write comment — floating near selection or centered for quick note | Click tooltip / Cmd+Shift+C |
| Menu Bar Popover | Review, manage, export all comments | Left-click menu bar icon |
| Floating Editor | Edit comment or create quick note from popover | Edit action on card / note icon in header |
| Detached Window | Persistent, pinnable version of popover content | Right-click → "Detach Comments Window" |
| Preferences Window | Settings (export format, excluded apps, license, launch at login) | Gear icon / right-click → Preferences |

### What gets removed

- Corner Widget (collapsed pill + expanded mini-viewer) — `CornerWidgetWindowController`, `CornerWidgetView`
- Full Viewer — `ViewerWindowController`, `ViewerView`
- NSMenu-based status bar dropdown — replaced by popover
- "Stacks" concept — flattened to single continuous list

## Menu Bar Icon

SF Symbol (`text.bubble` or similar) followed by a **filled circular badge** with the comment count in a brand color (muted blue or teal).

**States:**
- 0 comments: icon only, no badge
- 1+ comments: icon + colored badge with count
- Paused: icon grayed out, badge still shows count if comments exist

**Badge semantics:** Total count (inventory model). Always shows how many comments exist. Never resets except by deleting or clearing comments.

**Left-click:** Opens popover. If detached window exists, brings it to front instead.
**Right-click:** Utility menu:
- Copy All
- New Quick Note
- Detach Comments Window / Re-attach (toggles)
- Pause / Resume
- Preferences...
- Quit Remarc

## Menu Bar Popover

**Dimensions:** ~380pt wide. Max height ~50% of screen height, then scrolls.

### Header

- Left: "Comments" title (system semibold, secondary style)
- Right: icon buttons — note (quick note), search, sort, gear
- **Search and sort icons hidden when 0 comments**

### Card List

Scrollable area containing comment cards. Newest-first by default. Sort icon toggles ordering.

New comments inserted in real-time with animation when the popover is open.

### Sticky Footer

Always visible when 1+ comments exist. Three buttons:
- **Copy All** — copies all comments as Markdown (format configurable in Preferences). Shows toast "Copied to clipboard."
- **Delete All** — confirmation popover: "Delete all N comments?" with Cancel/Delete + "Don't ask again" checkbox. Undo toast after deletion.
- **Export to File...** — save dialog for Markdown/JSON export.

After Copy All or Export, inline prompt replaces the footer: "Clear exported comments?" with Clear / Keep buttons.

### Empty State

When 0 comments:
- Centered illustration (SF Symbol composition) + "Select text and click Comment to get started"
- Header shows only: title + note icon + gear (no search, no sort)
- No sticky footer

## Comment Card

Each card is a rounded rectangle with shadow on the popover's background surface.

### Layout (top to bottom)

1. **Reference container** — subtle inset background. Shows the selected text, truncated at 2 lines with ellipsis. Quick notes show a "Quick Note" label instead. Architecturally, this is a `ReferenceView` that switches on a `CommentReference` enum (see Future section).

2. **Comment text** — primary text below reference. Truncated at 4 lines. If longer, a subtle chevron at the bottom. Clicking expands to full text with smooth animation. Chevron rotates up when expanded.

3. **Metadata line** — tertiary text: app name + date/time. Example: "Safari — Feb 20, 2:34 PM"

### Actions (hover/focus reveal)

Three icon buttons appear in the top-right corner of the card on hover or keyboard focus: **copy**, **edit**, **delete**.

- Arrow keys navigate between cards. Focused card reveals actions. Tab cycles between action buttons.
- Right-click on any card opens context menu with same actions.

**Copy:** Copies comment to clipboard. Toast: "Copied to clipboard" (fades after 1.5s).

**Edit:** Opens floating editor panel on top of dimmed popover.

**Delete:** Small popover anchored to delete icon — "Delete this comment?" with Cancel / Delete + "Don't ask again" checkbox. After deletion, toast: "Deleted. Undo" with 5-second countdown.

## Search Mode

Clicking the search icon **replaces the entire header row** with a search field + close (X) button. Field gets immediate focus.

- Cards filter in real-time (matches reference text, comment text, app name)
- Clearing field or clicking X restores normal header
- No matches: centered "No matching comments" text
- Sort order preserved during search

## Floating Editor Panel

Used for **editing existing comments** and **creating quick notes** from within the popover.

**Dimensions:** ~440pt wide (wider than the popover). Floats on top with its own shadow and material background. Not attached to popover — positioned adjacent, like Calendar's "New Event" panel.

**When open:**
- Popover receives semi-transparent dark overlay (dimmed, non-interactive)
- Click on dimmed area does nothing (or subtle bounce to indicate blocked)
- Editor has full focus

**Contents:**
- If editing: reference text (read-only) + editable comment text, pre-filled
- If quick note: no reference section, just text editor
- Save button (or Enter) + close/cancel (X or Escape)
- **Same SwiftUI view component** as the comment input near selections, hosted differently

**Dismissal:**
- Save: saves, closes editor, removes overlay, popover becomes interactive
- Cancel/Escape/X: discards unsaved changes, closes editor, restores popover

## Tooltip & Comment Input (Capture Flow)

### Tooltip

Restyled to match the new design language (consistent shadow, border, typography with the card aesthetic). Still frosted-glass pill, refined. Appears near text selections after 0.5s delay.

### Comment Input Panel

Standalone floating NSPanel near the text selection. Uses the **same SwiftUI view component** as the floating editor (Section above), just hosted in its own panel positioned near the selection.

For quick notes via Cmd+Shift+C with no selection: opens centered on screen.

### Save Animation

Comment input shrinks with macOS window-dismiss feel (scale down + fade). Menu bar badge simultaneously pulses and increments count. No long travel animation — the connection is implied by synchronized timing.

## Detached Window

**Trigger:** Right-click menu bar icon → "Detach Comments Window."

**Appearance:** Standard NSWindow with traffic lights. Contains the exact same content view as the popover (header, card list, footer). Pin icon in title bar toggles always-on-top.

**Behavior:**
- Mutually exclusive with popover. While detached, left-clicking menu bar icon brings window to front (or hides if already frontmost).
- Right-click shows "Re-attach" instead of "Detach" — closes window, restores popover behavior.
- Window close (traffic light X) also re-attaches.
- Reusable content view hosted in NSWindow instead of popover panel.

**Pin:** Toggles `.canJoinAllSpaces` + floating window level. Pinned = visible on all spaces, always on top.

## Preferences Window

Standard macOS Preferences window. Opened via gear icon or right-click → Preferences.

**Tabs:**
- General: launch at login, pause/resume
- Export: default format (Markdown/JSON)
- Excluded Apps: app exclude list
- License: activation, status, upgrade

## Comment Lifecycle

- Comments accumulate indefinitely in a single flat list
- No stacks, no sessions, no auto-archive
- After Copy All or Export: inline prompt "Clear exported comments?" with Clear / Keep
- Comments persist until user explicitly deletes or clears
- Delete All follows same confirmation pattern as single delete

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| Cmd+Shift+C | New comment (with selection) or quick note (without) |
| Cmd+Shift+V | Open/toggle menu bar popover (or bring detached window to front) |

## Architecture: Future Screenshot Support

**Not in MVP.** The following architectural decisions in MVP accommodate image-based comments later.

### Data Model

Comment references use an enum rather than a raw string:

```
CommentReference
  ├── .textSelection(text: String, appName: String, bundleID: String)
  └── .screenshot(imageID: UUID, appName: String, bundleID: String)  // future
```

MVP implements only `.textSelection`. Adding `.screenshot` requires no data migration.

### Storage

Directory structure instead of a single flat file:

```
~/Library/Application Support/Remarc/
  ├── comments.json          // comment metadata + references
  └── images/                // future: screenshot files by UUID
      ├── <uuid>.png
      └── ...
```

MVP creates this structure. The `images/` directory stays empty until screenshot support ships.

### Card View

The reference container is a `ReferenceView` that switches on the `CommentReference` enum — text rendering for `.textSelection`, image thumbnail for `.screenshot`. MVP only implements the text path.

### Capture

Screenshot capture is a separate mechanism (global shortcut for region capture, drag-and-drop onto menu bar icon). Additive to the tooltip flow, no architectural hook needed in MVP beyond the data model.

### Export

Markdown export with images (inline base64 or file references) deferred entirely. MVP export handles text only.

## Design Decisions Log

| Decision | Choice | Rationale |
|---|---|---|
| Primary use case | Capture & export (clipboard paste) | Users mainly create comments and bulk-copy. 3-15 comments per session. |
| No toast on save | Badge pulse + window dismiss animation | Toast is redundant — the badge increment is sufficient feedback |
| Total count badge (not unseen) | Inventory model | Badge is "how many comments exist," not "how many are new" |
| Hover-reveal card actions | Cleaner default, focus as hover for keyboard | Reduces visual noise per card. Keyboard and right-click as alternatives. |
| Copy All always Markdown | Simplicity | One-click export. Format changeable in Preferences for power users. |
| Editor blocks popover | Dim overlay, non-interactive | Prevents confusion about which surface has focus during editing |
| Same view component for input + editor | One SwiftUI view, two hosting contexts | Changes to editor apply everywhere. Reduces code duplication. |
| Mutually exclusive popover/window | Prevents duplicate surfaces | One management surface at a time. Menu bar icon adapts to current mode. |
| Enum for comment reference | Future screenshot support | Costs nothing in MVP, prevents data migration later. |
