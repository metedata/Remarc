import AppKit

/// SF Symbols added after Ventura keep an equivalent icon on older systems.
@MainActor
enum RemarcSymbols {
    static let quickNote = name("bubble.and.pencil", fallback: "square.and.pencil")
    static let moveToSession = name("arrow.forward.folder", fallback: "folder")

    private static func name(_ preferred: String, fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) == nil ? fallback : preferred
    }
}
