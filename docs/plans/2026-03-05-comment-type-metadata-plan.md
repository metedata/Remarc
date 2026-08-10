# Comment Type Metadata — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rename `CommentReference` → `CommentType`, make UI labels consistent across all comment types, and expose type metadata in export/copy/MCP.

**Architecture:** The existing `CommentReference` enum is the single source of truth for comment type. We rename it to `CommentType`, rename its cases (`textSelection` → `comment`, `voiceCritique` → `critMode`), add computed properties for display metadata, update all consumers (views, services, export, MCP), and add a new `includeType` export setting.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, TypeScript (MCP server)

**Design doc:** `docs/plans/2026-03-05-comment-type-metadata-design.md`

---

### Task 1: Rename CommentReference → CommentType (model)

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/CommentReference.swift` (rename to CommentType.swift)

**Step 1: Rename file**

Rename `CommentReference.swift` → `CommentType.swift` via git mv.

```bash
cd app/RemarcPackage/Sources/RemarcFeature/Models
git mv CommentReference.swift CommentType.swift
```

**Step 2: Rewrite the enum**

Replace the entire file contents with:

```swift
import Foundation

public enum CommentType: Codable, Equatable, Sendable {
    case comment(text: String)
    case screenshot(imagePath: String)
    case quickNote
    case critMode

    // MARK: - Display Metadata

    public var identifier: String {
        switch self {
        case .comment: return "comment"
        case .screenshot: return "screenshot"
        case .quickNote: return "quickNote"
        case .critMode: return "critMode"
        }
    }

    public var displayName: String {
        switch self {
        case .comment: return "Comment"
        case .screenshot: return "Screenshot"
        case .quickNote: return "Quick Note"
        case .critMode: return "Crit Mode"
        }
    }

    public var iconName: String {
        switch self {
        case .comment: return "text.quote"
        case .screenshot: return "camera.viewfinder"
        case .quickNote: return "note.text"
        case .critMode: return "mic.fill"
        }
    }

    // MARK: - Convenience

    public var displayText: String? {
        switch self {
        case .comment(let text): return text
        case .quickNote: return nil
        case .screenshot: return nil
        case .critMode: return nil
        }
    }

    public var isQuickNote: Bool {
        if case .quickNote = self { return true }
        return false
    }

    public var isScreenshot: Bool {
        if case .screenshot = self { return true }
        return false
    }

    public var isCritMode: Bool {
        if case .critMode = self { return true }
        return false
    }

    public var imagePath: String? {
        if case .screenshot(let path) = self { return path }
        return nil
    }
}
```

**Step 3: Commit**

```bash
git add -A && git commit -m "refactor: rename CommentReference → CommentType with new case names"
```

---

### Task 2: Update Comment.swift

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/Comment.swift`

**Step 1: Rename `reference` field to `type`**

- Line 5: `public var reference: CommentReference` → `public var type: CommentType`
- Init parameter (line 22): `reference: CommentReference` → `type: CommentType`
- Init body (line 38): `self.reference = reference` → `self.type = type`

**Step 2: Update CodingKeys**

- Line 57: Replace `case id, reference, selectedText, commentText, ...` with `case id, type, selectedText, commentText, ...`
- Remove legacy `stackID` key — no backward compat needed.

**Step 3: Simplify Codable**

Replace the custom `init(from:)` and `encode(to:)` with the auto-synthesized versions. Delete lines 65-124. Since we don't need backward compatibility, the compiler will generate correct Codable conformance. The only issue is the `CodingKeys` enum — remove it entirely and let the compiler synthesize from property names.

Actually, keep a minimal CodingKeys only if the property names don't match the JSON keys. Since we renamed `reference` → `type`, and Swift's auto-synthesis will use `type` as the key, this is fine. Delete:
- The `CodingKeys` enum (lines 56-63)
- The custom `init(from decoder:)` (lines 65-103)
- The custom `encode(to encoder:)` (lines 105-124)

**Step 4: Update computed properties**

- Line 138-140: `selectedText` — change `reference.displayText` → `type.displayText`
- Line 142-145: `isStandaloneNote` — change `reference.isQuickNote` → `type.isQuickNote`
- Line 148-163: `truncatedReference` — rename to `truncatedTypeLabel`, update switch from `reference` to `type`, update `.textSelection` → `.comment`, `.voiceCritique` → `.critMode`, change "Voice Critique" label to "Crit Mode"

**Step 5: Commit**

```bash
git add -A && git commit -m "refactor: update Comment model for CommentType rename"
```

---

### Task 3: Update PersistenceManager

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift`

**Step 1: Update createComment signature**

- Line 241: `reference: CommentReference` → `type: CommentType`
- Inside the method body: pass `type:` instead of `reference:` to `Comment(...)` init

**Step 2: Update imagePath references**

- Line 133: `comment.reference.imagePath` → `comment.type.imagePath`
- Line 291: `comment.reference.imagePath` → `comment.type.imagePath`
- Line 453: `comment.reference.imagePath` → `comment.type.imagePath`

**Step 3: Commit**

```bash
git add -A && git commit -m "refactor: update PersistenceManager for CommentType rename"
```

---

### Task 4: Update CritModeService

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/CritModeService.swift`

**Step 1: Update comment creation**

- Line 307: `reference: .voiceCritique` → `type: .critMode`

**Step 2: Commit**

```bash
git add -A && git commit -m "refactor: update CritModeService for CommentType rename"
```

---

### Task 5: Update CommentInputWindowController

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentInputWindowController.swift`

**Step 1: Update all reference creation sites**

- Line 230: `CommentReference.screenshot(imagePath: imagePath)` → `CommentType.screenshot(imagePath: imagePath)`, rename variable `reference` → `type`
- Line 232: Pass `type:` instead of `reference:` to `createComment()`
- Line 251: Same pattern as line 230
- Line 253: Same as 232
- Line 274: `let reference: CommentReference` → `let type: CommentType`
- Line 281: `reference = trimmed.isEmpty ? .quickNote : .textSelection(text: trimmed)` → `type = trimmed.isEmpty ? .quickNote : .comment(text: trimmed)`
- Line 284: `reference = .quickNote` → `type = .quickNote`
- Line 291: Pass `type:` instead of `reference:` to `createComment()`

**Step 2: Commit**

```bash
git add -A && git commit -m "refactor: update CommentInputWindowController for CommentType rename"
```

---

### Task 6: Update FloatingEditorController

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/FloatingEditorController.swift`

**Step 1: Update reference access**

- Line 41: `comment.reference.displayText` → `comment.type.displayText`
- Line 42: `comment.reference.imagePath` → `comment.type.imagePath`
- Line 68: `reference: .quickNote` → `type: .quickNote`

**Step 2: Commit**

```bash
git add -A && git commit -m "refactor: update FloatingEditorController for CommentType rename"
```

---

### Task 7: Update search filtering views

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentHistoryView.swift`
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`

**Step 1: Update reference access**

- CommentHistoryView line 22-23: `comment.reference.displayText` → `comment.type.displayText`
- PopoverContentView line 48: `comment.reference.displayText` → `comment.type.displayText`

**Step 2: Commit**

```bash
git add -A && git commit -m "refactor: update search views for CommentType rename"
```

---

### Task 8: Update HistoryCardView — reference access + delete warning

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/HistoryCardView.swift`

**Step 1: Update reference access**

- Line 113: `comment.reference.imagePath != nil` → `comment.type.imagePath != nil`

(The `referenceView` will be fully rewritten in Task 10.)

**Step 2: Commit**

```bash
git add -A && git commit -m "refactor: update HistoryCardView for CommentType rename"
```

---

### Task 9: Build checkpoint

**Step 1: Build to verify all renames compile**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData"
```

Fix any remaining `CommentReference`, `.reference`, `.textSelection`, `.voiceCritique`, or `isVoiceCritique` references the compiler finds.

**Step 2: Commit any fixes**

```bash
git add -A && git commit -m "fix: resolve remaining CommentType rename issues"
```

---

### Task 10: Consistent UI labels — CommentCardView + HistoryCardView

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift` (lines 54-119)
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/HistoryCardView.swift` (lines 38-73)

**Step 1: Rewrite `referenceView` in CommentCardView**

Replace the `referenceView` computed property (lines 54-119). All four cases get a consistent label, and `.comment` / `.screenshot` keep their content below.

```swift
@ViewBuilder
private var referenceView: some View {
    // Type label — consistent across all types
    Label(comment.type.displayName, systemImage: comment.type.iconName)
        .font(.system(size: 11))
        .foregroundStyle(.primary.opacity(0.6))
        .labelStyle(TypeLabelStyle(colorScheme: colorScheme))

    // Type-specific content below the label
    switch comment.type {
    case .comment(let text):
        Text("\u{201C}\(text)\u{201D}")
            .font(.system(size: 11))
            .italic()
            .foregroundStyle(Color.remarcAccent(for: colorScheme))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                FloatingEditorController.shared.showForEdit(comment: comment)
            }

    case .screenshot(let imagePath):
        ScreenshotThumbnailView(imagePath: imagePath, maxWidth: 140)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                ScreenshotPreviewController.shared.show(
                    imagePath: imagePath,
                    commentText: comment.commentText
                )
            }
            .contextMenu {
                Button {
                    if let nsImage = loadScreenshotImage(imagePath) {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.writeObjects([nsImage])
                        ToastManager.shared.show("Image copied")
                    }
                } label: {
                    Label("Copy Image", systemImage: "doc.on.doc")
                }
                Button {
                    saveScreenshotAs(imagePath: imagePath)
                } label: {
                    Label("Save Image As\u{2026}", systemImage: "square.and.arrow.down")
                }
            }

    case .quickNote, .critMode:
        EmptyView()
    }
}
```

**Step 2: Create `TypeLabelStyle`**

Add a small `LabelStyle` (can live in CommentCardView.swift or a shared file) that renders the icon in `remarcPrimary` and the title in `.primary.opacity(0.6)`:

```swift
struct TypeLabelStyle: LabelStyle {
    let colorScheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
            configuration.title
                .foregroundStyle(.primary.opacity(0.6))
        }
    }
}
```

**Step 3: Rewrite `referenceView` in HistoryCardView**

Same pattern but simpler (no tap gestures, no context menu):

```swift
@ViewBuilder
private var referenceView: some View {
    Label(comment.type.displayName, systemImage: comment.type.iconName)
        .font(.system(size: 11))
        .foregroundStyle(.primary.opacity(0.6))
        .labelStyle(TypeLabelStyle(colorScheme: colorScheme))

    switch comment.type {
    case .comment(let text):
        Text("\u{201C}\(text)\u{201D}")
            .font(.system(size: 11))
            .italic()
            .foregroundStyle(Color.remarcAccent(for: colorScheme))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
                    .frame(width: 2)
            }

    case .screenshot(let imagePath):
        ScreenshotThumbnailView(imagePath: imagePath, maxWidth: 140, maxHeight: 80)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.remarcPrimary(for: colorScheme).opacity(0.6))
                    .frame(width: 2)
            }

    case .quickNote, .critMode:
        EmptyView()
    }
}
```

**Step 4: Build and verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData"
```

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: consistent type labels across all comment types"
```

---

### Task 11: Add `includeType` to SettingsManager

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift`

**Step 1: Add the key**

In the `Keys` struct (around line 30), add:
```swift
static let includeType = "includeType"
```

**Step 2: Add the published property**

After `includeSource` (around line 111), add:
```swift
@Published public var includeType: Bool {
    didSet { defaults.set(includeType, forKey: Keys.includeType) }
}
```

**Step 3: Initialize in init**

In the initializer, after `includeSource` is loaded (around line 247), add:
```swift
self.includeType = defaults.object(forKey: Keys.includeType) != nil
    ? defaults.bool(forKey: Keys.includeType)
    : true
```

**Step 4: Commit**

```bash
git add -A && git commit -m "feat: add includeType export setting"
```

---

### Task 12: Add type to ExportManager — markdown + JSON + preview

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift`

**Step 1: Add `ExportHighlight.type` case**

Line 6: Add `type` to the second case line:
```swift
case source, date, status, remarkID, aiHint, type
```

**Step 2: Update `formatReference` — rename switch**

Lines 28-49: Change `comment.reference` → `comment.type`, `.textSelection` → `.comment`, `.voiceCritique` → `.critMode`.

**Step 3: Add `includeType` to `formatMetadataLine`**

Add parameter `includeType: Bool` to the signature (line 108). Inside the method, add before the `includeRemarkID` block (around line 119):
```swift
if includeType {
    parts.append("Type: \(comment.type.displayName)")
}
```

**Step 4: Thread `includeType` through `markdownForComments`**

Add `includeType: Bool` parameter to the `markdownForComments` signature (line 162). Pass it through to `formatMetadataLine`.

**Step 5: Thread `includeType` through `markdownForSession` and `markdownForComment`**

- `markdownForSession` (line 138): Add `includeType: settings.includeType` to the call.
- `markdownForComment` (line 283): Add `includeType: settings.includeType` to the call.

**Step 6: Add `type` to JSON export**

In `ExportComment` struct (line 231), add:
```swift
let type: String
```

In the mapping (line 248-257), add:
```swift
type: comment.type.identifier,
```

**Step 7: Update sample comments for preview**

Lines 304-360: Change all `.textSelection(text:)` → `.comment(text:)`. Add 1-2 sample comments with `.quickNote` and `.critMode` types to demonstrate type metadata in preview.

**Step 8: Update `previewLines` signature and body**

Add `includeType: Bool` parameter to `previewLines` (line 364). In the metadata section (lines 436-469), add a type segment before `includeRemarkID`:

```swift
if includeType {
    if metaFieldCount > 0 {
        metaSegments.append(PreviewSegment(text: metadataDivider.separator, highlights: [.metadataDivider]))
    }
    metaSegments.append(PreviewSegment(text: "Type: \(comment.type.displayName)", highlights: [.type]))
    metaFieldCount += 1
}
```

Also update the switch on `comment.reference` (line 386) → `comment.type`, `.textSelection` → `.comment`, `.voiceCritique` → `.critMode`.

**Step 9: Commit**

```bash
git add -A && git commit -m "feat: add type metadata to markdown/JSON export and preview"
```

---

### Task 13: Add Type toggle to PreferencesWindowController

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Add toggle row**

Around line 371 (the metadata toggles section), add before the "Source app" row:
```swift
toggleRow("Type", isOn: $settings.includeType, highlight: .type)
```

**Step 2: Thread `includeType` to preview**

Around line 470 (the `exportPreviewLines` computed property), add:
```swift
includeType: settings.includeType,
```

**Step 3: Update any remaining `.reference` / `.referenceStyle` naming**

The `referenceStyle` setting name stays — it controls how the *reference text* (blockquote vs Re: vs quoted) is formatted, which is a separate concept from the type label.

**Step 4: Build and verify**

```bash
cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData"
bash scripts/relaunch.sh
```

**Step 5: Commit**

```bash
git add -A && git commit -m "feat: add Type toggle to export preferences"
```

---

### Task 14: Update MCP server — data.ts

**Files:**
- Modify: `mcp/src/data.ts`

**Step 1: Rename CommentReference → CommentType**

Lines 42-45: Replace with:
```typescript
export type CommentType =
  | { comment: { text: string } }
  | { screenshot: { imagePath: string } }
  | { quickNote: Record<string, never> }
  | { critMode: Record<string, never> };
```

**Step 2: Update RawComment and Comment interfaces**

- Line 49: `reference?: CommentReference` → `type?: CommentType`
- Line 70: `reference: CommentReference` → `type: CommentType`

**Step 3: Update parseReference → parseType**

Rename the function (around line 146) and update the field name it reads from raw data. Update case handling for new key names (`comment` instead of `textSelection`, `critMode` instead of `voiceCritique`).

**Step 4: Add typeIdentifier helper**

```typescript
export function typeIdentifier(t: CommentType): string {
  if ("comment" in t) return "comment";
  if ("screenshot" in t) return "screenshot";
  if ("critMode" in t) return "critMode";
  return "quickNote";
}
```

**Step 5: Rename referenceLabel → typeLabel**

Lines 290-301: Rename function and update key checks:
```typescript
export function typeLabel(t: CommentType): string {
  if ("comment" in t) {
    const text = t.comment.text;
    const cleaned = text.replace(/\n/g, " ").trim();
    if (cleaned.length > 80) return `"${cleaned.slice(0, 80)}..."`;
    return `"${cleaned}"`;
  }
  if ("screenshot" in t) {
    return `Screenshot: ${t.screenshot.imagePath}`;
  }
  if ("critMode" in t) {
    return "Crit Mode";
  }
  return "Quick Note";
}
```

**Step 6: Update all callers of parseReference / referenceLabel in data.ts**

Search for any internal usage and update.

**Step 7: Commit**

```bash
git add -A && git commit -m "refactor: rename CommentReference → CommentType in MCP data.ts"
```

---

### Task 15: Update MCP server — tools.ts

**Files:**
- Modify: `mcp/src/tools.ts`

**Step 1: Update imports**

Line 6: `referenceLabel` → `typeLabel, typeIdentifier`

**Step 2: Update formatCommentLine**

Line 67: `referenceLabel(comment.reference)` → `typeLabel(comment.type)`

Add type tag to the formatted output — include `[${typeIdentifier(comment.type)}]` alongside the status tag.

**Step 3: Update remarc_get_comment**

Line 212: `referenceLabel(comment.reference)` → `typeLabel(comment.type)`

Add a `Type:` line to the detail output.

**Step 4: Add type filter to remarc_list_comments**

Around line 143, add to the input schema:
```typescript
type: z
  .enum(["comment", "screenshot", "quickNote", "critMode"])
  .optional()
  .describe('Filter by type: "comment", "screenshot", "quickNote", or "critMode". Omit for all.'),
```

In the handler (around line 155), add filter:
```typescript
if (type) {
  comments = comments.filter((c) => typeIdentifier(c.type) === type);
}
```

**Step 5: Update all remaining `.reference` access to `.type`**

Search tools.ts for any remaining `.reference` and replace with `.type`.

**Step 6: Build MCP**

```bash
cd mcp && npm run build
```

**Step 7: Commit**

```bash
git add -A && git commit -m "feat: add type metadata and filter to MCP tools"
```

---

### Task 16: Final build, relaunch, and wipe old data

**Step 1: Delete old data**

```bash
rm -f ~/Library/Application\ Support/Remarc/data.json
```

**Step 2: Full build**

```bash
cd app && xcodebuild clean build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -derivedDataPath "$PWD/DerivedData"
```

**Step 3: Relaunch**

```bash
bash scripts/relaunch.sh
```

**Step 4: Final commit**

```bash
git add -A && git commit -m "feat: comment type metadata — complete"
```
