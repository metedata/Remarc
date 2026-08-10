# Settings Window Sidebar Redesign

## Problem

The current settings window (980x460, toolbar tabs) has several IA issues:
- General tab is a catch-all bucket with unrelated settings (login, detection, shortcuts, clipboard, MCP)
- Excluded Apps and License tabs are too thin to justify their own toolbar tab
- Fixed window size is dictated by Export's two-column layout, leaving other tabs swimming in whitespace
- Settings are arranged haphazardly within tabs

## Design

### Window & Navigation

- **Layout:** `NavigationSplitView` with sidebar (200pt) + detail pane (~900pt)
- **Window size:** ~1100 x 500pt, `NSWindow` with `.titled, .closable`. Not resizable.
- **Window level:** `NSWindow.Level.popUpMenu + 1` (unchanged)
- **Sidebar style:** Flat list, no section headers or separators. Each row: SF Symbol icon + label.
- **Selection:** Single selection, persisted across reopen (restore last-viewed section).

### Sidebar Items

| Row | SF Symbol | Label |
|-----|-----------|-------|
| 1 | `gearshape` | General |
| 2 | `command` | Shortcuts |
| 3 | `square.and.arrow.up` | Export |
| 4 | `globe` | Chrome Extension |
| 5 | `server.rack` | MCP Server |
| 6 | `app.dashed` | Excluded Apps |
| 7 | `key` | License |
| 8 | `info.circle` | About |

No grouping or section headers — 8 items is flat enough to scan without hierarchy.

### Detail Panes

#### General
Grouped form sections inside the detail pane:

**App**
- Launch at login (toggle)
- Detection mode (picker: auto / hotkey only)

**Clipboard**
- Clean up whitespace (toggle)
- Copy screenshot to clipboard (toggle)

**Retention**
- History retention (picker: 1, 7, 30 days)
- Image retention (picker: 7, 14, 30 days)
- Delete resolved comments (picker: never / immediately / 15min / 1hr / 1 day)
- Total remarks count (read-only display)

#### Shortcuts
- Comment on Selection (keyboard recorder)
- Screenshot Comment (keyboard recorder)
- Paste All Comments (keyboard recorder)
- Voice Input (keyboard recorder, macOS 26+)

#### Export
Unchanged — left column controls + right column live preview. Same settings: reference style, comment prefix, list style, dividers, metadata toggles, date/time format, auto-clear, file format.

#### Chrome Extension
- Connection status indicator (colored dot + text) with port
- Error state with retry button
- First-time onboarding card with installation link
- Captured Metadata toggles (React, computed styles, accessibility, layout, identity) — shown when extension has connected at least once

#### MCP Server
- Enable MCP server (toggle)
- Dependency status (Node.js installed, Claude Code CLI installed)
- Check Again button
- Relaunch hint when toggled on

#### Excluded Apps
Standard macOS editable list pattern:
- Bordered list showing excluded apps (24pt icon + app name per row)
- **+ button** (bottom-left) → `NSOpenPanel` filtered to `.app` bundles, starting at `/Applications`
- **- button** → removes selected item
- Stored by bundle identifier (resilient across updates/moves)
- No more separate floating window — fully inline

#### License
- License status display (free with count / pro / expired / invalid)
- Enter License Key button (opens sheet or inline entry)
- Upgrade to Pro button (opens checkout URL)

#### About
- App icon (centered)
- App name + tagline
- Version number
- Check for Updates button (Sparkle)
- Links: website, changelog, support/feedback

### SwiftUI Implementation Notes

- Use `NavigationSplitView` with `.navigationSplitViewColumnWidth(200)` for sidebar
- Detail panes use `Form` with `.formStyle(.grouped)` where appropriate (General, Shortcuts, Chrome Extension, MCP Server)
- Export detail pane keeps its custom two-column layout (not Form)
- Excluded Apps uses `List` with selection + toolbar buttons (not Form)
- About uses centered VStack layout (not Form)
- State management stays on `SettingsManager` (`ObservableObject` singleton) — no changes to data layer
- Tab selection via enum, persisted to UserDefaults for restore-on-reopen
- `PreferencesWindowController` updated: window width from 980 → 1100, height 460 → 500
- `ExcludeListWindowController` (separate floating window) eliminated — functionality moves inline

### Migration

- Remove `PrefsTab` enum, replace with new `SettingsSection` enum
- Remove toolbar tab view, replace with `NavigationSplitView`
- Move Excluded Apps list UI from `ExcludeListWindowController` into inline detail pane
- Add NSOpenPanel-based app picker (replacing running-apps picker)
- Add About section view
- Remove `ExcludeListWindowController` and its floating window
- Keep `LicenseEntryWindowController` for now (modal entry makes sense)
- Update `show(tab:)` to `show(section:)` using new enum
