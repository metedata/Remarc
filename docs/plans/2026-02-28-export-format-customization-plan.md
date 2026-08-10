# Export Format Customization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Let users customize how "Copy All" formats their comments as markdown — reference style, numbering, dividers, date format, and which metadata fields are included — with a live preview in the Export settings tab.

**Architecture:** Add new enums + settings to `SettingsManager`, refactor `ExportManager.markdownForSession` to read those settings, redesign the Export tab in `PreferencesView` as a two-column layout (controls left, live preview right), and widen the preferences window from 480pt to 640pt.

**Tech Stack:** SwiftUI, UserDefaults, Swift Testing

---

### Task 1: Add Export Format Enums to SettingsManager

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift`

**Step 1: Add the four new enums after the existing `SelectionDetectionMode` enum (line ~181)**

```swift
public enum ReferenceStyle: String, CaseIterable, Sendable {
    case blockquote
    case rePrefix
    case quoted

    public var label: String {
        switch self {
        case .blockquote: return "> Blockquote"
        case .rePrefix: return "Re: Prefix"
        case .quoted: return "\"Quoted\""
        }
    }
}

public enum NumberingStyle: String, CaseIterable, Sendable {
    case numbered
    case bulleted
    case none

    public var label: String {
        switch self {
        case .numbered: return "Numbered"
        case .bulleted: return "Bulleted"
        case .none: return "None"
        }
    }
}

public enum DividerStyle: String, CaseIterable, Sendable {
    case horizontalRule
    case blankLine

    public var label: String {
        switch self {
        case .horizontalRule: return "Horizontal Rule"
        case .blankLine: return "Blank Line"
        }
    }
}

public enum ExportDateFormat: String, CaseIterable, Sendable {
    case short
    case iso
    case relative

    public var label: String {
        switch self {
        case .short: return "Short (Feb 28)"
        case .iso: return "ISO (2026-02-28)"
        case .relative: return "Relative (2d ago)"
        }
    }
}
```

**Step 2: Add UserDefaults keys inside the `Keys` enum (after line 25)**

```swift
static let referenceStyle = "referenceStyle"
static let numberingStyle = "numberingStyle"
static let dividerStyle = "dividerStyle"
static let exportDateFormat = "exportDateFormat"
static let includeSource = "includeSource"
static let includeDate = "includeDate"
static let includeStatus = "includeStatus"
```

**Step 3: Add published properties (after `autoClearAfterExport`, line ~74)**

```swift
@Published public var referenceStyle: ReferenceStyle {
    didSet { defaults.set(referenceStyle.rawValue, forKey: Keys.referenceStyle) }
}

@Published public var numberingStyle: NumberingStyle {
    didSet { defaults.set(numberingStyle.rawValue, forKey: Keys.numberingStyle) }
}

@Published public var dividerStyle: DividerStyle {
    didSet { defaults.set(dividerStyle.rawValue, forKey: Keys.dividerStyle) }
}

@Published public var exportDateFormat: ExportDateFormat {
    didSet { defaults.set(exportDateFormat.rawValue, forKey: Keys.exportDateFormat) }
}

@Published public var includeSource: Bool {
    didSet { defaults.set(includeSource, forKey: Keys.includeSource) }
}

@Published public var includeDate: Bool {
    didSet { defaults.set(includeDate, forKey: Keys.includeDate) }
}

@Published public var includeStatus: Bool {
    didSet { defaults.set(includeStatus, forKey: Keys.includeStatus) }
}
```

**Step 4: Initialize the new properties in `init()` (after line ~131, before `excludedAppBundleIDs`)**

```swift
if let saved = defaults.string(forKey: Keys.referenceStyle),
   let style = ReferenceStyle(rawValue: saved) {
    self.referenceStyle = style
} else {
    self.referenceStyle = .blockquote
}

if let saved = defaults.string(forKey: Keys.numberingStyle),
   let style = NumberingStyle(rawValue: saved) {
    self.numberingStyle = style
} else {
    self.numberingStyle = .numbered
}

if let saved = defaults.string(forKey: Keys.dividerStyle),
   let style = DividerStyle(rawValue: saved) {
    self.dividerStyle = style
} else {
    self.dividerStyle = .blankLine
}

if let saved = defaults.string(forKey: Keys.exportDateFormat),
   let fmt = ExportDateFormat(rawValue: saved) {
    self.exportDateFormat = fmt
} else {
    self.exportDateFormat = .short
}

// Migration: if old includeMetadataInExport was explicitly set, use it for includeSource/includeDate
if defaults.object(forKey: Keys.includeSource) != nil {
    self.includeSource = defaults.bool(forKey: Keys.includeSource)
} else {
    self.includeSource = self.includeMetadataInExport
}

if defaults.object(forKey: Keys.includeDate) != nil {
    self.includeDate = defaults.bool(forKey: Keys.includeDate)
} else {
    self.includeDate = self.includeMetadataInExport
}

if defaults.object(forKey: Keys.includeStatus) != nil {
    self.includeStatus = defaults.bool(forKey: Keys.includeStatus)
} else {
    self.includeStatus = false
}
```

**Step 5: Build and verify**

Run: `cd /Users/metepolat/Developer/Remarc/app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/SettingsManager.swift
git commit -m "feat: add export format settings (reference style, numbering, dividers, date format, metadata toggles)"
```

---

### Task 2: Refactor ExportManager Markdown Formatting

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift`

**Step 1: Write tests for the new formatting logic**

Create: `app/RemarcPackage/Tests/RemarcFeatureTests/ExportFormatTests.swift`

```swift
import Testing
import Foundation
@testable import RemarcFeature

// Helper to create test comments without needing @MainActor SettingsManager
private func makeComment(
    text: String = "Hello world",
    comment: String = "My note",
    source: String = "VS Code",
    status: CommentStatus = .open,
    createdAt: Date = Date(timeIntervalSince1970: 1772265600) // 2026-02-28
) -> Comment {
    Comment(
        reference: .textSelection(text: text),
        commentText: comment,
        source: source,
        appBundleID: nil,
        createdAt: createdAt,
        sessionID: UUID(),
        status: status
    )
}

private func makeScreenshotComment(
    imagePath: String = "/path/to/screenshot.png",
    comment: String = "Screenshot note",
    source: String = "Figma"
) -> Comment {
    Comment(
        reference: .screenshot(imagePath: imagePath),
        commentText: comment,
        source: source,
        appBundleID: nil,
        sessionID: UUID()
    )
}

private func makeQuickNote(comment: String = "A quick note") -> Comment {
    Comment(
        reference: .quickNote,
        commentText: comment,
        source: "Remarc",
        appBundleID: nil,
        sessionID: UUID()
    )
}

@Suite("Export Format Tests")
struct ExportFormatTests {

    @Test("Blockquote reference style")
    @MainActor func blockquoteStyle() {
        let comment = makeComment(text: "Selected text", comment: "My comment")
        let result = ExportManager.shared.formatReference(comment, style: .blockquote)
        #expect(result == "> Selected text")
    }

    @Test("Re: prefix reference style")
    @MainActor func rePrefixStyle() {
        let comment = makeComment(text: "Selected text", comment: "My comment")
        let result = ExportManager.shared.formatReference(comment, style: .rePrefix)
        #expect(result == "Re: Selected text")
    }

    @Test("Quoted reference style")
    @MainActor func quotedStyle() {
        let comment = makeComment(text: "Selected text", comment: "My comment")
        let result = ExportManager.shared.formatReference(comment, style: .quoted)
        #expect(result == "\"Selected text\"")
    }

    @Test("Numbered style")
    @MainActor func numberedStyle() {
        let result = ExportManager.shared.formatPrefix(index: 0, style: .numbered)
        #expect(result == "1. ")
    }

    @Test("Bulleted style")
    @MainActor func bulletedStyle() {
        let result = ExportManager.shared.formatPrefix(index: 0, style: .bulleted)
        #expect(result == "- ")
    }

    @Test("No prefix style")
    @MainActor func noPrefixStyle() {
        let result = ExportManager.shared.formatPrefix(index: 0, style: .none)
        #expect(result == "")
    }

    @Test("Short date format")
    @MainActor func shortDateFormat() {
        let date = Date(timeIntervalSince1970: 1772265600) // 2026-02-28
        let result = ExportManager.shared.formatDate(date, format: .short)
        #expect(result.contains("Feb"))
        #expect(result.contains("28"))
    }

    @Test("ISO date format")
    @MainActor func isoDateFormat() {
        let date = Date(timeIntervalSince1970: 1772265600)
        let result = ExportManager.shared.formatDate(date, format: .iso)
        #expect(result == "2026-02-28")
    }

    @Test("Metadata line with source and date")
    @MainActor func metadataLineSourceAndDate() {
        let comment = makeComment(source: "Safari")
        let result = ExportManager.shared.formatMetadataLine(
            comment,
            includeSource: true,
            includeDate: true,
            includeStatus: false,
            dateFormat: .short
        )
        #expect(result.contains("Safari"))
        #expect(result.contains("Feb"))
    }

    @Test("Metadata line with status")
    @MainActor func metadataLineWithStatus() {
        let comment = makeComment(source: "Safari", status: .resolved)
        let result = ExportManager.shared.formatMetadataLine(
            comment,
            includeSource: true,
            includeDate: false,
            includeStatus: true,
            dateFormat: .short
        )
        #expect(result.contains("Resolved"))
    }

    @Test("Empty metadata line returns nil")
    @MainActor func emptyMetadataLine() {
        let comment = makeComment()
        let result = ExportManager.shared.formatMetadataLine(
            comment,
            includeSource: false,
            includeDate: false,
            includeStatus: false,
            dateFormat: .short
        )
        #expect(result == nil)
    }

    @Test("Screenshot comment reference")
    @MainActor func screenshotReference() {
        let comment = makeScreenshotComment()
        let result = ExportManager.shared.formatReference(comment, style: .blockquote)
        #expect(result == "![screenshot](/path/to/screenshot.png)")
    }

    @Test("Quick note reference")
    @MainActor func quickNoteReference() {
        let comment = makeQuickNote()
        let result = ExportManager.shared.formatReference(comment, style: .blockquote)
        #expect(result == nil)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/metepolat/Developer/Remarc/app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -only-testing RemarcFeatureTests/ExportFormatTests -quiet 2>&1 | tail -10`
Expected: FAIL — `formatReference`, `formatPrefix`, `formatDate`, `formatMetadataLine` don't exist yet

**Step 3: Add the formatting helper methods to ExportManager**

Add these public helper methods to `ExportManager` (before `markdownForSession`):

```swift
// MARK: - Formatting Helpers

/// Format a comment's reference text according to the chosen style.
/// Returns nil for quick notes (no reference to show).
public func formatReference(_ comment: Comment, style: SettingsManager.ReferenceStyle) -> String? {
    switch comment.reference {
    case .textSelection(let text):
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch style {
        case .blockquote:
            return cleaned.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
        case .rePrefix:
            let oneLine = cleaned.replacingOccurrences(of: "\n", with: " ")
            return "Re: \(oneLine)"
        case .quoted:
            let oneLine = cleaned.replacingOccurrences(of: "\n", with: " ")
            return "\"\(oneLine)\""
        }
    case .screenshot(let imagePath):
        return "![screenshot](\(imagePath))"
    case .quickNote:
        return nil
    }
}

/// Format the prefix for a comment at the given index.
public func formatPrefix(index: Int, style: SettingsManager.NumberingStyle) -> String {
    switch style {
    case .numbered: return "\(index + 1). "
    case .bulleted: return "- "
    case .none: return ""
    }
}

/// Format a date according to the chosen format.
public func formatDate(_ date: Date, format: SettingsManager.ExportDateFormat) -> String {
    switch format {
    case .short:
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    case .iso:
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    case .relative:
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Build the metadata line (e.g. "_Source: VS Code | Feb 28 | Open_").
/// Returns nil if no metadata fields are enabled.
public func formatMetadataLine(
    _ comment: Comment,
    includeSource: Bool,
    includeDate: Bool,
    includeStatus: Bool,
    dateFormat: SettingsManager.ExportDateFormat
) -> String? {
    var parts: [String] = []
    if includeSource {
        parts.append("Source: \(comment.source)")
    }
    if includeDate {
        parts.append(formatDate(comment.createdAt, format: dateFormat))
    }
    if includeStatus {
        parts.append(comment.status == .open ? "Open" : "Resolved")
    }
    guard !parts.isEmpty else { return nil }
    return "_\(parts.joined(separator: " | "))_"
}
```

**Step 4: Run tests to verify they pass**

Run: `cd /Users/metepolat/Developer/Remarc/app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -only-testing RemarcFeatureTests/ExportFormatTests -quiet 2>&1 | tail -10`
Expected: All tests PASS

**Step 5: Refactor `markdownForSession` to use the new helpers and settings**

Replace the current `markdownForSession` method (lines 11-57) with:

```swift
public func markdownForSession(_ session: Session, comments: [Comment], includeMetadata: Bool) -> String {
    let settings = SettingsManager.shared
    return markdownForComments(
        comments,
        referenceStyle: settings.referenceStyle,
        numberingStyle: settings.numberingStyle,
        dividerStyle: settings.dividerStyle,
        dateFormat: settings.exportDateFormat,
        includeSource: settings.includeSource,
        includeDate: settings.includeDate,
        includeStatus: settings.includeStatus
    )
}

/// Core formatting method used by both real export and preview.
public func markdownForComments(
    _ comments: [Comment],
    referenceStyle: SettingsManager.ReferenceStyle,
    numberingStyle: SettingsManager.NumberingStyle,
    dividerStyle: SettingsManager.DividerStyle,
    dateFormat: SettingsManager.ExportDateFormat,
    includeSource: Bool,
    includeDate: Bool,
    includeStatus: Bool
) -> String {
    var lines: [String] = []

    for (index, comment) in comments.enumerated() {
        let prefix = formatPrefix(index: index, style: numberingStyle)
        let reference = formatReference(comment, style: referenceStyle)

        if let reference {
            lines.append("\(prefix)\(reference)")
        }

        // Indent comment text if using numbered/bulleted prefix
        let indent = numberingStyle != .none ? String(repeating: " ", count: prefix.count) : ""
        let commentLine = "\(indent)\(comment.commentText)"
        lines.append(commentLine)

        // Attachments
        for attachment in comment.attachments {
            lines.append("\(indent)![attachment](\(attachment))")
        }

        // Metadata line
        if let metadataLine = formatMetadataLine(
            comment,
            includeSource: includeSource,
            includeDate: includeDate,
            includeStatus: includeStatus,
            dateFormat: dateFormat
        ) {
            lines.append("\(indent)\(metadataLine)")
        }

        // Divider (not after last comment)
        if index < comments.count - 1 {
            switch dividerStyle {
            case .horizontalRule:
                lines.append("")
                lines.append("---")
                lines.append("")
            case .blankLine:
                lines.append("")
            }
        }
    }

    return lines.joined(separator: "\n")
}
```

**Step 6: Refactor `markdownForComment` (single comment copy) to also use the new settings**

Replace the current `markdownForComment` method (lines 114-138) with:

```swift
public func markdownForComment(_ comment: Comment) -> String {
    let settings = SettingsManager.shared
    return markdownForComments(
        [comment],
        referenceStyle: settings.referenceStyle,
        numberingStyle: .none,  // Single comment: no numbering
        dividerStyle: .blankLine,
        dateFormat: settings.exportDateFormat,
        includeSource: settings.includeSource,
        includeDate: settings.includeDate,
        includeStatus: settings.includeStatus
    )
}
```

**Step 7: Build and run all tests**

Run: `cd /Users/metepolat/Developer/Remarc/app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -quiet 2>&1 | tail -10`
Expected: BUILD SUCCEEDED, all tests pass

**Step 8: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift app/RemarcPackage/Tests/RemarcFeatureTests/ExportFormatTests.swift
git commit -m "feat: refactor ExportManager to use configurable format settings with tests"
```

---

### Task 3: Add Preview Markdown Generator

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift`

**Step 1: Add a preview method that uses hardcoded sample data**

Add after the `markdownForComment` method:

```swift
// MARK: - Preview

/// Generate sample markdown for the settings preview panel.
public func previewMarkdown(
    referenceStyle: SettingsManager.ReferenceStyle,
    numberingStyle: SettingsManager.NumberingStyle,
    dividerStyle: SettingsManager.DividerStyle,
    dateFormat: SettingsManager.ExportDateFormat,
    includeSource: Bool,
    includeDate: Bool,
    includeStatus: Bool
) -> String {
    let sampleComments = [
        Comment(
            reference: .textSelection(text: "Lorem ipsum dolor sit amet, consectetur adipiscing elit"),
            commentText: "This is a sample comment.",
            source: "TextEdit",
            appBundleID: nil,
            createdAt: Date(),
            sessionID: UUID(),
            status: .open
        ),
        Comment(
            reference: .textSelection(text: "Sed do eiusmod tempor incididunt"),
            commentText: "Another comment here.",
            source: "Safari",
            appBundleID: nil,
            createdAt: Date().addingTimeInterval(-86400),
            sessionID: UUID(),
            status: .resolved
        ),
    ]

    return markdownForComments(
        sampleComments,
        referenceStyle: referenceStyle,
        numberingStyle: numberingStyle,
        dividerStyle: dividerStyle,
        dateFormat: dateFormat,
        includeSource: includeSource,
        includeDate: includeDate,
        includeStatus: includeStatus
    )
}
```

**Step 2: Build**

Run: `cd /Users/metepolat/Developer/Remarc/app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift
git commit -m "feat: add preview markdown generator for settings panel"
```

---

### Task 4: Redesign Export Tab in PreferencesView

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift`

**Step 1: Widen the preferences window from 480 to 640**

Change line 22 in `createWindow()`:
```swift
// Old:
contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
// New:
contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
```

**Step 2: Replace the `exportTab` computed property with the new two-column layout**

Replace the current `exportTab` (lines 172-181) with:

```swift
private var exportTab: some View {
    HStack(alignment: .top, spacing: 16) {
        // Left column: controls
        VStack(alignment: .leading, spacing: 16) {
            // Clipboard Format section
            VStack(alignment: .leading, spacing: 8) {
                Text("Clipboard Format")
                    .font(.system(size: 12, weight: .semibold))

                LabeledContent("Reference style") {
                    Picker("", selection: $settings.referenceStyle) {
                        ForEach(SettingsManager.ReferenceStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                .font(.system(size: 12))

                LabeledContent("Numbering") {
                    Picker("", selection: $settings.numberingStyle) {
                        ForEach(SettingsManager.NumberingStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                .font(.system(size: 12))

                LabeledContent("Dividers") {
                    Picker("", selection: $settings.dividerStyle) {
                        ForEach(SettingsManager.DividerStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                .font(.system(size: 12))

                LabeledContent("Date format") {
                    Picker("", selection: $settings.exportDateFormat) {
                        ForEach(SettingsManager.ExportDateFormat.allCases, id: \.self) { fmt in
                            Text(fmt.label).tag(fmt)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                .font(.system(size: 12))
            }

            Divider()

            // Metadata toggles
            VStack(alignment: .leading, spacing: 6) {
                Text("Include in Export")
                    .font(.system(size: 12, weight: .semibold))

                Toggle("Source app", isOn: $settings.includeSource)
                    .font(.system(size: 12))
                Toggle("Date", isOn: $settings.includeDate)
                    .font(.system(size: 12))
                Toggle("Status (open / resolved)", isOn: $settings.includeStatus)
                    .font(.system(size: 12))
            }

            Divider()

            // File export format
            VStack(alignment: .leading, spacing: 6) {
                Text("File Export")
                    .font(.system(size: 12, weight: .semibold))

                LabeledContent("Default format") {
                    Picker("", selection: $settings.outputFormat) {
                        ForEach(SettingsManager.OutputFormat.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
                .font(.system(size: 12))
            }

            Spacer()
        }
        .frame(width: 260)

        // Right column: live preview
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.system(size: 12, weight: .semibold))

            ScrollView {
                Text(exportPreviewText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
}

private var exportPreviewText: String {
    ExportManager.shared.previewMarkdown(
        referenceStyle: settings.referenceStyle,
        numberingStyle: settings.numberingStyle,
        dividerStyle: settings.dividerStyle,
        dateFormat: settings.exportDateFormat,
        includeSource: settings.includeSource,
        includeDate: settings.includeDate,
        includeStatus: settings.includeStatus
    )
}
```

**Step 3: Build, kill, and relaunch**

Run: `cd /Users/metepolat/Developer/Remarc/app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | grep -oE '/Users/[^ ]*DerivedData/Remarc-[^/]+' | head -1`
Then: `pkill -x Remarc || true && open <derived_path>/Build/Products/Debug/Remarc.app`
Verify: Open Preferences → Export tab should show two-column layout with live preview

**Step 4: Commit**

```bash
git add app/RemarcPackage/Sources/RemarcFeature/Views/PreferencesWindowController.swift
git commit -m "feat: redesign Export settings tab with two-column layout and live preview"
```

---

### Task 5: Update copyAll to Remove Hardcoded Format

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Views/PopoverContentView.swift`

**Step 1: The `copyAll()` function currently hardcodes `.markdown` format. It should continue using markdown (since clipboard copy is always markdown per design), but this is already correct. No change needed to the format parameter.**

The `copyAll()` function at line ~475 already calls:
```swift
ExportManager.shared.copySessionToClipboard(session, comments: allComments, format: .markdown)
```

This is correct — clipboard copy is always markdown. The `markdownForSession` method now reads the new settings internally, so no changes needed to `PopoverContentView`.

**Step 2: Verify by building and testing Copy All**

Run: `cd /Users/metepolat/Developer/Remarc/app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

Verify manually: Change export settings in Preferences → Export, then use Copy All → paste into a text editor → confirm format matches the settings.

**Step 3: Commit (only if any changes were needed)**

No commit needed if no changes were made.

---

### Task 6: Clean Up Old includeMetadataInExport Usage

**Files:**
- Modify: `app/RemarcPackage/Sources/RemarcFeature/Services/ExportManager.swift`

**Step 1: The `markdownForSession` method now ignores the `includeMetadata` parameter (it reads settings directly). The `includeMetadata` parameter on `markdownForSession` is still passed by `copySessionToClipboard` and `saveSessionToFile`. Since the new implementation reads settings directly, the parameter is now vestigial.**

Update `markdownForSession` signature to keep backward compatibility but the parameter is unused internally (the method already reads from SettingsManager directly). This is fine — the JSON export path still uses `includeMetadata` for the session wrapper, so we keep the parameter for JSON but the markdown path ignores it.

Verify the `copySessionToClipboard` method still works correctly:
- The `.markdown` case calls `markdownForSession` which reads settings internally ✓
- The `.json` case calls `jsonForSession` which uses `includeMetadata` for the wrapper ✓

**Step 2: Build and run tests**

Run: `cd /Users/metepolat/Developer/Remarc/app && xcodebuild test -workspace Remarc.xcworkspace -scheme RemarcFeature -quiet 2>&1 | tail -10`
Expected: All tests pass

**Step 3: Final build, kill, and relaunch for manual verification**

Run build without `-quiet` to get DerivedData path:
```bash
cd /Users/metepolat/Developer/Remarc/app && xcodebuild build -workspace Remarc.xcworkspace -scheme Remarc -configuration Debug 2>&1 | grep -oE '/Users/[^ ]*DerivedData/Remarc-[^/]+' | head -1
```
Then:
```bash
pkill -x Remarc || true
open <derived_path>/Build/Products/Debug/Remarc.app
```

Manual verification checklist:
- [ ] Preferences → Export tab shows two-column layout
- [ ] Changing Reference style updates preview instantly
- [ ] Changing Numbering updates preview instantly
- [ ] Changing Dividers updates preview instantly
- [ ] Changing Date format updates preview instantly
- [ ] Toggling Source/Date/Status updates preview
- [ ] Copy All respects the chosen settings
- [ ] Single comment copy respects reference style and metadata
- [ ] File Export format picker still works

**Step 4: Commit**

```bash
git add -A
git commit -m "chore: clean up export format integration"
```
