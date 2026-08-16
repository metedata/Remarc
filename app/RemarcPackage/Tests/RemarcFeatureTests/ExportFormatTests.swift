import Testing
import Foundation
@testable import RemarcFeature

// Disambiguate from Testing.Comment
private typealias AppComment = RemarcFeature.Comment

// Helper to create test comments without needing @MainActor SettingsManager
private func makeComment(
    text: String = "Hello world",
    comment: String = "My note",
    source: String = "VS Code",
    status: CommentStatus = .open,
    createdAt: Date = Date(timeIntervalSince1970: 1772265600) // 2026-02-28
) -> AppComment {
    AppComment(
        type: .comment(text: text),
        commentText: comment,
        source: source,
        appBundleID: nil,
        createdAt: createdAt,
        sessionID: UUID(),
        status: status
    )
}

private func makeScreenshotComment(
    imagePath: String = "images/screenshot.png",
    comment: String = "Screenshot note",
    source: String = "Figma"
) -> AppComment {
    AppComment(
        type: .screenshot(imagePath: imagePath),
        commentText: comment,
        source: source,
        appBundleID: nil,
        sessionID: UUID()
    )
}

private func makeQuickNote(comment: String = "A quick note") -> AppComment {
    AppComment(
        type: .quickNote,
        commentText: comment,
        source: "Remarc",
        appBundleID: nil,
        sessionID: UUID()
    )
}

@MainActor
private func renderMarkdown(_ comments: [AppComment]) -> String {
    ExportManager.shared.markdownForComments(
        comments,
        referenceStyle: .blockquote,
        numberingStyle: .none,
        commentPrefixStyle: .comment,
        dividerStyle: .horizontalRule,
        dateFormat: .iso,
        includeRemarkID: false,
        includeSource: false,
        includeDate: false,
        includeStatus: false,
        includeType: false
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
        let result = ExportManager.shared.formatPrefix(index: 0, style: SettingsManager.NumberingStyle.none)
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
            includeRemarkID: false,
            includeSource: true,
            includeDate: true,
            includeStatus: false,
            includeType: false,
            dateFormat: .short
        )
        #expect(result != nil)
        #expect(result!.contains("Safari"))
        #expect(result!.contains("Feb"))
    }

    @Test("Metadata line with status")
    @MainActor func metadataLineWithStatus() {
        let comment = makeComment(source: "Safari", status: .resolved)
        let result = ExportManager.shared.formatMetadataLine(
            comment,
            includeRemarkID: false,
            includeSource: true,
            includeDate: false,
            includeStatus: true,
            includeType: false,
            dateFormat: .short
        )
        #expect(result != nil)
        #expect(result!.contains("Resolved"))
    }

    @Test("Empty metadata line returns nil")
    @MainActor func emptyMetadataLine() {
        let comment = makeComment()
        let result = ExportManager.shared.formatMetadataLine(
            comment,
            includeRemarkID: false,
            includeSource: false,
            includeDate: false,
            includeStatus: false,
            includeType: false,
            dateFormat: .short
        )
        #expect(result == nil)
    }

    @Test("Screenshot comment reference")
    @MainActor func screenshotReference() {
        let comment = makeScreenshotComment()
        let result = ExportManager.shared.formatReference(comment, style: .blockquote)
        let expectedPath = resolveImagePath("images/screenshot.png").path
        #expect(result == "![screenshot](\(expectedPath))")
    }

    @Test("Quick note reference")
    @MainActor func quickNoteReference() {
        let comment = makeQuickNote()
        let result = ExportManager.shared.formatReference(comment, style: .blockquote)
        #expect(result == nil)
    }

    @Test("Context-only comments export their reference without a dangling body prefix")
    @MainActor func contextOnlyMarkdown() {
        let comment = makeComment(text: "Selected text", comment: "  \n")

        let result = renderMarkdown([comment])

        #expect(result == "> Selected text")
        #expect(!result.contains("Comment:"))
    }

    @Test("JSON retains context-only comments with an empty String body")
    @MainActor func contextOnlyJSON() throws {
        let session = Session(name: "Export")
        let contextOnly = AppComment(
            type: .comment(text: "Selected text"),
            commentText: " \n",
            source: "Xcode",
            appBundleID: nil,
            sessionID: session.id
        )
        let quickNote = AppComment(
            type: .quickNote,
            commentText: "Keep me",
            source: "Remarc",
            appBundleID: nil,
            sessionID: session.id
        )

        let result = ExportManager.shared.jsonForSession(
            session,
            comments: [contextOnly, quickNote],
            includeMetadata: false
        )
        let data = try #require(result.data(using: .utf8))
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(objects.count == 2)
        #expect(objects[0]["comment"] as? String == "")
        #expect(objects[0]["selectedText"] as? String == "Selected text")
        #expect(objects[1]["comment"] as? String == "Keep me")
    }

    @Test("JSON retains screenshot and web-element references when their bodies are empty")
    @MainActor func contextOnlyStructuredReferencesInJSON() throws {
        let session = Session(name: "Export")
        let screenshot = AppComment(
            type: .screenshot(imagePath: "images/capture.png"),
            commentText: "",
            source: "Screenshot",
            appBundleID: nil,
            sessionID: session.id
        )
        let webElement = AppComment(
            type: .webElement(componentName: nil, filePath: "Views/Editor.swift"),
            commentText: " \n",
            source: "Web Element",
            appBundleID: nil,
            sessionID: session.id
        )

        let result = ExportManager.shared.jsonForSession(
            session,
            comments: [screenshot, webElement],
            includeMetadata: false
        )
        let data = try #require(result.data(using: .utf8))
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        #expect(objects.count == 2)
        #expect((objects[0]["imagePath"] as? String)?.hasSuffix("/images/capture.png") == true)
        #expect(objects[0]["comment"] as? String == "")
        #expect(objects[1]["filePath"] as? String == "Views/Editor.swift")
        #expect(objects[1]["componentName"] == nil)
        #expect(objects[1]["comment"] as? String == "")
        #expect(objects[1]["type"] as? String == "webElement")
    }

    @Test("Legacy payloadless records still have a Markdown marker")
    @MainActor func payloadlessLegacyMarkdownFallback() {
        let legacyCrit = AppComment(
            type: .critMode,
            commentText: "",
            source: "Remarc",
            appBundleID: nil,
            sessionID: UUID()
        )

        #expect(renderMarkdown([legacyCrit]) == "[Crit Mode]")
    }

    @Test("Export receipt skips edited, moved, restored, and newly-created comments")
    func receiptGenerationContract() {
        let sessionID = UUID()
        let exportedAt = Date(timeIntervalSince1970: 1_000)
        let edited = AppComment(
            type: .comment(text: "Edited"),
            commentText: "Before",
            source: "Xcode",
            appBundleID: nil,
            updatedAt: exportedAt,
            sessionID: sessionID
        )
        let moved = AppComment(
            type: .comment(text: "Moved"),
            commentText: "Before",
            source: "Xcode",
            appBundleID: nil,
            updatedAt: exportedAt,
            sessionID: sessionID
        )
        let unchanged = AppComment(
            type: .comment(text: "Unchanged"),
            commentText: "Before",
            source: "Xcode",
            appBundleID: nil,
            updatedAt: exportedAt,
            sessionID: sessionID
        )
        let restored = AppComment(
            type: .comment(text: "Restored"),
            commentText: "Before",
            source: "Xcode",
            appBundleID: nil,
            updatedAt: exportedAt,
            sessionID: sessionID
        )
        let receipt = ExportReceipt(
            sessionID: sessionID,
            comments: [edited, moved, unchanged, restored]
        )

        var editedAfterExport = edited
        editedAfterExport.commentText = "After"
        editedAfterExport.updatedAt = exportedAt.addingTimeInterval(1)
        var movedAfterExport = moved
        movedAfterExport.sessionID = UUID()
        movedAfterExport.updatedAt = exportedAt.addingTimeInterval(1)
        // Soft-delete followed by restore returns to active state, but both
        // transitions advance updatedAt so the old receipt must not clear it.
        var restoredAfterExport = restored
        restoredAfterExport.isDeleted = false
        restoredAfterExport.deletedAt = nil
        restoredAfterExport.updatedAt = exportedAt.addingTimeInterval(2)
        let createdAfterExport = AppComment(
            type: .quickNote,
            commentText: "New",
            source: "Remarc",
            appBundleID: nil,
            updatedAt: exportedAt.addingTimeInterval(2),
            sessionID: sessionID
        )

        let clearable = receipt.clearableCommentIDs(
            in: [editedAfterExport, movedAfterExport, unchanged, restoredAfterExport, createdAfterExport]
        )

        #expect(clearable == [unchanged.id])
        #expect(receipt.commentIDs == [edited.id, moved.id, unchanged.id, restored.id])
    }

    @Test("Short date format with time")
    @MainActor func shortDateFormatWithTime() {
        let date = Date(timeIntervalSince1970: 1772265600) // 2026-02-28
        let result = ExportManager.shared.formatDate(date, format: .short, includeTime: true)
        #expect(result.contains("Feb"))
        #expect(result.contains("28"))
        #expect(result.contains(":"))
    }

    @Test("ISO date format with time")
    @MainActor func isoDateFormatWithTime() {
        let date = Date(timeIntervalSince1970: 1772265600)
        let result = ExportManager.shared.formatDate(date, format: .iso, includeTime: true)
        #expect(result.hasPrefix("2026-02-28"))
        #expect(result.contains(":"))
    }

    @Test("Medium date format")
    @MainActor func mediumDateFormat() {
        let date = Date(timeIntervalSince1970: 1772265600)
        let result = ExportManager.shared.formatDate(date, format: .medium)
        #expect(result.contains("Feb"))
        #expect(result.contains("28"))
        #expect(result.contains("2026"))
    }

    @Test("Long date format")
    @MainActor func longDateFormat() {
        let date = Date(timeIntervalSince1970: 1772265600)
        let result = ExportManager.shared.formatDate(date, format: .long)
        #expect(result.contains("February"))
        #expect(result.contains("28"))
        #expect(result.contains("2026"))
    }

    @Test("European date format")
    @MainActor func europeanDateFormat() {
        let date = Date(timeIntervalSince1970: 1772265600)
        let result = ExportManager.shared.formatDate(date, format: .european)
        #expect(result.contains("28/02/2026"))
    }

    @Test("Short date format with 24-hour time")
    @MainActor func shortDateFormat24Hour() {
        let date = Date(timeIntervalSince1970: 1772265600)
        let result = ExportManager.shared.formatDate(date, format: .short, includeTime: true, use24Hour: true)
        #expect(result.contains("Feb"))
        #expect(result.contains(":"))
        // Should NOT contain AM/PM
        #expect(!result.contains("AM") && !result.contains("PM"))
    }

    @Test("ISO always uses 24h regardless of use24Hour flag")
    @MainActor func isoAlways24Hour() {
        let date = Date(timeIntervalSince1970: 1772265600)
        let result = ExportManager.shared.formatDate(date, format: .iso, includeTime: true, use24Hour: false)
        #expect(result.hasPrefix("2026-02-28"))
        // ISO never has AM/PM
        #expect(!result.contains("AM") && !result.contains("PM"))
    }

    @Test("Medium date format with time")
    @MainActor func mediumDateFormatWithTime() {
        let date = Date(timeIntervalSince1970: 1772265600)
        let result = ExportManager.shared.formatDate(date, format: .medium, includeTime: true)
        #expect(result.contains("Feb"))
        #expect(result.contains("2026"))
        #expect(result.contains(":"))
    }

    @Test("European date format with 24h time")
    @MainActor func europeanDateFormat24Hour() {
        let date = Date(timeIntervalSince1970: 1772265600)
        let result = ExportManager.shared.formatDate(date, format: .european, includeTime: true, use24Hour: true)
        #expect(result.contains("28/02/2026"))
        #expect(result.contains(":"))
        #expect(!result.contains("AM") && !result.contains("PM"))
    }

    @Test("Metadata line has no underscores")
    @MainActor func metadataLineNoUnderscores() {
        let comment = makeComment(source: "Safari")
        let result = ExportManager.shared.formatMetadataLine(
            comment,
            includeRemarkID: false,
            includeSource: true,
            includeDate: true,
            includeStatus: false,
            includeType: false,
            dateFormat: .short
        )
        #expect(result != nil)
        #expect(!result!.hasPrefix("_"))
        #expect(!result!.hasSuffix("_"))
    }

    @Test("Metadata line with includeTime")
    @MainActor func metadataLineWithTime() {
        let comment = makeComment(source: "Xcode")
        let result = ExportManager.shared.formatMetadataLine(
            comment,
            includeRemarkID: false,
            includeSource: true,
            includeDate: true,
            includeStatus: false,
            includeType: false,
            dateFormat: .short,
            includeTime: true
        )
        #expect(result != nil)
        #expect(result!.contains(":"))
    }

    @Test("Metadata line with use24Hour")
    @MainActor func metadataLineWith24Hour() {
        let comment = makeComment(source: "Xcode")
        let result = ExportManager.shared.formatMetadataLine(
            comment,
            includeRemarkID: false,
            includeSource: true,
            includeDate: true,
            includeStatus: false,
            includeType: false,
            dateFormat: .short,
            includeTime: true,
            use24Hour: true
        )
        #expect(result != nil)
        #expect(!result!.contains("AM") && !result!.contains("PM"))
    }

    @Test("TimeFormat use24Hour property")
    func timeFormatUse24Hour() {
        #expect(SettingsManager.TimeFormat.twelve.use24Hour == false)
        #expect(SettingsManager.TimeFormat.twentyFour.use24Hour == true)
    }

    @Test("ExportDateFormat has all expected cases")
    func exportDateFormatCases() {
        let cases = SettingsManager.ExportDateFormat.allCases
        #expect(cases.count == 5)
        #expect(cases.contains(.short))
        #expect(cases.contains(.medium))
        #expect(cases.contains(.long))
        #expect(cases.contains(.iso))
        #expect(cases.contains(.european))
    }

    @Test("ExportDateFormat labels show today's date")
    func exportDateFormatLabels() {
        // Labels should be non-empty and contain recognizable date components
        let shortLabel = SettingsManager.ExportDateFormat.short.label
        #expect(!shortLabel.isEmpty)
        let isoLabel = SettingsManager.ExportDateFormat.iso.label
        #expect(isoLabel.contains("-")) // ISO format uses dashes
        let euroLabel = SettingsManager.ExportDateFormat.european.label
        #expect(euroLabel.contains("/")) // European format uses slashes
    }
}
