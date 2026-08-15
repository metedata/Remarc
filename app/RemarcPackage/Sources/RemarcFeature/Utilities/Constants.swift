import AppKit
import os.log

private let logger = Logger(subsystem: "com.metepolat.Remarc", category: "debug")
nonisolated(unsafe) private let debugLogFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    return f
}()
private let debugLogQueue = DispatchQueue(label: "com.metepolat.Remarc.debugLog", qos: .utility)

/// Selected text, window titles, and dictation transcripts pass through here
/// (issue #12), so release builds write no log file at all unless the user
/// opts in for a support case:
///
///     defaults write com.metepolat.Remarc debugFileLoggingEnabled -bool YES
///
/// While the flag is set the current launch logs to a fresh file and the
/// previous launch's file is kept as remarc_debug.log.old, so a bug whose
/// reproduction spans a relaunch (or a Sparkle update mid-support-case) still
/// has its pre-restart half. Two bounded files at most. With the flag unset
/// (the default) both files are deleted on launch, which also clears logs
/// accumulated by older builds that wrote unconditionally. Debug builds keep
/// the fixed /tmp path that local tooling tails.
private let debugLogFileURL: URL? = {
    #if DEBUG
    return URL(fileURLWithPath: "/tmp/remarc_debug.log")
    #else
    let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Logs/Remarc", isDirectory: true)
    let logFile = logsDir.appendingPathComponent("remarc_debug.log")
    let previousLogFile = logsDir.appendingPathComponent("remarc_debug.log.old")
    guard UserDefaults.standard.bool(forKey: "debugFileLoggingEnabled") else {
        try? FileManager.default.removeItem(at: logFile)
        try? FileManager.default.removeItem(at: previousLogFile)
        return nil
    }
    try? FileManager.default.createDirectory(
        at: logsDir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try? FileManager.default.removeItem(at: previousLogFile)
    try? FileManager.default.moveItem(at: logFile, to: previousLogFile)
    return logFile
    #endif
}()

/// Runs the release-build log deletion/rotation above, eagerly. The first
/// debugLog call would do the same work lazily, but the docs promise "Remarc
/// deletes the log the next time it launches", and that must not depend on
/// early logging happening to come true. AppController.setup calls this
/// before anything else; calling it again is a no-op.
public func prepareDebugLogFile() {
    _ = debugLogFileURL
}

public func debugLog(_ message: String) {
    let timestamp = debugLogFormatter.string(from: Date())
    print("[Remarc] \(message)")
    logger.notice("\(message)")
    let logMessage = "[\(timestamp)] \(message)\n"
    debugLogQueue.async {
        guard let logFile = debugLogFileURL else { return }
        guard let data = logMessage.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: logFile)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logFile.path)
        }
    }
}

// MARK: - Image Path Helpers

/// The real storage root. Computed once; the app never uses anything else.
private let productionAppSupportURL: URL = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("Remarc", isDirectory: true)
}()

/// Set only by tests, to redirect every path helper at a temporary directory.
///
/// Without this the suite reads and writes the user's live
/// `~/Library/Application Support/Remarc`: it created images there, left
/// deliberately corrupt sidecars behind when a case failed before its teardown,
/// and two concurrent runs fought over the same files. A running Remarc then
/// found those fixtures and logged them as real corruption.
nonisolated(unsafe) var remarcAppSupportOverride: URL?

var remarcAppSupportURL: URL {
    remarcAppSupportOverride ?? productionAppSupportURL
}

/// Resolves a relative image path to an absolute URL under App Support/Remarc/
public func resolveImagePath(_ relativePath: String) -> URL {
    remarcAppSupportURL.appendingPathComponent(relativePath)
}

/// Loads an NSImage from a relative image path under App Support/Remarc/
public func loadScreenshotImage(_ relativePath: String) -> NSImage? {
    NSImage(contentsOf: resolveImagePath(relativePath))
}

/// Resolves a comment's `appBundleID` to a display name, or `nil` if no app is associated.
/// Results are cached to avoid repeated filesystem lookups per card per render.
@MainActor
func appDisplayName(for comment: Comment) -> String? {
    guard let bundleID = comment.appBundleID else { return nil }
    if let cached = appDisplayNameCache[bundleID] { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
    let name = FileManager.default.displayName(atPath: url.path)
    appDisplayNameCache[bundleID] = name
    return name
}
@MainActor private var appDisplayNameCache: [String: String] = [:]

public enum AppConstants {
    // Selection detection
    public static let selectionPollInterval: TimeInterval = 0.2
    public static let tooltipShowDelay: TimeInterval = 0.15
    public static let tooltipTimeout: TimeInterval = 5.0
    public static let tooltipFadeInDuration: TimeInterval = 0.12
    public static let tooltipFadeOutDuration: TimeInterval = 0.15

    // UI dimensions
    public static let tooltipCornerRadius: CGFloat = 8
    public static let panelCornerRadius: CGFloat = 12
    public static let viewerWidth: CGFloat = 800
    public static let viewerHeight: CGFloat = 550

    // Onboarding
    public static let onboardingWindowWidth: CGFloat = 660
    public static let onboardingWindowHeight: CGFloat = 680
    public static let onboardingCornerRadius: CGFloat = 16
    public static let permissionPollInterval: TimeInterval = 0.5

    // Comment
    public static let maxReferenceTextLength: Int = 80
    public static let maxActiveSessions: Int = 8

    /// How often CommentCardView re-evaluates its relative timestamp tier
    /// (so a card left open updates when a comment crosses the 24h boundary).
    public static let cardTimestampRefreshInterval: TimeInterval = 60

    // Sessions
    public static let inboxSessionName: String = "Inbox"

    // Claude Code marker files — format must match scripts/hooks/remarc-session-*.sh
    public static let claudeCodeMarkerDirectory: String = "/tmp"
    public static let claudeCodeMarkerPrefix: String = "remarc-claude-"
    public static let claudeCodeMarkerSuffix: String = ".marker"
    public static func claudeCodeMarkerPath(for claudeSessionId: String) -> String {
        "\(claudeCodeMarkerDirectory)/\(claudeCodeMarkerPrefix)\(claudeSessionId)\(claudeCodeMarkerSuffix)"
    }

    // Menu bar popover
    public static let popoverWidth: CGFloat = 380
    public static let popoverMinHeight: CGFloat = 440
    public static let popoverMaxHeightRatio: CGFloat = 0.65
    public static let cardCornerRadius: CGFloat = 10
    public static let editorWidth: CGFloat = 440
    public static let popoverArrowWidth: CGFloat = 20
    public static let popoverArrowHeight: CGFloat = 10
    public static let popoverGap: CGFloat = 7

    // History
    public static let defaultHistoryRetentionDays: Int = 1
    public static let defaultImageRetentionDays: Int = 7
    public static let defaultTranscriptionRetentionDays: Int = 7
    public static let historyIcon = "clock.arrow.trianglehead.counterclockwise.rotate.90"

    // Chrome extension
    public static let chromeExtensionURL = URL(string: "https://remarc.app/chrome-extension")!

    // WebSocket server
    public static let webSocketPort: UInt16 = 9274
    public static let webSocketHost = "127.0.0.1"

    // Known Chromium browser bundle IDs
    public static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

}

// MARK: - Compact Timestamp (display only)

extension Date {
    /// Compact timestamp for `CommentCardView` display. Display only; copy / export /
    /// MCP paths keep the full timestamp.
    ///
    /// - Less than 24h before `now`: time of day (`15:45` or `3:45 PM`).
    /// - 24h or older: the date, formatted with `dateFormat`.
    ///
    /// `now` is injected so the tier decision is deterministic in tests and so a
    /// periodic refresh can re-evaluate it as time passes.
    @MainActor
    func remarcCompactTimestamp(
        dateFormat: SettingsManager.ExportDateFormat,
        use24Hour: Bool,
        now: Date = Date()
    ) -> String {
        if now.timeIntervalSince(self) < 24 * 60 * 60 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = use24Hour ? "HH:mm" : "h:mm a"
            return formatter.string(from: self)
        } else {
            return ExportManager.shared.formatDate(self, format: dateFormat)
        }
    }
}
