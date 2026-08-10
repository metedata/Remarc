# Comment Type Metadata — Design

**Date:** 2026-03-05

## Problem

1. Comment labels are styled inconsistently — Crit Mode uses brand color, Quick Note uses gray
2. No explicit type metadata in export, copy, or MCP output
3. `CommentReference` naming is confusing — it IS the type, not just a reference
4. MCP server is missing `voiceCritique` from its TypeScript union

## Design

### 1. Model Rename: `CommentReference` → `CommentType`

Rename the enum and its cases:

| Old | New |
|-----|-----|
| `CommentReference` | `CommentType` |
| `.textSelection(text: String)` | `.comment(text: String)` |
| `.screenshot(imagePath: String)` | `.screenshot(imagePath: String)` |
| `.quickNote` | `.quickNote` |
| `.voiceCritique` | `.critMode` |

Field on `Comment` renames from `reference` to `type`.

**Computed properties on `CommentType`:**
- `identifier: String` — `"comment"`, `"screenshot"`, `"quickNote"`, `"critMode"`
- `displayName: String` — `"Comment"`, `"Screenshot"`, `"Quick Note"`, `"Crit Mode"`
- `iconName: String` — `"text.quote"`, `"camera.viewfinder"`, `"note.text"`, `"mic.fill"`

Existing convenience properties (`displayText`, `isQuickNote`, `isScreenshot`, `imagePath`) stay. `isVoiceCritique` renames to `isCritMode`.

**No backward compatibility needed.** Old `data.json` can be wiped on decode failure — no custom Codable migration.

### 2. UI Label Consistency

All four types get an explicit label in `CommentCardView` and `HistoryCardView`:

- **Icon**: `remarcPrimary` (brand color)
- **Text**: `.primary.opacity(0.6)` (gray secondary)
- **Font**: `.system(size: 11)`

For `.comment` and `.screenshot`, the label appears above the existing content (quoted text / thumbnail). For `.quickNote` and `.critMode`, the label is all there is.

### 3. Export & Copy

**Markdown export:**
- New metadata field: `Type: Comment` / `Type: Screenshot` / `Type: Quick Note` / `Type: Crit Mode`
- Appears in the metadata line alongside Source, Date, Status (joined by user's chosen divider)
- Controlled by new `includeType` toggle in export settings

**JSON export:**
- New `type` field on `ExportComment`: `"comment"`, `"screenshot"`, `"quickNote"`, `"critMode"`
- Always included (structural field, not optional)

**Settings:**
- New `includeType: Bool` on `SettingsManager` (default `true`)
- New toggle row "Type" in PreferencesWindowController metadata section

### 4. MCP Server

**TypeScript types (`data.ts`):**
- Rename `CommentReference` → `CommentType`
- Update union:
  ```typescript
  export type CommentType =
    | { comment: { text: string } }
    | { screenshot: { imagePath: string } }
    | { quickNote: Record<string, never> }
    | { critMode: Record<string, never> };
  ```
- Rename `referenceLabel` → `typeLabel`, handle all four cases including `critMode`
- Add `typeIdentifier(type: CommentType): string` helper

**Tool output (`tools.ts`):**
- `remarc_list_comments` and `remarc_get_comment` include type identifier in output
- `remarc_list_comments` gains optional `type` filter parameter

**Interfaces:**
- Rename `reference` → `type` field on `RawComment` / `Comment`

## Scope

### Files to modify

**Swift (model + services):**
- `Models/CommentReference.swift` → rename to `CommentType.swift`
- `Models/Comment.swift` — field rename, update computed properties
- `Services/PersistenceManager.swift` — update `createComment` calls
- `Services/ExportManager.swift` — add type to metadata line + JSON export
- `Services/SettingsManager.swift` — add `includeType` toggle
- `Services/CritModeService.swift` — update `.voiceCritique` → `.critMode`

**Swift (views):**
- `Views/CommentCardView.swift` — consistent labels for all types
- `Views/HistoryCardView.swift` — consistent labels for all types
- `Views/CommentInputWindowController.swift` — update reference creation
- `Views/FloatingEditorController.swift` — update reference usage
- `Views/PopoverContentView.swift` — update reference usage
- `Views/CommentHistoryView.swift` — update reference usage
- `Views/PreferencesWindowController.swift` — add "Type" toggle row

**MCP (TypeScript):**
- `mcp/src/data.ts` — type rename, add helpers
- `mcp/src/tools.ts` — type filter, output format
