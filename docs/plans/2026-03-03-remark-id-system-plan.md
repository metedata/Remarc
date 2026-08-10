# Remark ID System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add human-friendly sequential IDs (`#R-1`, `#R-2`, ...) to comments so AI agents can reference and update them via MCP.

**Architecture:** Add `remarkID: Int` to the Comment struct, assigned from a global counter (resets at 10,000). Show in UI metadata, include in exports with an optional AI hint. Extend MCP tools to accept `remark_id` as an alternative to UUID.

**Tech Stack:** Swift/SwiftUI (app), TypeScript/Node.js (MCP server)

---

### Task 1: Add `remarkID` field to Comment model

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Models/Comment.swift`

**Step 1: Add the field and update init**

In `Comment.swift`, add `remarkID` as a stored property after `attachments` (line 18), add it to `init` with a default of `0`, and add it to `CodingKeys`:

```swift
// Line 18, after attachments:
public var remarkID: Int

// In init (line 35), add parameter before attachments:
remarkID: Int = 0,
attachments: [String] = []

// In init body (after line 51):
self.remarkID = remarkID
```

**Step 2: Update CodingKeys**

Add `remarkID` to the CodingKeys enum (line 56-63):

```swift
private enum CodingKeys: String, CodingKey {
    case id, reference, selectedText, commentText, source, appBundleID
    case createdAt, updatedAt, sessionID, isDeleted, deletedAt
    case status, resolutionSummary, resolvedBy, resolvedAt
    case attachments, remarkID
    // Legacy key for reading old data
    case stackID
}
```

**Step 3: Update Codable**

In `init(from:)` (after line 102), decode with backward compat:

```swift
remarkID = try container.decodeIfPresent(Int.self, forKey: .remarkID) ?? 0
```

In `encode(to:)` (after line 123, before closing brace):

```swift
if remarkID > 0 {
    try container.encode(remarkID, forKey: .remarkID)
}
```

**Step 4: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```
feat: add remarkID field to Comment model
```

---

### Task 2: Assign remarkID in PersistenceManager and handle counter reset

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift`

**Step 1: Assign remarkID when creating comments**

In `createComment` (lines 240-270), after incrementing `totalCommentsCreated` (line 265), compute the remarkID with reset logic and assign it to the comment:

```swift
// Replace lines 255-268 with:
appState.totalCommentsCreated += 1
let remarkID = ((appState.totalCommentsCreated - 1) % 10_000) + 1

let comment = Comment(
    reference: reference,
    commentText: commentText,
    source: source,
    appBundleID: appBundleID,
    sessionID: activeSessionID,
    remarkID: remarkID,
    attachments: attachments
)

appState.comments.append(comment)

scheduleSave()
debugLog("PersistenceManager: Created comment #R-\(remarkID) (total: \(appState.totalCommentsCreated))")
```

Note: The counter increment moves BEFORE Comment creation so `remarkID` can be passed to the initializer. The formula `((total - 1) % 10_000) + 1` gives IDs 1-10000, then wraps back to 1.

**Step 2: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
feat: assign remarkID to new comments with 10K reset
```

---

### Task 3: Migrate existing comments to have remarkIDs

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/PersistenceManager.swift`

**Step 1: Add migration in loadFromDisk/reloadFromDisk**

Find the `reloadFromDisk()` method (around line 397). After the state is loaded and assigned, add migration logic that assigns remarkIDs to any comments that have `remarkID == 0`:

```swift
// After appState is assigned from decoded data, add:
migrateRemarkIDs()
```

Add a new private method:

```swift
private func migrateRemarkIDs() {
    // Sort all comments by createdAt to assign IDs in chronological order
    let needsMigration = appState.comments.contains { $0.remarkID == 0 }
    guard needsMigration else { return }

    // Get all comments sorted by creation date
    let sorted = appState.comments.enumerated()
        .sorted { $0.element.createdAt < $1.element.createdAt }

    // Track next ID — start from 1 for migration
    var nextID = 1
    for (originalIndex, _) in sorted {
        if appState.comments[originalIndex].remarkID == 0 {
            appState.comments[originalIndex].remarkID = nextID
            nextID += 1
        }
    }

    // Update totalCommentsCreated if needed (in case it's behind)
    if nextID - 1 > appState.totalCommentsCreated {
        appState.totalCommentsCreated = nextID - 1
    }

    scheduleSave()
    debugLog("PersistenceManager: Migrated \(nextID - 1) comments with remarkIDs")
}
```

**Step 2: Call migration on initial load too**

Find where `appState` is first loaded (in `init` or `loadFromDisk`). Make sure `migrateRemarkIDs()` is called after the initial load as well, not just `reloadFromDisk`.

**Step 3: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```
feat: migrate existing comments to have remarkIDs
```

---

### Task 4: Update CommentCardView metadata to show remarkID

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/CommentCardView.swift`

**Step 1: Replace source app name with remarkID**

In `metadataView` (line 175), replace the metadata text:

Before:
```swift
Text("\(appDisplayName(for: comment)) — \(comment.createdAt.formatted(date: .abbreviated, time: .shortened))")
```

After:
```swift
Text("#R-\(comment.remarkID) — \(comment.createdAt.formatted(date: .abbreviated, time: .shortened))")
```

**Step 2: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Kill and relaunch to verify visually**

Kill running Remarc and launch the new build. Verify that comment cards show `#R-N` in the metadata row instead of the source app name.

**Step 4: Commit**

```
feat: show remarkID in comment card metadata
```

---

### Task 5: Add export settings for remarkID and AI hint

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift`

**Step 1: Add Keys**

In the `Keys` enum (lines 11-37), add:

```swift
static let includeRemarkID = "includeRemarkID"
static let includeAIHint = "includeAIHint"
```

**Step 2: Add published properties**

After the `metadataDividerStyle` property (line 128-130), add:

```swift
@Published public var includeRemarkID: Bool {
    didSet { defaults.set(includeRemarkID, forKey: Keys.includeRemarkID) }
}

@Published public var includeAIHint: Bool {
    didSet { defaults.set(includeAIHint, forKey: Keys.includeAIHint) }
}
```

**Step 3: Initialize in init()**

In the `init()` method, after the existing settings initialization (around line 244), add:

```swift
if defaults.object(forKey: Keys.includeRemarkID) != nil {
    self.includeRemarkID = defaults.bool(forKey: Keys.includeRemarkID)
} else {
    self.includeRemarkID = true  // Default: on
}

if defaults.object(forKey: Keys.includeAIHint) != nil {
    self.includeAIHint = defaults.bool(forKey: Keys.includeAIHint)
} else {
    self.includeAIHint = true  // Default: on
}
```

**Step 4: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```
feat: add includeRemarkID and includeAIHint settings
```

---

### Task 6: Update ExportManager to include remarkID and AI hint

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift`

**Step 1: Add `includeRemarkID` parameter to `formatMetadataLine`**

Update the `formatMetadataLine` method (lines 108-130) to accept and handle remarkID:

```swift
public func formatMetadataLine(
    _ comment: Comment,
    includeRemarkID: Bool,
    includeSource: Bool,
    includeDate: Bool,
    includeStatus: Bool,
    dateFormat: SettingsManager.ExportDateFormat,
    includeTime: Bool = false,
    use24Hour: Bool = false,
    metadataDivider: SettingsManager.MetadataDividerStyle = .pipe
) -> String? {
    var parts: [String] = []
    if includeRemarkID && comment.remarkID > 0 {
        parts.append("#R-\(comment.remarkID)")
    }
    if includeSource {
        parts.append(comment.source)
    }
    if includeDate {
        parts.append(formatDate(comment.createdAt, format: dateFormat, includeTime: includeTime, use24Hour: use24Hour))
    }
    if includeStatus {
        parts.append(comment.status == .open ? "Open" : "Resolved")
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: metadataDivider.separator)
}
```

Note: Removed `"Source: "` prefix from the source field since remarkID is now the first element and the label is redundant in a metadata line. This keeps the metadata cleaner: `#R-42 | Xcode | Mar 3` instead of `#R-42 | Source: Xcode | Mar 3`.

**Step 2: Thread `includeRemarkID` through `markdownForComments`**

Add `includeRemarkID: Bool` parameter to `markdownForComments` (line 153) and pass it to `formatMetadataLine` (line 186).

```swift
public func markdownForComments(
    _ comments: [Comment],
    referenceStyle: SettingsManager.ReferenceStyle,
    numberingStyle: SettingsManager.NumberingStyle,
    commentPrefixStyle: SettingsManager.CommentPrefixStyle = .none,
    dividerStyle: SettingsManager.DividerStyle,
    dateFormat: SettingsManager.ExportDateFormat,
    includeRemarkID: Bool,
    includeSource: Bool,
    includeDate: Bool,
    includeStatus: Bool,
    includeTime: Bool = false,
    use24Hour: Bool = false,
    metadataDivider: SettingsManager.MetadataDividerStyle = .pipe
) -> String {
```

Update the `formatMetadataLine` call inside (line 186-197) to pass `includeRemarkID`:

```swift
if let metadataLine = formatMetadataLine(
    comment,
    includeRemarkID: includeRemarkID,
    includeSource: includeSource,
    ...
```

**Step 3: Add AI hint footer to session export**

Update `markdownForSession` (lines 134-150) to append the AI hint after the formatted comments:

```swift
public func markdownForSession(_ session: Session, comments: [Comment], includeMetadata: Bool) -> String {
    let settings = SettingsManager.shared
    var result = markdownForComments(
        comments,
        referenceStyle: settings.referenceStyle,
        numberingStyle: settings.numberingStyle,
        commentPrefixStyle: settings.commentPrefixStyle,
        dividerStyle: settings.dividerStyle,
        dateFormat: settings.exportDateFormat,
        includeRemarkID: settings.includeRemarkID,
        includeSource: settings.includeSource,
        includeDate: settings.includeDate,
        includeStatus: settings.includeStatus,
        includeTime: settings.includeTime,
        use24Hour: settings.timeFormat.use24Hour,
        metadataDivider: settings.metadataDividerStyle
    )

    // Append AI hint if enabled and MCP is active
    if settings.includeAIHint && MCPManager.shared.isEnabled {
        result += "\n\n<!-- To update these comments, use the Remarc MCP tools (remarc_resolve, remarc_reopen). -->"
    }

    return result
}
```

**Step 4: Update `markdownForComment` (single comment export)**

Update `markdownForComment` (lines 272-288) to pass `includeRemarkID`:

```swift
public func markdownForComment(_ comment: Comment) -> String {
    let settings = SettingsManager.shared
    return markdownForComments(
        [comment],
        referenceStyle: settings.referenceStyle,
        numberingStyle: .none,
        commentPrefixStyle: settings.commentPrefixStyle,
        dividerStyle: .blankLine,
        dateFormat: settings.exportDateFormat,
        includeRemarkID: settings.includeRemarkID,
        includeSource: settings.includeSource,
        includeDate: settings.includeDate,
        includeStatus: settings.includeStatus,
        includeTime: settings.includeTime,
        use24Hour: settings.timeFormat.use24Hour,
        metadataDivider: settings.metadataDividerStyle
    )
}
```

**Step 5: Update all other callers of `markdownForComments`**

Search for all callers of `markdownForComments` (preview methods, etc.) and add the `includeRemarkID` parameter. The preview methods (`previewLines`, `previewMarkdown`) should also pass this. Search with:

```
grep -n "markdownForComments\|formatMetadataLine" ExportManager.swift
```

Update each call site to include `includeRemarkID:`.

**Step 6: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```
feat: include remarkID and AI hint in exports
```

---

### Task 7: Add export setting toggles to Preferences UI

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Add remarkID and AI hint toggles**

In the "Include in Export" section (lines 334-344), add the two new toggles after the existing ones:

```swift
// After line 343 (Status toggle):
toggleRow("Remark ID", isOn: $settings.includeRemarkID, highlight: .remarkID)
toggleRow("AI hint", isOn: $settings.includeAIHint, highlight: .aiHint)
```

Note: The `highlight` parameter is used for preview highlighting. Check the `HighlightTag` enum in the file and add `.remarkID` and `.aiHint` cases if needed. If the enum doesn't exist or highlighting isn't needed, omit the `highlight:` parameter.

**Step 2: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Kill and relaunch to verify visually**

Open Preferences > Export tab. Verify the two new toggles appear in the "Include in Export" section.

**Step 4: Commit**

```
feat: add remarkID and AI hint toggles to export settings
```

---

### Task 8: Add total remarks counter to Settings UI

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Find the appropriate settings tab**

Look for a "General" or "About" tab in PreferencesWindowController. Add a read-only stat display showing the total comment count.

```swift
// In the appropriate section:
HStack {
    Text("Total remarks")
        .font(.system(size: 12))
        .foregroundStyle(.primary.opacity(0.6))
    Spacer()
    Text("\(PersistenceManager.shared.appState.totalCommentsCreated)")
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.primary.opacity(0.45))
}
```

**Step 2: Build to verify**

Run: `cd app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```
feat: show total remarks counter in settings
```

---

### Task 9: Update MCP data layer with remarkID

**Files:**
- Modify: `mcp/src/data.ts`

**Step 1: Add remarkID to TypeScript types**

In `RawComment` interface (line 47-65), add:

```typescript
remarkID?: number;
```

In `Comment` interface (line 67-83), add:

```typescript
remarkID: number;
```

**Step 2: Update parseComment**

In `parseComment` (lines 152-170), add remarkID parsing:

```typescript
remarkID: raw.remarkID ?? 0,
```

**Step 3: Update serializeComment**

In `serializeComment` (lines 199-219), add remarkID serialization:

```typescript
if (c.remarkID > 0) {
    raw.remarkID = c.remarkID;
}
```

Note: Add the `remarkID` field to the `RawComment` type definition as optional to support both old and new data formats. This needs to be added as an optional field on the RawComment interface: `remarkID?: number;`.

**Step 4: Build MCP to verify**

Run: `cd mcp && npm run build 2>&1 | tail -5`
Expected: No errors

**Step 5: Commit**

```
feat(mcp): add remarkID to data types and serialization
```

---

### Task 10: Extend MCP tools to accept remark_id parameter

**Files:**
- Modify: `mcp/src/tools.ts`

**Step 1: Add a `findCommentByRemarkID` helper**

After the existing helpers (around line 43), add:

```typescript
function findComment(
    comments: Comment[],
    commentId?: string,
    remarkId?: number
): Comment | undefined {
    if (commentId) {
        return comments.find((c) => c.id === commentId);
    }
    if (remarkId != null) {
        // Search non-deleted first, most recent match
        const nonDeleted = comments
            .filter((c) => !c.isDeleted && c.remarkID === remarkId)
            .sort((a, b) => b.createdAt.getTime() - a.createdAt.getTime());
        if (nonDeleted.length > 0) return nonDeleted[0];
        // Fall back to any match
        return comments.find((c) => c.remarkID === remarkId);
    }
    return undefined;
}
```

**Step 2: Update `remarc_get_comment` input schema and handler**

Change the input schema (lines 169-171) to accept either comment_id or remark_id:

```typescript
inputSchema: {
    comment_id: z.string().optional().describe("The UUID of the comment. Provide either this or remark_id."),
    remark_id: z.number().optional().describe("The Remark ID number (#R-N). Provide either this or comment_id."),
},
```

Update the handler (line 172) to use the new `findComment` helper:

```typescript
}, async ({ comment_id, remark_id }) => {
    try {
        const state = await loadState();
        const comment = findComment(state.comments, comment_id, remark_id);

        if (!comment) {
            const idDesc = comment_id ? comment_id : `#R-${remark_id}`;
            return errorResult(`Comment not found: ${idDesc}`);
        }
        // ... rest of handler unchanged, but add remarkID to output:
        lines.push(`Remark ID: #R-${comment.remarkID}`);
```

**Step 3: Update `remarc_resolve` input schema and handler**

Change the input schema (lines 223-228):

```typescript
inputSchema: {
    comment_id: z.string().optional().describe("The UUID of the comment. Provide either this or remark_id."),
    remark_id: z.number().optional().describe("The Remark ID number (#R-N). Provide either this or comment_id."),
    summary: z.string().describe("A brief summary of how/why the comment was resolved."),
},
```

Update the handler (line 229):

```typescript
}, async ({ comment_id, remark_id, summary }) => {
    try {
        const state = await loadState();
        const comment = findComment(state.comments, comment_id, remark_id);

        if (!comment) {
            const idDesc = comment_id ? comment_id : `#R-${remark_id}`;
            return errorResult(`Comment not found: ${idDesc}`);
        }
        // ... rest unchanged
```

**Step 4: Update `remarc_reopen` input schema and handler**

Same pattern as resolve:

```typescript
inputSchema: {
    comment_id: z.string().optional().describe("The UUID of the comment. Provide either this or remark_id."),
    remark_id: z.number().optional().describe("The Remark ID number (#R-N). Provide either this or comment_id."),
},
```

Update handler similarly.

**Step 5: Add remarkID to `formatCommentLine`**

In `formatCommentLine` (lines 44-71), add the remarkID to the output:

```typescript
// After line 56 (ID line):
lines.push(`  ID: ${comment.id}`);
if (comment.remarkID > 0) {
    lines.push(`  Remark ID: #R-${comment.remarkID}`);
}
```

**Step 6: Build MCP to verify**

Run: `cd mcp && npm run build 2>&1 | tail -5`
Expected: No errors

**Step 7: Commit**

```
feat(mcp): accept remark_id as alternative to UUID in all tools
```

---

### Task 11: Update MCP server description with remark ID instructions

**Files:**
- Modify: `mcp/src/index.ts`

**Step 1: Add server instructions**

When creating the McpServer (lines 5-8), check if the SDK supports a `description` or `instructions` field. If so, add:

```typescript
const server = new McpServer({
    name: "remarc",
    version: "0.1.0",
    instructions: "Remarc is a macOS app for contextual comments on text selections. Comments have human-friendly Remark IDs (#R-N). When users paste Remarc comments into chat, look for these IDs and use them to track and update comment status as you address each one. Call remarc_resolve with the remark_id and a brief summary of what you did.",
});
```

If the SDK doesn't support `instructions` on McpServer, update the tool descriptions instead to mention remark_id usage.

**Step 2: Update tool descriptions to mention remark_id**

Update each tool's description string to mention that remark_id can be used:

- `remarc_resolve`: `'Resolve a comment by setting its status to "resolved" with a summary. Accepts either comment_id (UUID) or remark_id (#R-N number). Writes the change and notifies Remarc to reload.'`
- `remarc_reopen`: `'Reopen a resolved comment. Accepts either comment_id (UUID) or remark_id (#R-N number). Writes the change and notifies Remarc to reload.'`
- `remarc_get_comment`: `'Get full details of a single comment. Accepts either comment_id (UUID) or remark_id (#R-N number).'`

**Step 3: Build MCP to verify**

Run: `cd mcp && npm run build 2>&1 | tail -5`
Expected: No errors

**Step 4: Commit**

```
feat(mcp): add server instructions for remark ID workflow
```

---

### Task 12: Final integration build and manual verification

**Step 1: Clean build the app**

```bash
cd app && xcodebuild clean && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug
```

**Step 2: Kill and relaunch**

Kill running Remarc and launch new build.

**Step 3: Manual verification checklist**

- [ ] Create a new comment — verify it gets a remarkID shown in metadata (`#R-N`)
- [ ] Copy a single comment — verify `#R-N` appears in metadata line of pasted text
- [ ] Copy all comments — verify each has `#R-N` and AI hint footer appears
- [ ] Open Preferences > Export — verify "Remark ID" and "AI hint" toggles appear
- [ ] Toggle "Remark ID" off — verify ID disappears from export preview
- [ ] Check settings for total remarks counter display
- [ ] Rebuild MCP server and test `remarc_resolve` with `remark_id` parameter

**Step 4: Final commit**

If any fixes were needed during verification, commit them:

```
fix: address integration issues from remark ID system
```
