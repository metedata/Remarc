import Foundation

public enum CommentType: Codable, Equatable, Sendable {
    case comment(text: String)
    case quickNote
    case screenshot(imagePath: String)
    case critMode
    case webElement(componentName: String?, filePath: String?)

    public var displayText: String? {
        switch self {
        case .comment(let text): return text
        case .quickNote: return nil
        case .screenshot: return nil
        case .critMode: return nil
        case .webElement(let name, _): return name
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

    public var isWebElement: Bool {
        if case .webElement = self { return true }
        return false
    }

    public var imagePath: String? {
        if case .screenshot(let path) = self { return path }
        return nil
    }

    // MARK: - Metadata

    public var identifier: String { kind.rawValue }

    public var displayName: String {
        switch self {
        case .critMode: return "Crit Mode"  // Kind uses "Crit" (shorter for filters)
        default: return kind.displayName
        }
    }

    public var iconName: String {
        // Aligns with `Kind.iconName` — `.webElement` → "globe" everywhere.
        // (Previously overridden to "chevron.left.forwardslash.chevron.right",
        //  which collided visually with the WebContextBadge's `</>` icon.)
        kind.iconName
    }
}

// MARK: - Kind (Hashable filter key)

extension CommentType {
    /// A simple, Hashable enum for filtering — strips associated values from CommentType.
    public enum Kind: String, Hashable, CaseIterable, Sendable {
        case comment, screenshot, quickNote, critMode, webElement
    }

    public var kind: Kind {
        switch self {
        case .comment: return .comment
        case .screenshot: return .screenshot
        case .quickNote: return .quickNote
        case .critMode: return .critMode
        case .webElement: return .webElement
        }
    }
}

extension CommentType.Kind {
    public var displayName: String {
        switch self {
        case .comment: return "Comment"
        case .screenshot: return "Screenshot"
        case .quickNote: return "Quick Note"
        case .critMode: return "Crit"
        case .webElement: return "Web Element"
        }
    }

    public var iconName: String {
        switch self {
        case .comment: return "text.quote"
        case .screenshot: return "camera.viewfinder"
        case .quickNote: return "note.text"
        case .critMode: return "mic.fill"
        case .webElement: return "globe"
        }
    }
}
