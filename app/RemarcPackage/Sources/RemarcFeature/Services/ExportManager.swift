import AppKit
import UniformTypeIdentifiers

public enum ExportHighlight: Hashable, Sendable {
    case reference, numbering, commentPrefix, divider, dateFormat, metadataDivider
    case source, date, status, remarkID, aiHint, type
}

public struct PreviewSegment: Sendable {
    public let text: String
    public let highlights: Set<ExportHighlight>
}

public struct PreviewLine: Identifiable, Sendable {
    public let id: Int
    public let segments: [PreviewSegment]
}

@MainActor
public final class ExportManager {
    public static let shared = ExportManager()
    private init() {}

    // MARK: - Formatting Helpers

    /// Format a comment's reference text according to the chosen style.
    /// Returns nil for quick notes (no reference to show).
    public func formatReference(_ comment: Comment, style: SettingsManager.ReferenceStyle) -> String? {
        switch comment.type {
        case .comment(let text):
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
            return "![screenshot](\(resolveImagePath(imagePath).path))"
        case .quickNote:
            return nil
        case .critMode:
            return nil
        case .webElement(let name, let path):
            let parts = [name, path].compactMap { $0 }
            let label = parts.isEmpty ? "Web Element" : parts.joined(separator: " \u{00B7} ")
            switch style {
            case .blockquote: return "> [\(label)]"
            case .rePrefix: return "Re: \(label)"
            case .quoted: return "\"\(label)\""
            }
        }
    }

    /// Format the comment prefix (e.g. "Comment: ", "Note: ", "— ").
    public func formatCommentPrefix(style: SettingsManager.CommentPrefixStyle) -> String {
        switch style {
        case .comment: return "Comment: "
        case .note: return "Note: "
        case .dash: return "\u{2014} "
        case .arrow: return "\u{2192} "
        case .none: return ""
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
    public func formatDate(_ date: Date, format: SettingsManager.ExportDateFormat, includeTime: Bool = false, use24Hour: Bool = false) -> String {
        let formatter = DateFormatter()
        switch format {
        case .short:
            if includeTime {
                formatter.dateFormat = use24Hour ? "MMM d, HH:mm" : "MMM d, h:mm a"
            } else {
                formatter.dateFormat = "MMM d"
            }
        case .medium:
            if includeTime {
                formatter.dateFormat = use24Hour ? "MMM d, yyyy, HH:mm" : "MMM d, yyyy, h:mm a"
            } else {
                formatter.dateFormat = "MMM d, yyyy"
            }
        case .long:
            if includeTime {
                formatter.dateFormat = use24Hour ? "MMMM d, yyyy, HH:mm" : "MMMM d, yyyy, h:mm a"
            } else {
                formatter.dateFormat = "MMMM d, yyyy"
            }
        case .iso:
            // ISO always uses 24h regardless of time format setting
            formatter.dateFormat = includeTime ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        case .european:
            if includeTime {
                formatter.dateFormat = use24Hour ? "dd/MM/yyyy, HH:mm" : "dd/MM/yyyy, h:mm a"
            } else {
                formatter.dateFormat = "dd/MM/yyyy"
            }
        }
        return formatter.string(from: date)
    }

    /// Build the metadata line (e.g. "a3f2b | VS Code | Feb 28 | Open").
    /// Returns nil if no metadata fields are enabled.
    public func formatMetadataLine(
        _ comment: Comment,
        includeRemarkID: Bool,
        includeSource: Bool,
        includeDate: Bool,
        includeStatus: Bool,
        includeType: Bool,
        dateFormat: SettingsManager.ExportDateFormat,
        includeTime: Bool = false,
        use24Hour: Bool = false,
        metadataDivider: SettingsManager.MetadataDividerStyle = .pipe
    ) -> String? {
        var parts: [String] = []
        if includeRemarkID {
            parts.append(comment.shortID)
        }
        if includeSource {
            parts.append(comment.source)
        }
        if includeDate {
            parts.append(formatDate(comment.createdAt, format: dateFormat, includeTime: includeTime, use24Hour: use24Hour))
        }
        if includeStatus {
            parts.append(comment.status.label)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: metadataDivider.separator)
    }

    // MARK: - Markdown Export

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
            includeType: settings.includeType,
            includeTime: settings.includeTime,
            use24Hour: settings.timeFormat.use24Hour,
            metadataDivider: settings.metadataDividerStyle
        )
        if settings.includeAIHint && MCPManager.shared.isEnabled {
            result += "\n\n<!-- These remarks are from the '\(session.name)' session in Remarc. Use MCP tool remarc_list_comments with session_id to read and resolve them. -->"
        }
        return result
    }

    /// Core formatting method used by both real export and preview.
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
        includeType: Bool,
        includeTime: Bool = false,
        use24Hour: Bool = false,
        metadataDivider: SettingsManager.MetadataDividerStyle = .pipe
    ) -> String {
        let nonEmptyComments = comments.filter { !$0.commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var lines: [String] = []
        let commentPrefix = formatCommentPrefix(style: commentPrefixStyle)

        for (index, comment) in nonEmptyComments.enumerated() {
            let prefix = formatPrefix(index: index, style: numberingStyle)
            let reference = formatReference(comment, style: referenceStyle)

            if let reference {
                lines.append("\(prefix)\(reference)")
            }

            lines.append("\(commentPrefix)\(comment.commentText)")

            // Type line (separate from metadata)
            if includeType {
                lines.append("Type: \(comment.type.displayName)")
            }

            // Web context
            if let wc = comment.webContext, let summary = wc.displaySummary {
                lines.append("`\(summary)`")
                if let url = wc.pageUrl {
                    lines.append("`URL: \(url)`")
                }
                if let chain = wc.reactComponents, !chain.isEmpty {
                    lines.append("`Via: \(chain)`")
                }
                if let elementPath = wc.elementPath {
                    lines.append("`Element: \(wc.elementName ?? "unknown") @ \(elementPath)`")
                } else if let elementName = wc.elementName {
                    lines.append("`Element: \(elementName)`")
                }
                if let selectedText = wc.selectedText {
                    lines.append("`Selected text: \(selectedText)`")
                }
                if let selector = wc.selector {
                    lines.append("`\(selector)`")
                }
                if let cssClasses = wc.cssClasses, !cssClasses.isEmpty {
                    lines.append("`Classes: \(cssClasses)`")
                }
                if let styles = wc.computedStyles, !styles.isEmpty {
                    lines.append("`Styles: \(styles)`")
                }
                if let a11y = wc.accessibility, !a11y.isEmpty {
                    lines.append("`A11y: \(a11y)`")
                }
                if let nearby = wc.nearbyText, !nearby.isEmpty {
                    lines.append("`Nearby: \(nearby)`")
                }
            }

            // Region elements
            if let elements = comment.regionElements, elements.count > 1 {
                lines.append("Region elements (\(elements.count)):")
                for el in elements.prefix(5) {
                    let label = el.displaySummary ?? el.elementName ?? el.selector ?? "unknown"
                    lines.append("  - `\(label)`")
                }
                if elements.count > 5 {
                    lines.append("  - ... and \(elements.count - 5) more")
                }
            }

            // Attachments
            for attachment in comment.attachments {
                lines.append("![attachment](\(resolveImagePath(attachment).path))")
            }

            // Metadata line
            if let metadataLine = formatMetadataLine(
                comment,
                includeRemarkID: includeRemarkID,
                includeSource: includeSource,
                includeDate: includeDate,
                includeStatus: includeStatus,
                includeType: includeType,
                dateFormat: dateFormat,
                includeTime: includeTime,
                use24Hour: use24Hour,
                metadataDivider: metadataDivider
            ) {
                lines.append(metadataLine)
            }

            // Divider (not after last comment)
            if index < nonEmptyComments.count - 1 {
                switch dividerStyle {
                case .horizontalRule:
                    lines.append("---")
                case .doubleLine:
                    lines.append("===")
                case .dotted:
                    lines.append("\u{00B7}\u{00B7}\u{00B7}")
                case .blankLine:
                    lines.append("")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - JSON Export

    public func jsonForSession(_ session: Session, comments: [Comment], includeMetadata: Bool) -> String {
        struct ExportComment: Encodable {
            let number: Int
            let selectedText: String?
            let imagePath: String?
            let comment: String
            let type: String
            let source: String
            let timestamp: String
            let attachments: [String]?
            let webContext: WebContext?
            let regionElements: [WebContext]?
        }

        struct ExportWrapper: Encodable {
            let session: String?
            let exported: String?
            let comments: [ExportComment]
        }

        let formatter = ISO8601DateFormatter()
        let nonEmptyComments = comments.filter { !$0.commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let exportComments = nonEmptyComments.enumerated().map { index, comment in
            ExportComment(
                number: index + 1,
                selectedText: comment.selectedText,
                imagePath: comment.type.imagePath.map { resolveImagePath($0).path },
                comment: comment.commentText,
                type: comment.type.identifier,
                source: comment.source,
                timestamp: formatter.string(from: comment.createdAt),
                attachments: comment.attachments.isEmpty ? nil : comment.attachments.map { resolveImagePath($0).path },
                webContext: comment.webContext,
                regionElements: comment.regionElements
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if includeMetadata {
            let wrapper = ExportWrapper(
                session: session.name,
                exported: formatter.string(from: Date()),
                comments: exportComments
            )
            if let data = try? encoder.encode(wrapper) {
                return String(data: data, encoding: .utf8) ?? "[]"
            }
        } else {
            if let data = try? encoder.encode(exportComments) {
                return String(data: data, encoding: .utf8) ?? "[]"
            }
        }

        return "[]"
    }

    // MARK: - Single Comment Export

    public func markdownForComment(_ comment: Comment) -> String {
        let settings = SettingsManager.shared
        return markdownForComments(
            [comment],
            referenceStyle: settings.referenceStyle,
            numberingStyle: .none,  // Single comment: no numbering
            commentPrefixStyle: settings.commentPrefixStyle,
            dividerStyle: .blankLine,
            dateFormat: settings.exportDateFormat,
            includeRemarkID: settings.includeRemarkID,
            includeSource: settings.includeSource,
            includeDate: settings.includeDate,
            includeStatus: settings.includeStatus,
            includeType: settings.includeType,
            includeTime: settings.includeTime,
            use24Hour: settings.timeFormat.use24Hour,
            metadataDivider: settings.metadataDividerStyle
        )
    }

    // MARK: - Preview

    private lazy var sampleComments: [Comment] = [
            Comment(
                type: .comment(text: "let maxRetries = 42 // default"),
                commentText: "Seems arbitrary — where does this come from?",
                source: "Xcode",
                appBundleID: nil,
                createdAt: Date(),
                sessionID: UUID(),
                status: .open
            ),
            Comment(
                type: .comment(text: "func applicationWillTerminate()"),
                commentText: "So it goes. Clean up observers before exit.",
                source: "Xcode",
                appBundleID: nil,
                createdAt: Date().addingTimeInterval(-3600),
                sessionID: UUID(),
                status: .open
            ),
            Comment(
                type: .comment(text: "--color-ice-nine: rgba(0, 255, 206, 1)"),
                commentText: "This token cascades and freezes everything.",
                source: "Pages",
                appBundleID: nil,
                createdAt: Date().addingTimeInterval(-86400),
                sessionID: UUID(),
                status: .resolved
            ),
            Comment(
                type: .quickNote,
                commentText: "Most useful advice in the whole guide.",
                source: "Slack",
                appBundleID: nil,
                createdAt: Date().addingTimeInterval(-172800),
                sessionID: UUID(),
                status: .open
            ),
            Comment(
                type: .critMode,
                commentText: "Don't panic. Rollback script is in the wiki.",
                source: "Figma",
                appBundleID: nil,
                createdAt: Date().addingTimeInterval(-259200),
                sessionID: UUID(),
                status: .open
            ),
            Comment(
                type: .comment(text: "All tests were green as of last Tuesday"),
                commentText: "Everything was beautiful until the merge.",
                source: "Slack",
                appBundleID: nil,
                createdAt: Date().addingTimeInterval(-345600),
                sessionID: UUID(),
                status: .resolved
            ),
    ]

    /// Generate structured preview lines with highlight tags for the settings preview panel.
    public func previewLines(
        referenceStyle: SettingsManager.ReferenceStyle,
        numberingStyle: SettingsManager.NumberingStyle,
        commentPrefixStyle: SettingsManager.CommentPrefixStyle = .none,
        dividerStyle: SettingsManager.DividerStyle,
        dateFormat: SettingsManager.ExportDateFormat,
        includeRemarkID: Bool,
        includeSource: Bool,
        includeDate: Bool,
        includeStatus: Bool,
        includeType: Bool,
        includeTime: Bool = false,
        use24Hour: Bool = false,
        metadataDivider: SettingsManager.MetadataDividerStyle = .pipe,
        includeAIHint: Bool = false
    ) -> [PreviewLine] {
        var lines: [PreviewLine] = []
        let comments = sampleComments
        let maxSourceLen = comments.map { $0.source.count }.max() ?? 0

        for (index, comment) in comments.enumerated() {
            let prefix = formatPrefix(index: index, style: numberingStyle)

            // Reference line: split so only style indicators highlight
            switch comment.type {
            case .comment(let text):
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                var segments: [PreviewSegment] = []
                if !prefix.isEmpty {
                    segments.append(PreviewSegment(text: prefix, highlights: [.numbering]))
                }
                switch referenceStyle {
                case .blockquote:
                    segments.append(PreviewSegment(text: "> ", highlights: [.reference]))
                    segments.append(PreviewSegment(text: cleaned, highlights: []))
                case .rePrefix:
                    segments.append(PreviewSegment(text: "Re: ", highlights: [.reference]))
                    segments.append(PreviewSegment(text: cleaned, highlights: []))
                case .quoted:
                    segments.append(PreviewSegment(text: "\"", highlights: [.reference]))
                    segments.append(PreviewSegment(text: cleaned, highlights: []))
                    segments.append(PreviewSegment(text: "\"", highlights: [.reference]))
                }
                lines.append(PreviewLine(id: lines.count, segments: segments))
            case .screenshot(let imagePath):
                var segments: [PreviewSegment] = []
                if !prefix.isEmpty {
                    segments.append(PreviewSegment(text: prefix, highlights: [.numbering]))
                }
                segments.append(PreviewSegment(text: "![screenshot](\(imagePath))", highlights: [.reference]))
                lines.append(PreviewLine(id: lines.count, segments: segments))
            case .quickNote:
                break
            case .critMode:
                break
            case .webElement:
                break
            }

            // Hanging indent: pad continuation lines to align with content after prefix
            let indent = prefix.isEmpty ? "" : String(repeating: " ", count: prefix.count)

            // Comment text with optional prefix
            let commentPrefixText = formatCommentPrefix(style: commentPrefixStyle)
            var commentSegments: [PreviewSegment] = []
            if !indent.isEmpty {
                commentSegments.append(PreviewSegment(text: indent, highlights: []))
            }
            if !commentPrefixText.isEmpty {
                commentSegments.append(PreviewSegment(text: commentPrefixText, highlights: [.commentPrefix]))
            }
            commentSegments.append(PreviewSegment(text: comment.commentText, highlights: []))
            lines.append(PreviewLine(id: lines.count, segments: commentSegments))

            // Type line (separate from metadata)
            if includeType {
                var typeSegments: [PreviewSegment] = []
                if !indent.isEmpty {
                    typeSegments.append(PreviewSegment(text: indent, highlights: []))
                }
                typeSegments.append(PreviewSegment(text: "Type: \(comment.type.displayName)", highlights: [.type]))
                lines.append(PreviewLine(id: lines.count, segments: typeSegments))
            }

            // Metadata line: each part is its own segment with separators
            var metaSegments: [PreviewSegment] = []
            if !indent.isEmpty {
                metaSegments.append(PreviewSegment(text: indent, highlights: []))
            }
            var metaFieldCount = 0
            if includeRemarkID {
                metaSegments.append(PreviewSegment(text: comment.shortID, highlights: [.remarkID]))
                metaFieldCount += 1
            }
            if includeSource {
                if metaFieldCount > 0 {
                    metaSegments.append(PreviewSegment(text: metadataDivider.separator, highlights: [.metadataDivider]))
                }
                let paddedSource = comment.source.padding(toLength: maxSourceLen, withPad: " ", startingAt: 0)
                metaSegments.append(PreviewSegment(text: paddedSource, highlights: [.source]))
                metaFieldCount += 1
            }
            if includeDate {
                if metaFieldCount > 0 {
                    metaSegments.append(PreviewSegment(text: metadataDivider.separator, highlights: [.metadataDivider]))
                }
                metaSegments.append(PreviewSegment(text: formatDate(comment.createdAt, format: dateFormat, includeTime: includeTime, use24Hour: use24Hour), highlights: [.date, .dateFormat]))
                metaFieldCount += 1
            }
            if includeStatus {
                if metaFieldCount > 0 {
                    metaSegments.append(PreviewSegment(text: metadataDivider.separator, highlights: [.metadataDivider]))
                }
                metaSegments.append(PreviewSegment(text: comment.status.label, highlights: [.status]))
                metaFieldCount += 1
            }
            if metaFieldCount > 0 {
                lines.append(PreviewLine(id: lines.count, segments: metaSegments))
            }

            // Divider (not after last comment)
            if index < comments.count - 1 {
                switch dividerStyle {
                case .horizontalRule:
                    lines.append(PreviewLine(id: lines.count, segments: [PreviewSegment(text: "---", highlights: [.divider])]))
                case .doubleLine:
                    lines.append(PreviewLine(id: lines.count, segments: [PreviewSegment(text: "===", highlights: [.divider])]))
                case .dotted:
                    lines.append(PreviewLine(id: lines.count, segments: [PreviewSegment(text: "\u{00B7}\u{00B7}\u{00B7}", highlights: [.divider])]))
                case .blankLine:
                    lines.append(PreviewLine(id: lines.count, segments: [PreviewSegment(text: "", highlights: [.divider])]))
                }
            }
        }

        if includeAIHint {
            lines.append(PreviewLine(id: lines.count, segments: [PreviewSegment(text: "", highlights: [])]))
            lines.append(PreviewLine(id: lines.count, segments: [PreviewSegment(text: "<!-- These remarks are from the 'Session' session in Remarc. Use MCP tool remarc_list_comments with session_id to read and resolve them. -->", highlights: [.aiHint])]))
        }

        return lines
    }

    /// Generate sample markdown for the settings preview panel.
    public func previewMarkdown(
        referenceStyle: SettingsManager.ReferenceStyle,
        numberingStyle: SettingsManager.NumberingStyle,
        commentPrefixStyle: SettingsManager.CommentPrefixStyle = .none,
        dividerStyle: SettingsManager.DividerStyle,
        dateFormat: SettingsManager.ExportDateFormat,
        includeRemarkID: Bool,
        includeSource: Bool,
        includeDate: Bool,
        includeStatus: Bool,
        includeType: Bool,
        includeTime: Bool = false,
        use24Hour: Bool = false,
        metadataDivider: SettingsManager.MetadataDividerStyle = .pipe
    ) -> String {
        previewLines(
            referenceStyle: referenceStyle,
            numberingStyle: numberingStyle,
            commentPrefixStyle: commentPrefixStyle,
            dividerStyle: dividerStyle,
            dateFormat: dateFormat,
            includeRemarkID: includeRemarkID,
            includeSource: includeSource,
            includeDate: includeDate,
            includeStatus: includeStatus,
            includeType: includeType,
            includeTime: includeTime,
            use24Hour: use24Hour,
            metadataDivider: metadataDivider
        ).map { $0.segments.map(\.text).joined() }.joined(separator: "\n")
    }

    // MARK: - Clipboard Actions

    public func copySessionToClipboard(_ session: Session, comments: [Comment], format: SettingsManager.OutputFormat) {
        let content: String
        let includeMetadata = SettingsManager.shared.includeMetadataInExport

        switch format {
        case .markdown:
            content = markdownForSession(session, comments: comments, includeMetadata: includeMetadata)
        case .json:
            content = jsonForSession(session, comments: comments, includeMetadata: includeMetadata)
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        debugLog("ExportManager: Copied \(comments.count) comments as \(format.label)")
    }

    public func copyCommentToClipboard(_ comment: Comment) {
        let content = markdownForComment(comment)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        debugLog("ExportManager: Copied single comment")
    }

    // MARK: - File Save

    public func saveSessionToFile(_ session: Session, comments: [Comment], format: SettingsManager.OutputFormat) {
        let content: String
        let fileExtension: String

        switch format {
        case .markdown:
            content = markdownForSession(session, comments: comments, includeMetadata: true)
            fileExtension = "md"
        case .json:
            content = jsonForSession(session, comments: comments, includeMetadata: true)
            fileExtension = "json"
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(session.name).\(fileExtension)"
        panel.allowedContentTypes = fileExtension == "md"
            ? [UTType(filenameExtension: "md") ?? .plainText]
            : [.json]
        panel.canCreateDirectories = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    debugLog("ExportManager: Saved to \(url.path)")
                } catch {
                    debugLog("ExportManager: Save failed - \(error.localizedDescription)")
                }
            }
        }
    }
}
