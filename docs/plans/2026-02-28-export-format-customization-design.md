# Export Format Customization

## Problem

The current "Copy All" export is hardcoded to a single markdown format with an all-or-nothing metadata toggle. Users (primarily pasting into AI chats like Claude Code) need control over the output format and which metadata fields are included.

## Design

### Approach: Baseline Format + Toggleable Options

One baseline markdown format for clipboard copy, with formatting options and per-field metadata toggles. A live preview in the settings tab shows the effect of each change instantly.

### Formatting Options

| Option | Choices | Default |
|--------|---------|---------|
| Reference style | `>` blockquote / `Re:` prefix / `"quoted"` inline | `>` blockquote |
| Comment numbering | Numbered / Bulleted / None | Numbered |
| Dividers between comments | Horizontal rule / Blank line only | Blank line |
| Date format | Short ("Feb 28") / ISO ("2026-02-28") / Relative ("2 days ago") | Short |

### Metadata Field Toggles

| Field | Default |
|-------|---------|
| Source app | ON |
| Date | ON |
| Status (open/resolved) | OFF |

### Output Examples

**Default (compact, AI-optimized):**

```
1. > Selected text here
   Comment about this text
   _Source: VS Code | Feb 28_

2. > Another selection
   Another comment
   _Source: Safari | Feb 28_
```

**With Re: prefix, status on:**

```
1. Re: Selected text here
   Comment about this text
   _Source: VS Code | Feb 28 | Open_

2. Re: Another selection
   Another comment
   _Source: Safari | Feb 27 | Resolved_
```

**Minimal (all metadata off, no numbering):**

```
> Selected text here

Comment about this text

> Another selection

Another comment
```

### Settings UI — Export Tab (Two-Column)

```
┌─ Export ─────────────────────────────────────────────────────────────────┐
│                                                                         │
│  ┌─ Settings ──────────────────┐  ┌─ Preview ────────────────────────┐  │
│  │                             │  │                                  │  │
│  │  Clipboard Format           │  │  1. > Lorem ipsum dolor sit      │  │
│  │                             │  │     amet, consectetur            │  │
│  │  Reference style            │  │     This is a sample comment.    │  │
│  │  [> Blockquote ▾]           │  │     _Source: TextEdit | Feb 28_  │  │
│  │                             │  │                                  │  │
│  │  Numbering                  │  │  2. > Sed do eiusmod tempor      │  │
│  │  [Numbered ▾]               │  │     Another comment here.       │  │
│  │                             │  │     _Source: Safari | Feb 27_    │  │
│  │  Dividers                   │  │                                  │  │
│  │  [Blank line ▾]             │  │                                  │  │
│  │                             │  │                                  │  │
│  │  Date format                │  │                                  │  │
│  │  [Short ▾]                  │  │                                  │  │
│  │                             │  │                                  │  │
│  │  Include in Export          │  │                                  │  │
│  │  ☑ Source app               │  │                                  │  │
│  │  ☑ Date                     │  │                                  │  │
│  │  ☐ Status                   │  │                                  │  │
│  │                             │  │                                  │  │
│  │  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─  │  │                                  │  │
│  │                             │  │                                  │  │
│  │  File Export                │  │                                  │  │
│  │  Default format             │  │                                  │  │
│  │  [Markdown ▾]               │  │                                  │  │
│  │                             │  │                                  │  │
│  └─────────────────────────────┘  └──────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

- Live preview updates instantly on any change
- Preview uses sample/dummy data
- Monospace font, recessed background for preview area
- Preferences window widened from 480px to ~640px for two-column layout

### Data Model

**New enums in SettingsManager:**

```swift
enum ReferenceStyle: String, CaseIterable, Sendable {
    case blockquote    // > text
    case rePrefix      // Re: text
    case quoted        // "text"
}

enum NumberingStyle: String, CaseIterable, Sendable {
    case numbered      // 1. 2. 3.
    case bulleted      // - - -
    case none
}

enum DividerStyle: String, CaseIterable, Sendable {
    case horizontalRule // ---
    case blankLine      // \n\n
}

enum ExportDateFormat: String, CaseIterable, Sendable {
    case short         // "Feb 28"
    case iso           // "2026-02-28"
    case relative      // "2 days ago"
}
```

**New SettingsManager properties (persisted to UserDefaults):**

```swift
@Published var referenceStyle: ReferenceStyle = .blockquote
@Published var numberingStyle: NumberingStyle = .numbered
@Published var dividerStyle: DividerStyle = .blankLine
@Published var exportDateFormat: ExportDateFormat = .short
@Published var includeSource: Bool = true
@Published var includeDate: Bool = true
@Published var includeStatus: Bool = false
```

**Migration:** Existing `includeMetadataInExport: true` maps to `includeSource = true, includeDate = true`. `includeMetadataInExport: false` maps to all fields OFF.

### ExportManager Changes

- Refactor `markdownForSession` to read new settings and format accordingly
- Add `previewMarkdown()` for the settings preview (uses hardcoded sample data)
- `copyCommentToClipboard` (single comment copy) also respects the new formatting options
- File export (Markdown/JSON) continues to work; JSON format unaffected
- Remove the old `includeMetadataInExport` boolean in favor of individual toggles

### Scope

- **In scope:** Clipboard copy formatting, Export tab UI, live preview, settings persistence
- **Out of scope:** Template strings, CSV export, session name header (no multi-session yet), file export format changes beyond the existing Markdown/JSON picker
