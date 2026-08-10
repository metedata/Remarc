import AppKit
import ApplicationServices

/// Reads selected text from any app using a cascading fallback strategy.
/// Method 1: Standard AX `kAXSelectedTextAttribute`
/// Method 2: WebKit text markers (`AXSelectedTextMarkerRange`)
/// Method 3: Passive pasteboard read for copy-on-select terminal renderers
/// Method 4: Clipboard fallback (simulate Cmd+C, read, restore)
@MainActor
public final class TextReader {
    public static let shared = TextReader()

    // Bundle IDs that need AX activation (Electron/Chromium apps)
    private let electronAppPrefixes: Set<String> = [
        "com.google.Chrome",
        "com.microsoft.VSCode",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.electron.",
    ]

    // Bundle IDs of GPU-rendered apps with no AX tree — only clipboard fallback works
    private static let gpuRenderedApps: Set<String> = [
        // GPU-rendered terminals
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "com.raphamorim.rio",
        // GPU-rendered editors
        "dev.zed.Zed",
        "dev.zed.Zed-Preview",
        // GPU-rendered design tools (WebGL canvas)
        "com.figma.Desktop",
    ]

    // Bundle ID prefixes for GPU-rendered app families (Java Swing, Sublime's custom engine)
    private static let gpuRenderedAppPrefixes: [String] = [
        "com.jetbrains.",
        "com.sublimetext.",
        "com.sublimemerge",
    ]

    // Terminal and integrated-terminal hosts where apps may publish their own
    // selection to NSPasteboard when the terminal itself owns mouse selection.
    // Claude Code fullscreen rendering does this instead of exposing AX selection.
    private static let passiveSelectionClipboardApps: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.googlecode.iterm2.beta",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "com.raphamorim.rio",
        "co.zeit.hyper",
        "org.tabby",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.microsoft.VSCodeExploration",
        "com.visualstudio.code.oss",
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
    ]

    private static let passiveSelectionClipboardAppPrefixes: [String] = [
        "com.jetbrains.",
    ]

    private init() {}

    // MARK: - Public API

    static func appNeedsClipboardFallback(bundleID: String) -> Bool {
        gpuRenderedApps.contains(bundleID)
            || gpuRenderedAppPrefixes.contains(where: { bundleID.hasPrefix($0) })
    }

    static func appMayPublishSelectionToClipboard(bundleID: String) -> Bool {
        passiveSelectionClipboardApps.contains(bundleID)
            || passiveSelectionClipboardAppPrefixes.contains(where: { bundleID.hasPrefix($0) })
    }

    /// Whether the frontmost app is a known GPU-rendered app that needs clipboard fallback.
    public func frontmostAppNeedsClipboardFallback() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.appNeedsClipboardFallback(bundleID: bundleID)
    }

    /// Whether the frontmost app may copy selection to the pasteboard itself.
    public func frontmostAppMayPublishSelectionToClipboard() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return Self.appMayPublishSelectionToClipboard(bundleID: bundleID)
    }

    /// Read selected text from the frontmost app.
    /// Returns nil if no text is selected.
    public func readSelection() -> (text: String, source: String, bundleID: String?, bounds: CGRect?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            debugLog("TextReader: No frontmost app")
            return nil
        }
        let pid = app.processIdentifier
        let bundleID = app.bundleIdentifier

        // Check if paused or excluded
        if SettingsManager.shared.isPaused { return nil }
        if let bid = bundleID, SettingsManager.shared.excludedAppBundleIDs.contains(bid) { return nil }

        // Activate enhanced AX for all apps - harmless no-op for non-Electron apps,
        // but critical for Chromium/Electron apps we haven't explicitly listed.
        activateElectronAX(pid: pid)

        let appElement = AXUIElementCreateApplication(pid)

        // Get focused element (with fallback to focused window)
        guard let focusedElement = getFocusedElement(appElement: appElement, pid: pid, bundleID: bundleID) else {
            debugLog("TextReader: No focused element in \(bundleID ?? "?")")
            return nil
        }

        // Try cascading methods to get selected text
        guard let text = readText(from: focusedElement) else {
            debugLog("TextReader: No text found (all methods failed) in \(bundleID ?? "?")")
            return nil
        }
        let processed = SettingsManager.shared.normalizeWhitespace ? normalizeWhitespace(text) : text
        guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let source = getWindowTitle(appElement: appElement, pid: pid) ?? app.localizedName ?? bundleID ?? "Unknown"
        let bounds = getSelectionBounds(focusedElement: focusedElement)

        return (text: processed, source: source, bundleID: bundleID, bounds: bounds)
    }

    /// Read selected text using clipboard fallback (for hotkey mode or GPU-rendered apps).
    /// This simulates Cmd+C and reads the clipboard.
    public func readSelectionViaClipboard() -> (text: String, source: String, bundleID: String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            debugLog("readSelectionViaClipboard: no frontmost app")
            return nil
        }
        let bundleID = app.bundleIdentifier
        debugLog("readSelectionViaClipboard: frontmost=\(bundleID ?? "nil")")

        if SettingsManager.shared.isPaused {
            debugLog("readSelectionViaClipboard: paused")
            return nil
        }
        if let bid = bundleID, SettingsManager.shared.excludedAppBundleIDs.contains(bid) {
            debugLog("readSelectionViaClipboard: excluded app \(bid)")
            return nil
        }

        // Try AX first
        debugLog("readSelectionViaClipboard: trying AX...")
        if let result = readSelection() {
            debugLog("readSelectionViaClipboard: AX succeeded")
            return (text: result.text, source: result.source, bundleID: result.bundleID)
        }

        // Clipboard fallback
        debugLog("readSelectionViaClipboard: AX failed, trying clipboard fallback...")
        guard let text = simulateCopyAndRead() else {
            debugLog("readSelectionViaClipboard: clipboard fallback also failed")
            return nil
        }
        let processed = SettingsManager.shared.normalizeWhitespace ? normalizeWhitespace(text) : text
        guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let source = app.localizedName ?? bundleID ?? "Unknown"
        return (text: processed, source: source, bundleID: bundleID)
    }

    /// Read text that the frontmost app already placed on the pasteboard during
    /// the current selection gesture. This does not simulate Cmd+C or restore the
    /// clipboard; it only trusts a pasteboard change that happened after the
    /// gesture started.
    public func readSelectionFromPasteboardIfChanged(
        since previousChangeCount: Int?
    ) -> (text: String, source: String, bundleID: String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            debugLog("readSelectionFromPasteboardIfChanged: no frontmost app")
            return nil
        }

        let bundleID = app.bundleIdentifier

        if SettingsManager.shared.isPaused {
            debugLog("readSelectionFromPasteboardIfChanged: paused")
            return nil
        }
        if let bid = bundleID, SettingsManager.shared.excludedAppBundleIDs.contains(bid) {
            debugLog("readSelectionFromPasteboardIfChanged: excluded app \(bid)")
            return nil
        }
        guard let bid = bundleID, Self.appMayPublishSelectionToClipboard(bundleID: bid) else {
            return nil
        }
        guard let previousChangeCount else {
            debugLog("readSelectionFromPasteboardIfChanged: no gesture pasteboard baseline")
            return nil
        }

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != previousChangeCount else {
            debugLog("readSelectionFromPasteboardIfChanged: pasteboard unchanged")
            return nil
        }
        guard let text = pasteboard.string(forType: .string) else {
            debugLog("readSelectionFromPasteboardIfChanged: pasteboard changed without string")
            return nil
        }

        let processed = SettingsManager.shared.normalizeWhitespace ? normalizeWhitespace(text) : text
        guard !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let source = getWindowTitle(appElement: appElement, pid: app.processIdentifier) ?? app.localizedName ?? bundleID ?? "Unknown"
        debugLog("readSelectionFromPasteboardIfChanged: using pasteboard selection from \(bid)")
        return (text: processed, source: source, bundleID: bundleID)
    }

    // MARK: - Text Normalization

    /// Cleans up terminal soft-wrap artifacts: trims each line and collapses interior runs of spaces.
    private func normalizeWhitespace(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                String(line)
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            }
            .joined(separator: "\n")
    }

    // MARK: - Cascading Text Retrieval

    private func readText(from element: AXUIElement) -> String? {
        // Method 1: Standard AX selected text
        if let text = readAXSelectedText(element) {
            return text
        }

        // Method 2: WebKit text markers (Safari, Mail, etc.)
        if let text = readWebKitMarkerText(element) {
            return text
        }

        return nil
    }

    /// Method 1: Standard `kAXSelectedTextAttribute`
    private func readAXSelectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard result == .success else {
            debugLog("TextReader: AX selectedText failed (\(result.rawValue))")
            return nil
        }

        if let text = value as? String { return text }
        if let attrText = value as? NSAttributedString { return attrText.string }
        return nil
    }

    /// Method 2: WebKit text markers (`AXSelectedTextMarkerRange` → `AXStringForTextMarkerRange`)
    private func readWebKitMarkerText(_ element: AXUIElement) -> String? {
        var markerValue: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerValue)
        guard rangeResult == .success, let markerRange = markerValue else { return nil }

        var textValue: CFTypeRef?
        let textResult = AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForTextMarkerRange" as CFString, markerRange, &textValue
        )
        guard textResult == .success else { return nil }

        if let text = textValue as? String {
            debugLog("TextReader: WebKit marker text succeeded")
            return text
        }
        if let attrText = textValue as? NSAttributedString { return attrText.string }
        return nil
    }

    /// Pasteboard type markers that tell clipboard managers (Maccy, Paste, Alfred, Raycast)
    /// to ignore this entry. Convention from 1Password, widely adopted.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Method 3: Clipboard fallback — simulate Cmd+C, read, restore
    private func simulateCopyAndRead() -> String? {
        let pasteboard = NSPasteboard.general

        // Save current clipboard state (all items and types)
        let savedItems = saveClipboard()
        let previousChangeCount = pasteboard.changeCount

        // Mark clipboard as transient BEFORE Cmd+C so clipboard managers
        // that snapshot on change see the marker immediately
        pasteboard.clearContents()
        pasteboard.setData(Data(), forType: Self.transientType)
        pasteboard.setData(Data(), forType: Self.concealedType)

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // 'c'
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Wait for clipboard to update
        usleep(100_000) // 100ms

        let newText: String?
        if pasteboard.changeCount != previousChangeCount {
            newText = pasteboard.string(forType: .string)
        } else {
            newText = nil
        }

        // Restore clipboard with transient markers so the restore itself
        // doesn't pollute clipboard history either
        restoreClipboard(savedItems, markTransient: true)

        return newText
    }

    // MARK: - Clipboard Save/Restore

    private func saveClipboard() -> [[(NSPasteboard.PasteboardType, Data)]] {
        let pasteboard = NSPasteboard.general
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    private func restoreClipboard(_ items: [[(NSPasteboard.PasteboardType, Data)]], markTransient: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if items.isEmpty {
            // Clipboard was empty before — just leave it empty with transient marker
            if markTransient {
                pasteboard.setData(Data(), forType: Self.transientType)
            }
            return
        }

        for itemData in items {
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            if markTransient {
                item.setData(Data(), forType: Self.transientType)
                item.setData(Data(), forType: Self.concealedType)
            }
            pasteboard.writeObjects([item])
        }
    }

    // MARK: - Focused Element

    private func getFocusedElement(appElement: AXUIElement, pid: pid_t, bundleID: String?) -> AXUIElement? {
        var focusedValue: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedValue)

        // Fallback: try focused window
        if result != .success {
            result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue)
        }

        guard result == .success, let focused = focusedValue else { return nil }

        let element = focused as! AXUIElement

        // For apps like Word/Excel: touch descendants to force AX initialization, then re-query
        touchDescendants(element, depth: 4)

        // Re-fetch after touching
        var refetchedValue: CFTypeRef?
        let refetchResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &refetchedValue)
        if refetchResult == .success, let refetched = refetchedValue {
            return (refetched as! AXUIElement)
        }

        return element
    }

    private func touchDescendants(_ element: AXUIElement, depth: Int) {
        guard depth > 0 else { return }
        var children: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard result == .success, let childArray = children as? [AXUIElement] else { return }
        for child in childArray.prefix(8) {
            touchDescendants(child, depth: depth - 1)
        }
    }

    // MARK: - Electron/Chromium AX Activation

    private func isElectronApp(_ bundleID: String) -> Bool {
        electronAppPrefixes.contains(where: { bundleID.hasPrefix($0) })
    }

    private func activateElectronAX(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
    }

    // MARK: - Window Title

    private func getWindowTitle(appElement: AXUIElement, pid: pid_t) -> String? {
        var windowValue: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
        guard windowResult == .success, let window = windowValue else {
            return NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }?.localizedName
        }

        let windowElement = window as! AXUIElement
        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleValue)
        if titleResult == .success, let title = titleValue as? String, !title.isEmpty {
            let appName = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }?.localizedName ?? ""
            if !appName.isEmpty && title != appName {
                return "\(appName) — \(title)"
            }
            return title
        }

        return NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }?.localizedName
    }

    // MARK: - Selection Bounds

    private func getSelectionBounds(focusedElement: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
        guard rangeResult == .success, let range = rangeValue else { return nil }

        var boundsValue: CFTypeRef?
        let boundsResult = AXUIElementCopyParameterizedAttributeValue(
            focusedElement, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsValue
        )
        guard boundsResult == .success, let bounds = boundsValue else { return nil }

        var axRect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &axRect) else { return nil }

        // AX returns top-left origin (Quartz coordinates).
        // Convert to AppKit bottom-left origin.
        guard let screenHeight = NSScreen.screens.first?.frame.height else { return nil }
        let flippedY = screenHeight - axRect.origin.y - axRect.size.height
        return CGRect(x: axRect.origin.x, y: flippedY, width: axRect.size.width, height: axRect.size.height)
    }
}
