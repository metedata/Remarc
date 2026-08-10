import Foundation

public struct TextSelection: Sendable {
    public let text: String
    public let source: String
    public let appBundleID: String?
    public let screenRect: CGRect?
    public let timestamp: Date

    public init(text: String, source: String, appBundleID: String?, screenRect: CGRect?, timestamp: Date = Date()) {
        self.text = text
        self.source = source
        self.appBundleID = appBundleID
        self.screenRect = screenRect
        self.timestamp = timestamp
    }

    /// Truncated selected text for display
    public var truncatedText: String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if cleaned.count > AppConstants.maxReferenceTextLength {
            return String(cleaned.prefix(AppConstants.maxReferenceTextLength)) + "..."
        }
        return cleaned
    }

    /// Truncated source for display
    public var truncatedSource: String {
        if source.count > AppConstants.maxReferenceTextLength {
            return String(source.prefix(AppConstants.maxReferenceTextLength)) + "..."
        }
        return source
    }
}
