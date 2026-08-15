import AppKit
import SwiftUI
import ServiceManagement
import Combine
@MainActor
public final class AppController: NSObject, ObservableObject {
    public static let shared = AppController()

    private(set) var statusItem: NSStatusItem?

    /// Exposed for save animation targeting
    public var statusItemButton: NSStatusBarButton? { statusItem?.button }
    private var cancellables = Set<AnyCancellable>()
    private var bounceTimer: DispatchSourceTimer?
    private var pendingBounce = false

    @Published public private(set) var isOnboardingComplete: Bool = false

    public override init() {
        super.init()
    }

    public func setup() {
        prepareDebugLogFile()
        debugLog("AppController setup started")
        _ = ActivationPolicyManager.shared  // Establish activation policy early
        setupMenuBar()
        debugLog("Menu bar setup complete")

        // Claude Code integration is now distributed as a marketplace plugin
        // (metedata/remarc-agent-plugins). The app no longer writes into
        // ~/.claude/. LegacyInstallCleanup runs on every launch until both:
        //   1. Old artifacts are removed, AND
        //   2. The new `remarc` plugin is detected installed.
        Task { @MainActor in
            await LegacyInstallCleanup.shared.runIfNeeded()
            // After cleanup, so the popover status dot reflects the
            // post-cleanup registrations rather than one cleanup is about
            // to delete. Without this the dot stays on its default until
            // Preferences first opens.
            MCPManager.shared.checkDependencies()
        }

        _ = UpdateManager.shared
        debugLog("UpdateManager initialized")

        // Check if onboarding is needed
        if SettingsManager.shared.hasCompletedOnboarding {
            completeSetup(withHotkey: OnboardingWindowController.shared.checkAccessibilityPermission())
        } else {
            OnboardingWindowController.shared.onComplete = { [weak self] hasPermission in
                SettingsManager.shared.hasCompletedOnboarding = true
                self?.completeSetup(withHotkey: hasPermission)
            }
            OnboardingWindowController.shared.show()
        }
    }

    private func completeSetup(withHotkey: Bool) {
        debugLog("Completing app setup (withHotkey: \(withHotkey))")

        // Start event-driven selection monitoring
        SelectionMonitor.shared.startMonitoring()
        debugLog("SelectionMonitor started (event-driven)")

        // Start WebSocket server only if the extension has connected before (lazy start)
        if SettingsManager.shared.hasExtensionEverConnected {
            WebSocketService.shared.start()
            debugLog("WebSocketService started (extension previously connected)")
        } else {
            debugLog("WebSocketService deferred (extension never connected)")
        }

        // Initialize tooltip observer (subscribes to SelectionMonitor changes)
        _ = SelectionTooltipWindowController.shared
        debugLog("SelectionTooltipWindowController initialized")

        GlobalHotkey.shared.register()
        debugLog("GlobalHotkey registered")

        enableLoginItem()
        setupObservers()
        if #available(macOS 26, *) {
            preloadTranscriptionEngine()
        }
        isOnboardingComplete = true
        // Keep the wake button honest: ask the live sessions, not the plugin
        // registry, whether anything can be woken.
        SettingsManager.shared.refreshWakeReachability()

        // Retire the App Support script copies. Nothing resolves to them any
        // more, but they are executable JS predating every data-integrity fix,
        // and a config left pointing at one keeps running it.
        ScriptInstaller.removeStaleInstalledScripts()

        debugLog("AppController setup complete")
    }

    /// Prewarm or fully load the selected transcription engine model in the background.
    /// When `preloadModelOnLaunch` is enabled, the model is fully loaded into RAM so
    /// the first dictation invocation is instant. Otherwise, only CoreML compilation/
    /// caching on disk is triggered (fast cached loads: 3-5s vs 30-60s).
    @available(macOS 26, *)
    private func preloadTranscriptionEngine() {
        let settings = SettingsManager.shared
        let engine = settings.transcriptionEngine
        let fullLoad = settings.preloadModelOnLaunch && settings.keepModelInMemory

        Task.detached(priority: .utility) {
            switch engine {
            case .whisperKit:
                let model = await settings.whisperKitModel
                let manager = await WhisperKitModelManager.shared
                guard await manager.isModelDownloaded(model) else { return }
                if fullLoad {
                    let success = await manager.prepareModel(model)
                    await debugLog("AppController: WhisperKit preload \(success ? "succeeded" : "failed")")
                } else {
                    await manager.prewarmModel(model)
                }
            case .parakeet:
                let model = await settings.parakeetModelVersion
                let manager = await ParakeetModelManager.shared
                guard await manager.isModelDownloaded(model) else { return }
                if fullLoad {
                    let success = await manager.prepareModel(model)
                    await debugLog("AppController: Parakeet preload \(success ? "succeeded" : "failed")")
                }
            case .appleSpeech:
                await debugLog("AppController: Apple Speech — no prewarm needed")
            }
        }
    }

    private func setupObservers() {
        SettingsManager.shared.$isPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isPaused in
                self?.updateMenuBarIcon(isPaused: isPaused)
            }
            .store(in: &cancellables)

        // Observe comment count changes for badge
        PersistenceManager.shared.$appState
            .map { $0.comments.filter { !$0.isDeleted }.count }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.updateBadge(count: count)
            }
            .store(in: &cancellables)
    }

    private func updateMenuBarIcon(isPaused: Bool) {
        if let button = statusItem?.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            button.image = icon
            button.appearsDisabled = isPaused
        }
    }

    private func updateBadge(count: Int) {
        guard let button = statusItem?.button else { return }
        // Don't overwrite mid-bounce or pre-bounce — the bounce shows the new count
        guard bounceTimer == nil, !pendingBounce else { return }
        if count > 0 {
            // Create a filled circle badge image with the count
            let badgeImage = createBadgeImage(count: count)
            let attachment = NSTextAttachment()
            attachment.image = badgeImage
            // Vertically center with the status bar icon (offset from text baseline)
            let pad = Self.badgePadding
            let pillHeight = badgeImage.size.height - pad * 2
            let yOffset = -round(pillHeight * 0.28) - pad
            attachment.bounds = CGRect(x: 0, y: yOffset, width: badgeImage.size.width, height: badgeImage.size.height)
            let attachmentString = NSAttributedString(attachment: attachment)

            let attributed = NSMutableAttributedString(string: "\u{2009}")
            attributed.append(attachmentString)
            button.attributedTitle = attributed
        } else {
            button.title = ""
        }
    }

    /// Call before saving a comment to suppress Combine-driven badge updates
    /// until the bounce animation plays the new count.
    public func prepareBadgeBounce() {
        pendingBounce = true
    }

    /// Undo `prepareBadgeBounce` without animating.
    ///
    /// The capture transaction arms the bounce before the durable write, so a
    /// failed write must disarm it or badge updates stay suppressed until the next
    /// successful save.
    public func cancelPreparedBadgeBounce() {
        pendingBounce = false
    }

    /// Animate the badge pill with a bounce effect (pop in and settle).
    /// Call from fly-animation completion handlers for a "landing impact" feel.
    public func animateBadgeBounce() {
        pendingBounce = false
        guard let button = statusItem?.button else { return }
        let count = PersistenceManager.shared.allComments.count
        guard count > 0 else { return }

        // Cancel any in-progress bounce
        bounceTimer?.cancel()
        bounceTimer = nil

        // Bounce curve: smooth grow-in, gentle overshoot, settle
        // 14 frames × 28ms = ~390ms total
        let scales: [CGFloat] = [
            0.20, 0.48, 0.72, 0.88, 0.98,  // ease-out grow (5 frames)
            1.06, 1.10, 1.08,                // gentle overshoot (3 frames)
            1.03, 1.00, 0.97,                // settle (3 frames)
            0.99, 1.00, 1.00,                // rest (3 frames)
        ]

        // Pre-render all frames into fixed-size canvases so button width stays constant.
        // Each frame draws the scaled pill centered within the full-size rect.
        let text = "\(count)"
        let fullSizeImage = createBadgeImage(count: count)
        let fullWidth = fullSizeImage.size.width
        let fullHeight = fullSizeImage.size.height
        let pad = Self.badgePadding
        let pillHeight = fullHeight - pad * 2
        let yOffset = -round(pillHeight * 0.28) - pad
        let fixedBounds = CGRect(x: 0, y: yOffset, width: fullWidth, height: fullHeight)
        let frames: [NSImage] = scales.map { scale in
            let img = NSImage(size: NSSize(width: fullWidth, height: fullHeight), flipped: false) { rect in
                // Scale the pill (excluding padding) so the canvas stays fixed
                let pillW = (fullWidth - pad * 2) * scale
                let pillH = (fullHeight - pad * 2) * scale
                let pillRect = CGRect(
                    x: (rect.width - pillW) / 2,
                    y: (rect.height - pillH) / 2,
                    width: pillW,
                    height: pillH
                )
                Self.drawBadgePill(in: pillRect, text: text, fontSize: Self.badgeFontSize * scale)
                return true
            }
            img.isTemplate = false
            return img
        }

        var frameIndex = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(35))
        timer.setEventHandler { [weak self] in
            guard frameIndex < frames.count else {
                timer.cancel()
                self?.bounceTimer = nil
                return
            }
            let attachment = NSTextAttachment()
            attachment.image = frames[frameIndex]
            attachment.bounds = fixedBounds
            let attachmentString = NSAttributedString(attachment: attachment)
            let attributed = NSMutableAttributedString(string: "\u{2009}")
            attributed.append(attachmentString)
            button.attributedTitle = attributed
            frameIndex += 1
        }
        bounceTimer = timer
        timer.resume()
    }

    private static let badgeFontSize: CGFloat = 10

    /// Padding around the pill to prevent shadow/border clipping.
    private static let badgePadding: CGFloat = 2.0

    private func createBadgeImage(count: Int) -> NSImage {
        let text = "\(count)"
        let height: CGFloat = statusItem?.button?.image?.size.height ?? 18

        // Measure text at base size to determine pill width
        let baseFont = NSFont.monospacedDigitSystemFont(ofSize: Self.badgeFontSize, weight: .bold)
        let baseTextSize = (text as NSString).size(withAttributes: [.font: baseFont])

        // Pill sized to match menu bar icon height; width expands for wider numbers
        let pillWidth = max(height, baseTextSize.width + 10)
        let pad = Self.badgePadding
        let size = NSSize(width: pillWidth + pad * 2, height: height + pad * 2)

        let image = NSImage(size: size, flipped: false) { rect in
            let pillRect = rect.insetBy(dx: pad, dy: pad)
            Self.drawBadgePill(in: pillRect, text: text, fontSize: Self.badgeFontSize)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws a badge pill (fill + shadow + border + centered digit) into the current graphics context.
    private static func drawBadgePill(in pillRect: CGRect, text: String, fontSize: CGFloat) {
        let ctx = NSGraphicsContext.current!.cgContext
        let cornerRadius = pillRect.height / 2

        // Drop shadow
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -0.5),
            blur: 1.0,
            color: NSColor.black.withAlphaComponent(0.30).cgColor
        )
        NSColor.remarcBrandIndigo.setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        ctx.restoreGState()

        // Light inner border for contrast
        let bw: CGFloat = 1.0
        NSColor.white.withAlphaComponent(0.15).setStroke()
        let strokeRect = pillRect.insetBy(dx: bw / 2, dy: bw / 2)
        let strokePath = NSBezierPath(roundedRect: strokeRect,
                                      xRadius: strokeRect.height / 2, yRadius: strokeRect.height / 2)
        strokePath.lineWidth = bw
        strokePath.stroke()

        // Text visually centered using capHeight (digits don't use descender space)
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let textOriginY = pillRect.midY - font.capHeight / 2 + font.descender
        let textRect = CGRect(
            x: pillRect.midX - textSize.width / 2,
            y: textOriginY,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attrs)
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            let icon = NSImage(named: "MenuBarIcon")
            icon?.isTemplate = true
            button.image = icon
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Store reference so popover can position below the button
        MenuBarPopoverController.shared.statusItemButton = statusItem?.button
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        // If onboarding is pending and window was hidden, bring it back
        if !SettingsManager.shared.hasCompletedOnboarding {
            OnboardingWindowController.shared.bringBack()
            return
        }

        if event.type == .rightMouseUp {
            showRightClickMenu()
        } else {
            MenuBarPopoverController.shared.toggle()
        }
    }

    // MARK: - Right-Click Utility Menu

    private func showRightClickMenu() {
        let menu = NSMenu()

        let copyAllItem = NSMenuItem(title: "Copy All", action: #selector(copyAllAsMarkdown), keyEquivalent: "")
        copyAllItem.target = self
        copyAllItem.isEnabled = !PersistenceManager.shared.activeComments.isEmpty
        menu.addItem(copyAllItem)

        let quickNoteItem = NSMenuItem(title: "New Quick Note", action: #selector(newQuickNote), keyEquivalent: "")
        quickNoteItem.target = self
        menu.addItem(quickNoteItem)

        menu.addItem(NSMenuItem.separator())

        let detachItem = NSMenuItem(
            title: MenuBarPopoverController.shared.isDetached ? "Re-attach Window" : "Detach Window",
            action: MenuBarPopoverController.shared.isDetached ? #selector(reattachWindow) : #selector(detachWindow),
            keyEquivalent: ""
        )
        detachItem.target = self
        menu.addItem(detachItem)

        menu.addItem(NSMenuItem.separator())

        let pauseItem = NSMenuItem(
            title: SettingsManager.shared.isPaused ? "Resume" : "Pause",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Use the status-item menu trick for right-click: set, click, clear
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - Actions

    @objc private func openViewer() {
        MenuBarPopoverController.shared.show()
    }

    @objc private func newQuickNote() {
        CommentInputController.shared.showStandaloneNote()
    }

    @objc private func togglePause() {
        SettingsManager.shared.isPaused.toggle()
        if SettingsManager.shared.isPaused {
            SelectionMonitor.shared.stopMonitoring()
            SelectionTooltipWindowController.shared.dismiss()
        } else {
            SelectionMonitor.shared.startMonitoring()
        }
    }

    @objc private func showPreferences() {
        PreferencesWindowController.shared.show()
    }

    @objc private func detachWindow() {
        MenuBarPopoverController.shared.dismiss()
        DetachedWindowController.shared.show()
    }

    @objc private func reattachWindow() {
        DetachedWindowController.shared.dismiss()
    }

    // MARK: - Export Actions

    @objc private func copyAllAsMarkdown() {
        guard let session = PersistenceManager.shared.activeSession else { return }
        let comments = PersistenceManager.shared.activeComments
        ExportManager.shared.copySessionToClipboard(session, comments: comments, format: .markdown)
    }

    @objc private func copyAllAsJSON() {
        guard let session = PersistenceManager.shared.activeSession else { return }
        let comments = PersistenceManager.shared.activeComments
        ExportManager.shared.copySessionToClipboard(session, comments: comments, format: .json)
    }

    @objc private func saveAllToFile() {
        guard let session = PersistenceManager.shared.activeSession else { return }
        let comments = PersistenceManager.shared.activeComments
        ExportManager.shared.saveSessionToFile(session, comments: comments, format: SettingsManager.shared.outputFormat)
    }

    @objc private func checkForUpdates() {
        UpdateManager.shared.checkForUpdates()
    }

    // MARK: - App Info

    @objc private func showAbout() {
        let credits = NSMutableAttributedString()

        let footerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let contactLink = NSAttributedString(
            string: "Contact",
            attributes: [
                .link: URL(string: "mailto:mete@metedata.com")!,
                .font: footerFont
            ]
        )
        credits.append(contactLink)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        credits.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: credits.length)
        )

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationIcon: NSApp.applicationIconImage as Any,
            .credits: credits
        ]
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        PersistenceManager.shared.saveImmediately()
        NSApp.terminate(nil)
    }

    private func enableLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                print("Failed to register login item: \(error)")
            }
        }
    }

    // MARK: - Dock Icon Click Handler

    public func handleDockIconClick() {
        if !SettingsManager.shared.hasCompletedOnboarding {
            OnboardingWindowController.shared.bringBack()
            return
        }

        // Bring back settings if it's open or minimized, otherwise toggle the popover
        if PreferencesWindowController.shared.isVisible || PreferencesWindowController.shared.isMiniaturized {
            PreferencesWindowController.shared.bringBack()
        } else {
            MenuBarPopoverController.shared.toggle()
        }
    }
}
