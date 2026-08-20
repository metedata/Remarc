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

        RemarcURLHandler.shared.markReady()
        debugLog("RemarcURLHandler ready")

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

        // Observe unresolved comment count changes for the menu bar indicator.
        // Resolving a retained comment must remove it from the counter even
        // though the total number of stored comments does not change.
        PersistenceManager.shared.$appState
            .map { CommentCountPolicy.unresolvedCount(in: $0.comments) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.refreshIndicator(count: count)
            }
            .store(in: &cancellables)

        // Repaint on preference change, so the controls take effect immediately
        // rather than at next launch. `receive(on:)` always defers, so the
        // willSet-driven emission lands after the property has its new value.
        Publishers.Merge(
            SettingsManager.shared.$menuBarIndicatorStyle.map { _ in () },
            SettingsManager.shared.$hidesMenuBarCountAtZero.map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            // A style switch outranks a bounce still in flight: without
            // cancelling, switching to Off mid-bounce strands the old pill.
            self?.cancelBounce()
            self?.pendingBounce = false
            // Not animated: flipping the picker to Dot is the user looking at
            // Preferences, not a comment arriving.
            self?.refreshIndicator(count: PersistenceManager.shared.unresolvedCommentCount,
                                   animated: false)
        }
        .store(in: &cancellables)
    }

    private func updateMenuBarIcon(isPaused: Bool) {
        guard let button = statusItem?.button else { return }
        // Recompute from the live indicator: the notched glyph must survive a
        // pause toggle, which would otherwise reset the image to the plain one.
        let indicator = currentIndicator(count: PersistenceManager.shared.unresolvedCommentCount)
        applyIcon(for: indicator, isPaused: isPaused, to: button)
    }

    private func applyIcon(for indicator: SettingsManager.MenuBarIndicator,
                           isPaused: Bool,
                           to button: NSStatusBarButton) {
        // Dot mode stays on its padded canvas whether or not there is a dot to
        // draw, so the item is the same width empty or not and the menu bar
        // never reflows. Every other style uses the unpadded glyph, keeping Off
        // as narrow as it can be.
        if SettingsManager.shared.menuBarIndicatorStyle == .dot {
            button.image = indicator == .dot ? dottedIcon : dotModeEmptyIcon
        } else {
            button.image = plainIcon
        }
        button.appearsDisabled = isPaused
    }

    /// The indicator the current preferences resolve to for `count` comments.
    private func currentIndicator(count: Int) -> SettingsManager.MenuBarIndicator {
        let settings = SettingsManager.shared
        return settings.menuBarIndicatorStyle.indicator(
            forCommentCount: count,
            hidesCountAtZero: settings.hidesMenuBarCountAtZero
        )
    }

    private func refreshIndicator(count: Int, animated: Bool = true) {
        guard let button = statusItem?.button else { return }
        // Don't overwrite mid-bounce or pre-bounce — the bounce shows the new count
        guard bounceTimer == nil, !pendingBounce else { return }

        let indicator = currentIndicator(count: count)
        // Pop the dot in when it arrives from outside the composer, which is how
        // an agent or the extension adds a comment - those never run the save
        // bounce. Only on a real transition: `lastIndicator` is nil on the first
        // paint after launch, where an animation would just be noise.
        let appearing = animated && indicator == .dot && lastIndicator != nil && lastIndicator != .dot
        lastIndicator = indicator

        apply(indicator, to: button)
        if appearing { animateDotPopIn(on: button) }
    }

    /// What was last painted, so a dot arriving can be told from one already there.
    private var lastIndicator: SettingsManager.MenuBarIndicator?

    private func apply(_ indicator: SettingsManager.MenuBarIndicator, to button: NSStatusBarButton) {
        // The corner dot rides on the icon itself rather than the button title,
        // so it costs no status item width. That is the whole point of the mode:
        // a menu bar that never reflows when comments appear (issue #8).
        applyIcon(for: indicator, isPaused: SettingsManager.shared.isPaused, to: button)
        guard let metrics = Self.metrics(for: indicator, iconHeight: indicatorHeight) else {
            button.title = ""
            return
        }
        button.attributedTitle = Self.attributedIndicator(metrics: metrics, scale: 1)
    }

    // MARK: - Corner Dot

    private static let cornerDotDiameter: CGFloat = 5.5

    /// Transparent ring cleared out of the glyph around the dot.
    ///
    /// Without it the dot is only as visible as its contrast against both the
    /// glyph and whatever wallpaper shows through the menu bar, which on a blue
    /// desktop is nearly nothing. Knocking a hole in the glyph gives the dot a
    /// gap of pure background on every side, the way the battery icon separates
    /// its charging bolt from the fill.
    private static let cornerDotGap: CGFloat = 1.5

    /// The plain glyph, used whenever there is no dot to show.
    private lazy var plainIcon: NSImage? = {
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        return icon
    }()

    /// Canvas the glyph gets in dot mode, beyond the glyph's own size.
    ///
    /// The badge has to hang off the mark rather than sit on it: the R fills its
    /// box, so a dot placed inside it puts the separating ring straight through
    /// the bowl and breaks the letterform. Hanging it outside costs width, and
    /// the status item is anchored on its right edge, so the mark sits that much
    /// further left in this mode. That shift happens once, when the setting
    /// changes; nothing moves while comments come and go, which is the point.
    ///
    /// Vertical is per edge, and deliberately so. Padding only the top would
    /// leave the glyph low in a centered image, off the baseline the rest of the
    /// menu bar shares. It stays 1pt because an image taller than the menu bar
    /// gets scaled down, shrinking the glyph.
    private static let dotCanvasPadRight: CGFloat = 4
    private static let dotCanvasPadVertical: CGFloat = 1

    /// The glyph with the dot on its top-right corner.
    private lazy var dottedIcon: NSImage? = Self.makeDottedIcon(dotScale: 1)

    /// Dot mode with nothing to show: the same padded canvas, no dot drawn.
    ///
    /// Dot mode must use this rather than `plainIcon`, which is narrower by the
    /// overhang. Falling back to the plain glyph makes the item jump the moment
    /// the first comment lands - the exact reflow this mode exists to avoid.
    private lazy var dotModeEmptyIcon: NSImage? = Self.makeDottedIcon(dotScale: 0)

    /// The same glyph with the dot drawn at `dotScale`, for the pop-in.
    ///
    /// Every frame keeps the full canvas and the dot's centre, so only the dot
    /// changes size - the status item's width never moves during the animation.
    private static func makeDottedIcon(dotScale: CGFloat) -> NSImage? {
        guard let base = NSImage(named: "MenuBarIcon") else { return nil }
        let glyphSize = base.size
        let canvas = NSSize(width: glyphSize.width + dotCanvasPadRight,
                            height: glyphSize.height + dotCanvasPadVertical * 2)

        let image = NSImage(size: canvas, flipped: false) { _ in
            // Vertically centered; the spare width on the right is the overhang.
            base.draw(in: CGRect(origin: CGPoint(x: 0, y: dotCanvasPadVertical),
                                 size: glyphSize))

            let full = CGRect(
                x: canvas.width - cornerDotFootprint,
                y: canvas.height - cornerDotFootprint,
                width: cornerDotFootprint,
                height: cornerDotFootprint
            )
            // Scale the ring with the dot, about a fixed centre. At small scales
            // the ring barely clears anything, so the dot reads as growing out
            // of the mark rather than a hole opening ahead of it.
            let centre = CGPoint(x: full.midX, y: full.midY)
            func scaled(_ diameter: CGFloat) -> CGRect {
                let d = diameter * dotScale
                return CGRect(x: centre.x - d / 2, y: centre.y - d / 2, width: d, height: d)
            }

            // destinationOut clears alpha instead of painting over it, so the
            // ring reads as a hole rather than a colored disc.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: scaled(cornerDotFootprint)).fill()

            // The dot goes back into the same alpha channel, so the menu bar
            // tints it exactly like the glyph and it is legible wherever the
            // glyph is. A fixed color cannot promise that: the menu bar is
            // translucent over whatever wallpaper the user has, and blue on a
            // blue desktop disappears.
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: scaled(cornerDotDiameter)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Pop-in frames for the dot, on the same curve as the count pill's bounce.
    /// Built once and reused: they never vary, unlike the pill, whose width
    /// depends on the number in it.
    private lazy var dotBounceFrames: [NSImage] = Self.bounceScales.compactMap {
        Self.makeDottedIcon(dotScale: $0)
    }

    /// The dot plus its separating ring.
    private static var cornerDotFootprint: CGFloat { cornerDotDiameter + cornerDotGap * 2 }

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

    /// Animate the current indicator with a bounce effect (pop in and settle).
    /// Call from fly-animation completion handlers for a "landing impact" feel.
    ///
    /// Bounces whatever the user's style resolves to (count pill or corner dot)
    /// and no-ops for `.off`, which has nothing on screen to animate.
    public func animateBadgeBounce() {
        pendingBounce = false
        guard let button = statusItem?.button else { return }

        // Cancel any in-progress bounce
        cancelBounce()

        let count = PersistenceManager.shared.unresolvedCommentCount
        let indicator = currentIndicator(count: count)

        // Paint the indicator before deciding whether there is anything to
        // animate. This call is the only thing that shows the dot on a save:
        // `prepareBadgeBounce` suppressed the count observer, so if this method
        // returns early the glyph keeps whatever it had until some unrelated
        // repaint. Anything that bails below must bail *after* this.
        applyIcon(for: indicator, isPaused: SettingsManager.shared.isPaused, to: button)

        // The dot has no title to animate; it pops in on the glyph instead.
        guard let metrics = Self.metrics(for: indicator, iconHeight: indicatorHeight) else {
            button.title = ""
            if indicator == .dot { animateDotPopIn(on: button) }
            return
        }

        // Pre-render all frames into fixed-size canvases so button width stays
        // constant. Each frame draws the scaled shape centered in that canvas.
        let frames = Self.bounceScales.map { Self.attributedIndicator(metrics: metrics, scale: $0) }
        runBounce(frames.count) { [weak button] index in
            button?.attributedTitle = frames[index]
        }
    }

    /// Grow the dot in on the same curve the count pill bounces on, by swapping
    /// pre-rendered glyphs. The frames are images rather than title attachments
    /// because that is where the dot lives.
    private func animateDotPopIn(on button: NSStatusBarButton) {
        let frames = dotBounceFrames
        guard !frames.isEmpty else { return }
        runBounce(frames.count) { [weak button] index in
            button?.image = frames[index]
        }
    }

    /// Bounce curve: smooth grow-in, gentle overshoot, settle.
    /// 14 frames × 35ms = ~490ms total.
    private static let bounceScales: [CGFloat] = [
        0.20, 0.48, 0.72, 0.88, 0.98,  // ease-out grow (5 frames)
        1.06, 1.10, 1.08,                // gentle overshoot (3 frames)
        1.03, 1.00, 0.97,                // settle (3 frames)
        0.99, 1.00, 1.00,                // rest (3 frames)
    ]

    private func runBounce(_ frameCount: Int, apply: @escaping (Int) -> Void) {
        cancelBounce()
        var frameIndex = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(35))
        timer.setEventHandler { [weak self] in
            guard frameIndex < frameCount else {
                timer.cancel()
                self?.bounceTimer = nil
                return
            }
            apply(frameIndex)
            frameIndex += 1
        }
        bounceTimer = timer
        timer.resume()
    }

    private func cancelBounce() {
        bounceTimer?.cancel()
        bounceTimer = nil
    }

    private static let badgeFontSize: CGFloat = 10

    /// Padding around the shape to prevent shadow/border clipping.
    private static let badgePadding: CGFloat = 2.0

    /// Height of the menu bar icon, which the indicator is sized against.
    private var indicatorHeight: CGFloat {
        statusItem?.button?.image?.size.height ?? 18
    }

    /// Geometry for one indicator: a fixed canvas (so button width stays constant
    /// while bouncing) plus the shape drawn centered inside it. `nil` means there
    /// is nothing to draw.
    private struct IndicatorMetrics {
        let canvasSize: NSSize
        /// Shape size at scale 1, centered in the canvas.
        let shapeSize: NSSize
        /// Centered digits for the count pill; `nil` for the dot.
        let text: String?
    }

    private static func metrics(for indicator: SettingsManager.MenuBarIndicator,
                                iconHeight: CGFloat) -> IndicatorMetrics? {
        let pad = badgePadding
        switch indicator {
        case .none:
            return nil

        case .count(let count):
            let text = "\(count)"
            // Measure text at base size to determine pill width
            let baseFont = NSFont.monospacedDigitSystemFont(ofSize: badgeFontSize, weight: .bold)
            let baseTextSize = (text as NSString).size(withAttributes: [.font: baseFont])
            // Pill sized to match menu bar icon height; width expands for wider numbers
            let pillWidth = max(iconHeight, baseTextSize.width + 10)
            return IndicatorMetrics(
                canvasSize: NSSize(width: pillWidth + pad * 2, height: iconHeight + pad * 2),
                shapeSize: NSSize(width: pillWidth, height: iconHeight),
                text: text
            )

        case .dot:
            // Drawn into the glyph image by `makeDotModeIcon`, not in the title.
            return nil
        }
    }

    private static func attributedIndicator(metrics: IndicatorMetrics, scale: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image(for: metrics, scale: scale)
        // Vertically center with the status bar icon (offset from text baseline).
        // Driven by canvas height, not shape height, so pill and dot share a
        // centerline and neither jumps when the style changes.
        let pad = badgePadding
        let innerHeight = metrics.canvasSize.height - pad * 2
        let yOffset = -round(innerHeight * 0.28) - pad
        attachment.bounds = CGRect(x: 0, y: yOffset,
                                   width: metrics.canvasSize.width,
                                   height: metrics.canvasSize.height)

        let attributed = NSMutableAttributedString(string: "\u{2009}")
        attributed.append(NSAttributedString(attachment: attachment))
        return attributed
    }

    private static func image(for metrics: IndicatorMetrics, scale: CGFloat) -> NSImage {
        let image = NSImage(size: metrics.canvasSize, flipped: false) { rect in
            let width = metrics.shapeSize.width * scale
            let height = metrics.shapeSize.height * scale
            let shapeRect = CGRect(
                x: (rect.width - width) / 2,
                y: (rect.height - height) / 2,
                width: width,
                height: height
            )
            drawIndicatorShape(in: shapeRect, text: metrics.text, fontSize: badgeFontSize * scale)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Draws the indicator (fill + shadow + border, plus centered digits when
    /// `text` is non-nil) into the current graphics context. A square rect yields
    /// the dot; a wider one yields the count pill.
    private static func drawIndicatorShape(in pillRect: CGRect, text: String?, fontSize: CGFloat) {
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

        // Light inner border for contrast. Skipped on the first bounce frames,
        // where the scaled-down shape is too small to inset without inverting.
        let bw: CGFloat = 1.0
        let strokeRect = pillRect.insetBy(dx: bw / 2, dy: bw / 2)
        if strokeRect.width > 0, strokeRect.height > 0 {
            NSColor.white.withAlphaComponent(0.15).setStroke()
            let strokePath = NSBezierPath(roundedRect: strokeRect,
                                          xRadius: strokeRect.height / 2, yRadius: strokeRect.height / 2)
            strokePath.lineWidth = bw
            strokePath.stroke()
        }

        // The dot carries no digits
        guard let text else { return }

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
