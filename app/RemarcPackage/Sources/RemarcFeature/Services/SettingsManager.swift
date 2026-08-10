import Foundation
import Combine
import ServiceManagement
import KeyboardShortcuts

@MainActor
public final class SettingsManager: ObservableObject {
    public static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    /// Subset of keys that must be readable outside @MainActor (e.g. CGEventTap callbacks).
    nonisolated static let fnKeyDictationKey = "dictationUsesFnKey"
    nonisolated static let fnKeyHandsFreeKey = "dictationHandsFreeUsesFnKey"
    nonisolated static let dictationEnabledKey = "dictationEnabled"

    private enum Keys {
        static let isPaused = "isPaused"
        static let outputFormat = "outputFormat"
        static let selectionDetectionMode = "selectionDetectionMode"
        static let includeMetadataInExport = "includeMetadataInExport"
        static let historyRetentionDays = "historyRetentionDays"
        static let imageRetentionDays = "imageRetentionDays"

        static let excludedAppBundleIDs = "excludedAppBundleIDs"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let hasSeenMenuBarTooltip = "hasSeenMenuBarTooltip"
        static let widgetCorner = "widgetCorner"
        static let normalizeWhitespace = "normalizeWhitespace"
        static let copyScreenshotToClipboard = "copyScreenshotToClipboard"
        static let deleteResolvedComments = "deleteResolvedComments" // legacy migration key
        static let resolvedCommentDeletion = "resolvedCommentDeletion"
        static let autoClearAfterExport = "autoClearAfterExport" // legacy migration key
        static let clearAfterExportBehavior = "clearAfterExportBehavior"
        static let referenceStyle = "referenceStyle"
        static let numberingStyle = "numberingStyle"
        static let dividerStyle = "dividerStyle"
        static let exportDateFormat = "exportDateFormat"
        static let includeSource = "includeSource"
        static let includeDate = "includeDate"
        static let includeStatus = "includeStatus"
        static let includeTime = "includeTime"
        static let commentPrefixStyle = "commentPrefixStyle"
        static let timeFormat = "timeFormat"
        static let metadataDividerStyle = "metadataDividerStyle"
        static let hasSeenCritModeOnboarding = "hasSeenCritModeOnboarding"
        static let autoSaveVoiceNotes = "autoSaveVoiceNotes"
        static let autoSaveDelay = "autoSaveDelay"
        static let includeRemarkID = "includeRemarkID"
        static let includeAIHint = "includeAIHint"
        static let showInDock = "showInDock"
        static let includeType = "includeType"

        static let hasExtensionEverConnected = "hasExtensionEverConnected"
        static let webContextReactEnabled = "webContextReactEnabled"
        static let webContextStylesEnabled = "webContextStylesEnabled"
        static let webContextAccessibilityEnabled = "webContextAccessibilityEnabled"
        static let webContextLayoutEnabled = "webContextLayoutEnabled"
        static let webContextIdentityEnabled = "webContextIdentityEnabled"
        static let webContextHyperframesEnabled = "webContextHyperframesEnabled"

        static let extensionGrabElementShortcut = "extensionGrabElementShortcut"
        static let extensionRegionSelectShortcut = "extensionRegionSelectShortcut"
        static let transcriptionEngine = "transcriptionEngine"
        static let whisperKitModel = "whisperKitModel"
        static let parakeetModelVersion = "parakeetModelVersion"
        static let pauseMusicWhileRecording = "pauseMusicWhileRecording"
        static let smartMicrophoneSelection = "smartMicrophoneSelection"
        static let soundEffectsEnabled = "soundEffectsEnabled"
        static let transcriptionRetentionDays = "transcriptionRetentionDays"
        static let dictationHandsFreeMode = "dictationHandsFreeMode"
        static let dictationUsesFnKey = SettingsManager.fnKeyDictationKey
        static let dictationHandsFreeUsesFnKey = SettingsManager.fnKeyHandsFreeKey
        static let dictationEnabled = SettingsManager.dictationEnabledKey
        static let keepModelInMemory = "keepModelInMemory"
        static let preloadModelOnLaunch = "preloadModelOnLaunch"

        static let claudeCodeEnabled = "claudeCodeEnabled"
        static let claudeCodeAutoCreateSession = "claudeCodeAutoCreateSession"
        static let wakeOnCommentEnabled = "wakeOnCommentEnabled"
        static let wakeHooksAvailable = "wakeHooksAvailable"
        static let claudeCodeSessionEndBehavior = "claudeCodeSessionEndBehavior"
        static let mcpUserDisabled = "mcpUserDisabled"
        static let pluginMigrationCompleted = "pluginMigrationCompleted"
        static let vocabularyHints = "vocabularyHints"
        static let tooltipPosition = "tooltipPosition"
        static let inactiveSessionCleanupEnabled = "inactiveSessionCleanupEnabled"
        static let inactiveSessionCleanupInterval = "inactiveSessionCleanupInterval"
        static let webhooksConfig = "webhooksConfig"
    }

    @Published public var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Keys.isPaused) }
    }

    @Published public var outputFormat: OutputFormat {
        didSet { defaults.set(outputFormat.rawValue, forKey: Keys.outputFormat) }
    }

    @Published public var selectionDetectionMode: SelectionDetectionMode {
        didSet { defaults.set(selectionDetectionMode.rawValue, forKey: Keys.selectionDetectionMode) }
    }

    @Published public var tooltipPosition: TooltipPosition {
        didSet { defaults.set(tooltipPosition.rawValue, forKey: Keys.tooltipPosition) }
    }

    @Published public var includeMetadataInExport: Bool {
        didSet { defaults.set(includeMetadataInExport, forKey: Keys.includeMetadataInExport) }
    }

    @Published public var historyRetentionDays: Int {
        didSet { defaults.set(historyRetentionDays, forKey: Keys.historyRetentionDays) }
    }

    @Published public var imageRetentionDays: Int {
        didSet { defaults.set(imageRetentionDays, forKey: Keys.imageRetentionDays) }
    }

    @Published public var excludedAppBundleIDs: [String] {
        didSet { defaults.set(excludedAppBundleIDs, forKey: Keys.excludedAppBundleIDs) }
    }

    @Published public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published public var showInDock: Bool {
        didSet { defaults.set(showInDock, forKey: Keys.showInDock) }
    }

    @Published public var hasSeenMenuBarTooltip: Bool {
        didSet { defaults.set(hasSeenMenuBarTooltip, forKey: Keys.hasSeenMenuBarTooltip) }
    }

    @Published public var normalizeWhitespace: Bool {
        didSet { defaults.set(normalizeWhitespace, forKey: Keys.normalizeWhitespace) }
    }

    @Published public var copyScreenshotToClipboard: Bool {
        didSet { defaults.set(copyScreenshotToClipboard, forKey: Keys.copyScreenshotToClipboard) }
    }

    @Published public var resolvedCommentDeletion: ResolvedCommentDeletion {
        didSet { defaults.set(resolvedCommentDeletion.rawValue, forKey: Keys.resolvedCommentDeletion) }
    }

    @Published public var inactiveSessionCleanupEnabled: Bool {
        didSet { defaults.set(inactiveSessionCleanupEnabled, forKey: Keys.inactiveSessionCleanupEnabled) }
    }

    @Published public var inactiveSessionCleanupInterval: InactiveSessionCleanupInterval {
        didSet { defaults.set(inactiveSessionCleanupInterval.rawValue, forKey: Keys.inactiveSessionCleanupInterval) }
    }

    @Published public var clearAfterExportBehavior: ClearAfterExportBehavior {
        didSet { defaults.set(clearAfterExportBehavior.rawValue, forKey: Keys.clearAfterExportBehavior) }
    }

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

    @Published public var includeTime: Bool {
        didSet { defaults.set(includeTime, forKey: Keys.includeTime) }
    }

    @Published public var commentPrefixStyle: CommentPrefixStyle {
        didSet { defaults.set(commentPrefixStyle.rawValue, forKey: Keys.commentPrefixStyle) }
    }

    @Published public var timeFormat: TimeFormat {
        didSet { defaults.set(timeFormat.rawValue, forKey: Keys.timeFormat) }
    }

    @Published public var metadataDividerStyle: MetadataDividerStyle {
        didSet { defaults.set(metadataDividerStyle.rawValue, forKey: Keys.metadataDividerStyle) }
    }

    @Published public var hasSeenCritModeOnboarding: Bool {
        didSet { defaults.set(hasSeenCritModeOnboarding, forKey: Keys.hasSeenCritModeOnboarding) }
    }

    @Published public var autoSaveVoiceNotes: Bool {
        didSet { defaults.set(autoSaveVoiceNotes, forKey: Keys.autoSaveVoiceNotes) }
    }

    @Published public var autoSaveDelay: AutoSaveDelay {
        didSet { defaults.set(autoSaveDelay.rawValue, forKey: Keys.autoSaveDelay) }
    }

    @Published public var includeRemarkID: Bool {
        didSet { defaults.set(includeRemarkID, forKey: Keys.includeRemarkID) }
    }

    @Published public var includeAIHint: Bool {
        didSet { defaults.set(includeAIHint, forKey: Keys.includeAIHint) }
    }

    @Published public var includeType: Bool {
        didSet { defaults.set(includeType, forKey: Keys.includeType) }
    }

    @Published public var widgetCorner: WidgetCorner {
        didSet { defaults.set(widgetCorner.rawValue, forKey: Keys.widgetCorner) }
    }

    @Published public var hasExtensionEverConnected: Bool {
        didSet { defaults.set(hasExtensionEverConnected, forKey: Keys.hasExtensionEverConnected) }
    }

    @Published public var webContextReactEnabled: Bool {
        didSet { defaults.set(webContextReactEnabled, forKey: Keys.webContextReactEnabled) }
    }

    @Published public var webContextStylesEnabled: Bool {
        didSet { defaults.set(webContextStylesEnabled, forKey: Keys.webContextStylesEnabled) }
    }

    @Published public var webContextAccessibilityEnabled: Bool {
        didSet { defaults.set(webContextAccessibilityEnabled, forKey: Keys.webContextAccessibilityEnabled) }
    }

    @Published public var webContextLayoutEnabled: Bool {
        didSet { defaults.set(webContextLayoutEnabled, forKey: Keys.webContextLayoutEnabled) }
    }

    @Published public var webContextIdentityEnabled: Bool {
        didSet { defaults.set(webContextIdentityEnabled, forKey: Keys.webContextIdentityEnabled) }
    }

    /// HyperFrames composition context attached to web-element/region/quickNote comments.
    /// Debug-only experimental feature. Defaults to `false` in release builds; the
    /// toggle is surfaced in Preferences → Experimental → HyperFrames Context (which is
    /// itself `#if DEBUG`-gated). When false, `WebContext.filtered()` nulls out
    /// `hyperframesContext` on save, so the field is dropped from persistence.
    @Published public var webContextHyperframesEnabled: Bool {
        didSet { defaults.set(webContextHyperframesEnabled, forKey: Keys.webContextHyperframesEnabled) }
    }

    @Published public var extensionGrabElementShortcut: ExtensionShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(extensionGrabElementShortcut) {
                defaults.set(data, forKey: Keys.extensionGrabElementShortcut)
            }
        }
    }
    @Published public var extensionRegionSelectShortcut: ExtensionShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(extensionRegionSelectShortcut) {
                defaults.set(data, forKey: Keys.extensionRegionSelectShortcut)
            }
        }
    }

    @Published public var transcriptionEngine: TranscriptionEngineType {
        didSet { defaults.set(transcriptionEngine.rawValue, forKey: Keys.transcriptionEngine) }
    }

    @Published public var whisperKitModel: WhisperKitModelSize {
        didSet { defaults.set(whisperKitModel.rawValue, forKey: Keys.whisperKitModel) }
    }

    @Published public var parakeetModelVersion: ParakeetModelVersion {
        didSet { defaults.set(parakeetModelVersion.rawValue, forKey: Keys.parakeetModelVersion) }
    }

    @Published public var pauseMusicWhileRecording: Bool {
        didSet { defaults.set(pauseMusicWhileRecording, forKey: Keys.pauseMusicWhileRecording) }
    }

    @Published public var smartMicrophoneSelection: Bool {
        didSet { defaults.set(smartMicrophoneSelection, forKey: Keys.smartMicrophoneSelection) }
    }

    @Published public var soundEffectsEnabled: Bool {
        didSet { defaults.set(soundEffectsEnabled, forKey: Keys.soundEffectsEnabled) }
    }

    @Published public var transcriptionRetentionDays: Int {
        didSet { defaults.set(transcriptionRetentionDays, forKey: Keys.transcriptionRetentionDays) }
    }

    @Published public var dictationHandsFreeMode: DictationHandsFreeMode {
        didSet { defaults.set(dictationHandsFreeMode.rawValue, forKey: Keys.dictationHandsFreeMode) }
    }

    @Published public var dictationUsesFnKey: Bool {
        didSet {
            defaults.set(dictationUsesFnKey, forKey: Keys.dictationUsesFnKey)
            guard dictationUsesFnKey else { return }
            if dictationHandsFreeUsesFnKey {
                dictationHandsFreeUsesFnKey = false
                ToastManager.shared.show("fn🌐 moved from Hands-free Shortcut")
            }
            KeyboardShortcuts.setShortcut(nil, for: .dictation)
        }
    }

    @Published public var dictationHandsFreeUsesFnKey: Bool {
        didSet {
            defaults.set(dictationHandsFreeUsesFnKey, forKey: Keys.dictationHandsFreeUsesFnKey)
            guard dictationHandsFreeUsesFnKey else { return }
            if dictationUsesFnKey {
                dictationUsesFnKey = false
                ToastManager.shared.show("fn🌐 moved from Push to Talk")
            }
            KeyboardShortcuts.setShortcut(nil, for: .dictationHandsFree)
        }
    }

    // MARK: - Dictation Toggle

    @Published public var dictationEnabled: Bool {
        didSet { defaults.set(dictationEnabled, forKey: Keys.dictationEnabled) }
    }

    // MARK: - Keep Model in Memory

    @Published public var keepModelInMemory: Bool {
        didSet {
            defaults.set(keepModelInMemory, forKey: Keys.keepModelInMemory)
            if keepModelInMemory {
                // Cancel any pending unload timers so a stale timer
                // doesn't evict a model the user wants kept in memory.
                WhisperKitModelManager.shared.cancelPendingUnloads()
                ParakeetModelManager.shared.cancelPendingUnloads()
            } else {
                WhisperKitModelManager.shared.scheduleUnloadIfIdle()
                ParakeetModelManager.shared.scheduleUnloadIfIdle()
                // Disable preload on launch when keep-in-memory is turned off
                if preloadModelOnLaunch {
                    preloadModelOnLaunch = false
                }
            }
        }
    }

    @Published public var preloadModelOnLaunch: Bool {
        didSet { defaults.set(preloadModelOnLaunch, forKey: Keys.preloadModelOnLaunch) }
    }

    // MARK: - Claude Code Integration

    @Published public var claudeCodeEnabled: Bool {
        didSet { defaults.set(claudeCodeEnabled, forKey: Keys.claudeCodeEnabled) }
    }

    /// Whether the comment composer offers "Send instantly & save", which hands
    /// a comment to a live Claude Code session instead of waiting for its next
    /// prompt. Off means the button is hidden and the flag is never written.
    @Published public var wakeOnCommentEnabled: Bool {
        didSet { defaults.set(wakeOnCommentEnabled, forKey: Keys.wakeOnCommentEnabled) }
    }

    /// Whether a session that can actually be woken is currently live.
    ///
    /// Deliberately not "is the plugin installed": that says nothing about
    /// which harness the user is working in. Codex sessions have no file-watch
    /// or rewake hook, so a Codex user with the Claude Code plugin installed
    /// would otherwise see a button promising something Codex cannot do.
    /// Sessions declare their own capability in their marker; see
    /// `WakeReachability`.
    @Published public var wakeHooksAvailable: Bool {
        didSet { defaults.set(wakeHooksAvailable, forKey: Keys.wakeHooksAvailable) }
    }

    /// Recompute from live session markers. Cheap: a directory listing and a
    /// few small reads, so the composer can call it as it opens.
    public func refreshWakeReachability() {
        let reachable = WakeReachability.anyWakeCapableSessionIsLive()
        if reachable != wakeHooksAvailable { wakeHooksAvailable = reachable }
    }

    /// True when any paired agent is live, which is what Preferences reports.
    /// The composer must ask about its own target session instead - see
    /// `wakeAvailable(for:)`.
    public var wakeAvailable: Bool { wakeOnCommentEnabled && wakeHooksAvailable }

    /// True when pressing the wake button on a comment filed to this session
    /// will actually reach an agent.
    ///
    /// Session-specific because wake is: only the agent paired with this
    /// session is woken. A comment filed to the Inbox, or to a session whose
    /// agent is not running, has nobody to interrupt, so the button must not
    /// offer to interrupt them.
    public func wakeAvailable(for remarcSessionID: UUID?) -> Bool {
        guard wakeOnCommentEnabled, let remarcSessionID else { return false }
        return WakeReachability.liveWakeCapableSessionExists(pairedTo: remarcSessionID)
    }

    @Published public var claudeCodeAutoCreateSession: Bool {
        didSet { defaults.set(claudeCodeAutoCreateSession, forKey: Keys.claudeCodeAutoCreateSession) }
    }

    @Published public var claudeCodeSessionEndBehavior: ClaudeCodeSessionEndBehavior {
        didSet { defaults.set(claudeCodeSessionEndBehavior.rawValue, forKey: Keys.claudeCodeSessionEndBehavior) }
    }

    @Published public var mcpUserDisabled: Bool {
        didSet { defaults.set(mcpUserDisabled, forKey: Keys.mcpUserDisabled) }
    }

    /// One-shot flag set by `LegacyInstallCleanup` after both:
    ///   1. Old skill file, settings.json hooks, and MCP registration are removed
    ///   2. The new `remarc` Claude Code plugin is detected installed
    /// Until both hold, cleanup retries on every launch.
    @Published public var pluginMigrationCompleted: Bool {
        didSet { defaults.set(pluginMigrationCompleted, forKey: Keys.pluginMigrationCompleted) }
    }

    @Published public var vocabularyHints: [String] {
        didSet { defaults.set(vocabularyHints, forKey: Keys.vocabularyHints) }
    }

    @Published public var webhooks: [Webhook] {
        didSet {
            if let data = try? JSONEncoder().encode(webhooks) {
                defaults.set(data, forKey: Keys.webhooksConfig)
            }
        }
    }

    /// Launch at Login — reads/writes directly via SMAppService
    public var launchAtLogin: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                debugLog("Failed to \(newValue ? "enable" : "disable") launch at login: \(error)")
            }
        }
    }

    private init() {
        self.isPaused = defaults.bool(forKey: Keys.isPaused)

        if let savedFormat = defaults.string(forKey: Keys.outputFormat),
           let format = OutputFormat(rawValue: savedFormat) {
            self.outputFormat = format
        } else {
            self.outputFormat = .markdown
        }

        if let savedMode = defaults.string(forKey: Keys.selectionDetectionMode),
           let mode = SelectionDetectionMode(rawValue: savedMode) {
            self.selectionDetectionMode = mode
        } else {
            self.selectionDetectionMode = .auto
        }

        if let savedPos = defaults.string(forKey: Keys.tooltipPosition),
           let pos = TooltipPosition(rawValue: savedPos) {
            self.tooltipPosition = pos
        } else {
            self.tooltipPosition = .above
        }

        if defaults.object(forKey: Keys.includeMetadataInExport) != nil {
            self.includeMetadataInExport = defaults.bool(forKey: Keys.includeMetadataInExport)
        } else {
            self.includeMetadataInExport = true
        }

        let savedRetention = defaults.integer(forKey: Keys.historyRetentionDays)
        self.historyRetentionDays = savedRetention > 0 ? savedRetention : AppConstants.defaultHistoryRetentionDays

        let savedImageRetention = defaults.integer(forKey: Keys.imageRetentionDays)
        self.imageRetentionDays = savedImageRetention > 0 ? savedImageRetention : AppConstants.defaultImageRetentionDays

        if defaults.object(forKey: Keys.normalizeWhitespace) != nil {
            self.normalizeWhitespace = defaults.bool(forKey: Keys.normalizeWhitespace)
        } else {
            self.normalizeWhitespace = true
        }
        self.copyScreenshotToClipboard = defaults.bool(forKey: Keys.copyScreenshotToClipboard)

        // Migration: old Bool deleteResolvedComments → new enum resolvedCommentDeletion
        if let saved = defaults.string(forKey: Keys.resolvedCommentDeletion),
           let value = ResolvedCommentDeletion(rawValue: saved) {
            self.resolvedCommentDeletion = value
        } else if defaults.object(forKey: Keys.deleteResolvedComments) != nil {
            // Migrate: old true → .immediately, old false → .never
            self.resolvedCommentDeletion = defaults.bool(forKey: Keys.deleteResolvedComments) ? .immediately : .never
        } else {
            self.resolvedCommentDeletion = .never
        }

        // Migration: old Bool autoClearAfterExport → new enum clearAfterExportBehavior
        if let saved = defaults.string(forKey: Keys.clearAfterExportBehavior),
           let value = ClearAfterExportBehavior(rawValue: saved) {
            self.clearAfterExportBehavior = value
        } else if defaults.object(forKey: Keys.autoClearAfterExport) != nil {
            // Migrate: old true → .delete, old false → .ask
            self.clearAfterExportBehavior = defaults.bool(forKey: Keys.autoClearAfterExport) ? .delete : .ask
        } else {
            self.clearAfterExportBehavior = .ask
        }

        self.inactiveSessionCleanupEnabled = defaults.bool(forKey: Keys.inactiveSessionCleanupEnabled)
        if let saved = defaults.string(forKey: Keys.inactiveSessionCleanupInterval),
           let value = InactiveSessionCleanupInterval(rawValue: saved) {
            self.inactiveSessionCleanupInterval = value
        } else {
            self.inactiveSessionCleanupInterval = .after4Hours
        }

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
        let metadataDefault = defaults.object(forKey: Keys.includeMetadataInExport) != nil
            ? defaults.bool(forKey: Keys.includeMetadataInExport)
            : true

        if defaults.object(forKey: Keys.includeSource) != nil {
            self.includeSource = defaults.bool(forKey: Keys.includeSource)
        } else {
            self.includeSource = metadataDefault
        }

        if defaults.object(forKey: Keys.includeDate) != nil {
            self.includeDate = defaults.bool(forKey: Keys.includeDate)
        } else {
            self.includeDate = metadataDefault
        }

        if defaults.object(forKey: Keys.includeStatus) != nil {
            self.includeStatus = defaults.bool(forKey: Keys.includeStatus)
        } else {
            self.includeStatus = false
        }

        self.includeTime = defaults.bool(forKey: Keys.includeTime)

        if let saved = defaults.string(forKey: Keys.commentPrefixStyle),
           let style = CommentPrefixStyle(rawValue: saved) {
            self.commentPrefixStyle = style
        } else {
            self.commentPrefixStyle = .comment
        }

        if let saved = defaults.string(forKey: Keys.timeFormat),
           let fmt = TimeFormat(rawValue: saved) {
            self.timeFormat = fmt
        } else {
            self.timeFormat = .twelve
        }

        if let saved = defaults.string(forKey: Keys.metadataDividerStyle),
           let style = MetadataDividerStyle(rawValue: saved) {
            self.metadataDividerStyle = style
        } else {
            self.metadataDividerStyle = .pipe
        }

        self.excludedAppBundleIDs = defaults.stringArray(forKey: Keys.excludedAppBundleIDs) ?? []
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.showInDock = defaults.bool(forKey: Keys.showInDock)
        self.hasSeenMenuBarTooltip = defaults.bool(forKey: Keys.hasSeenMenuBarTooltip)
        self.hasSeenCritModeOnboarding = defaults.bool(forKey: Keys.hasSeenCritModeOnboarding)
        self.autoSaveVoiceNotes = defaults.bool(forKey: Keys.autoSaveVoiceNotes)

        if let saved = defaults.string(forKey: Keys.autoSaveDelay),
           let delay = AutoSaveDelay(rawValue: saved) {
            self.autoSaveDelay = delay
        } else {
            self.autoSaveDelay = .twoSeconds
        }

        if defaults.object(forKey: Keys.includeRemarkID) != nil {
            self.includeRemarkID = defaults.bool(forKey: Keys.includeRemarkID)
        } else {
            self.includeRemarkID = true
        }

        if defaults.object(forKey: Keys.includeAIHint) != nil {
            self.includeAIHint = defaults.bool(forKey: Keys.includeAIHint)
        } else {
            self.includeAIHint = true
        }

        if defaults.object(forKey: Keys.includeType) != nil {
            self.includeType = defaults.bool(forKey: Keys.includeType)
        } else {
            self.includeType = true
        }

        if let savedCorner = defaults.string(forKey: Keys.widgetCorner),
           let corner = WidgetCorner(rawValue: savedCorner) {
            self.widgetCorner = corner
        } else {
            self.widgetCorner = .bottomRight
        }

        self.hasExtensionEverConnected = defaults.bool(forKey: Keys.hasExtensionEverConnected)

        self.webContextReactEnabled = defaults.object(forKey: Keys.webContextReactEnabled) == nil
            ? true : defaults.bool(forKey: Keys.webContextReactEnabled)
        self.webContextStylesEnabled = defaults.object(forKey: Keys.webContextStylesEnabled) == nil
            ? true : defaults.bool(forKey: Keys.webContextStylesEnabled)
        self.webContextAccessibilityEnabled = defaults.object(forKey: Keys.webContextAccessibilityEnabled) == nil
            ? true : defaults.bool(forKey: Keys.webContextAccessibilityEnabled)
        self.webContextLayoutEnabled = defaults.object(forKey: Keys.webContextLayoutEnabled) == nil
            ? true : defaults.bool(forKey: Keys.webContextLayoutEnabled)
        self.webContextIdentityEnabled = defaults.object(forKey: Keys.webContextIdentityEnabled) == nil
            ? true : defaults.bool(forKey: Keys.webContextIdentityEnabled)
        // Debug-only / experimental — defaults FALSE so release builds never persist HF context.
        self.webContextHyperframesEnabled = defaults.object(forKey: Keys.webContextHyperframesEnabled) == nil
            ? false : defaults.bool(forKey: Keys.webContextHyperframesEnabled)

        if let data = defaults.data(forKey: Keys.extensionGrabElementShortcut),
           let shortcut = try? JSONDecoder().decode(ExtensionShortcut.self, from: data) {
            self.extensionGrabElementShortcut = shortcut
        } else {
            self.extensionGrabElementShortcut = .defaultGrabElement
        }
        if let data = defaults.data(forKey: Keys.extensionRegionSelectShortcut),
           let shortcut = try? JSONDecoder().decode(ExtensionShortcut.self, from: data) {
            self.extensionRegionSelectShortcut = shortcut
        } else {
            self.extensionRegionSelectShortcut = .defaultRegionSelect
        }

        if let saved = defaults.string(forKey: Keys.transcriptionEngine),
           let engine = TranscriptionEngineType(rawValue: saved) {
            self.transcriptionEngine = engine
        } else {
            self.transcriptionEngine = .appleSpeech
        }

        if let saved = defaults.string(forKey: Keys.whisperKitModel),
           let model = WhisperKitModelSize(rawValue: saved) {
            self.whisperKitModel = model
        } else {
            self.whisperKitModel = .balanced
        }

        if let saved = defaults.string(forKey: Keys.parakeetModelVersion),
           let version = ParakeetModelVersion(rawValue: saved) {
            self.parakeetModelVersion = version
        } else {
            self.parakeetModelVersion = .v3
        }

        self.pauseMusicWhileRecording = defaults.bool(forKey: Keys.pauseMusicWhileRecording)
        self.smartMicrophoneSelection = defaults.object(forKey: Keys.smartMicrophoneSelection) == nil
            ? true : defaults.bool(forKey: Keys.smartMicrophoneSelection)

        // Default to true when key has never been set
        if defaults.object(forKey: Keys.soundEffectsEnabled) == nil {
            self.soundEffectsEnabled = true
        } else {
            self.soundEffectsEnabled = defaults.bool(forKey: Keys.soundEffectsEnabled)
        }

        let savedTranscriptionRetention = defaults.integer(forKey: Keys.transcriptionRetentionDays)
        self.transcriptionRetentionDays = savedTranscriptionRetention > 0 ? savedTranscriptionRetention : AppConstants.defaultTranscriptionRetentionDays

        if let savedMode = defaults.string(forKey: Keys.dictationHandsFreeMode),
           let mode = DictationHandsFreeMode(rawValue: savedMode) {
            self.dictationHandsFreeMode = mode
        } else {
            self.dictationHandsFreeMode = .singleTap
        }

        self.dictationUsesFnKey = defaults.bool(forKey: Keys.dictationUsesFnKey)
        self.dictationHandsFreeUsesFnKey = defaults.bool(forKey: Keys.dictationHandsFreeUsesFnKey)

        // Dictation toggle — defaults to enabled
        self.dictationEnabled = defaults.object(forKey: Keys.dictationEnabled) == nil
            ? true : defaults.bool(forKey: Keys.dictationEnabled)

        // Keep model in memory — defaults to off
        self.keepModelInMemory = defaults.bool(forKey: Keys.keepModelInMemory)
        self.preloadModelOnLaunch = defaults.bool(forKey: Keys.preloadModelOnLaunch)

        // Claude Code Integration
        self.claudeCodeEnabled = defaults.bool(forKey: Keys.claudeCodeEnabled)
        // Off by default while the feature settles: waking an idle agent is a
        // deliberate choice, not something to opt users into silently.
        self.wakeOnCommentEnabled = defaults.bool(forKey: Keys.wakeOnCommentEnabled)
        self.wakeHooksAvailable = defaults.bool(forKey: Keys.wakeHooksAvailable)
        self.claudeCodeAutoCreateSession = defaults.object(forKey: Keys.claudeCodeAutoCreateSession) == nil
            ? true
            : defaults.bool(forKey: Keys.claudeCodeAutoCreateSession)
        self.mcpUserDisabled = defaults.bool(forKey: Keys.mcpUserDisabled)
        self.pluginMigrationCompleted = defaults.bool(forKey: Keys.pluginMigrationCompleted)
        self.vocabularyHints = defaults.stringArray(forKey: Keys.vocabularyHints) ?? VocabularyHints.defaultHints

        if let data = defaults.data(forKey: Keys.webhooksConfig),
           let decoded = try? JSONDecoder().decode([Webhook].self, from: data) {
            self.webhooks = decoded
        } else {
            self.webhooks = []
        }

        if let behaviorRaw = defaults.string(forKey: Keys.claudeCodeSessionEndBehavior),
           let behavior = ClaudeCodeSessionEndBehavior(rawValue: behaviorRaw) {
            self.claudeCodeSessionEndBehavior = behavior
        } else {
            // Keeping is the default because the alternative loses data:
            // autoDelete soft-deletes the session and every comment on it,
            // resolved history included.
            self.claudeCodeSessionEndBehavior = .keep
        }
    }

    // MARK: - Enums

    public enum InactiveSessionCleanupInterval: String, CaseIterable, Sendable {
        case after30Minutes, after1Hour, after2Hours, after4Hours, after6Hours, after12Hours, after24Hours

        public var label: String {
            switch self {
            case .after30Minutes: "After 30 min"
            case .after1Hour:     "After 1 hour"
            case .after2Hours:    "After 2 hours"
            case .after4Hours:    "After 4 hours"
            case .after6Hours:    "After 6 hours"
            case .after12Hours:   "After 12 hours"
            case .after24Hours:   "After 24 hours"
            }
        }

        public var interval: TimeInterval {
            switch self {
            case .after30Minutes: 30 * 60
            case .after1Hour:     60 * 60
            case .after2Hours:    2 * 60 * 60
            case .after4Hours:    4 * 60 * 60
            case .after6Hours:    6 * 60 * 60
            case .after12Hours:   12 * 60 * 60
            case .after24Hours:   24 * 60 * 60
            }
        }
    }

    public enum ResolvedCommentDeletion: String, CaseIterable, Sendable {
        case never, immediately, after15Minutes, after1Hour, after1Day

        public var label: String {
            switch self {
            case .never: "Never"
            case .immediately: "Immediately"
            case .after15Minutes: "After 15 min"
            case .after1Hour: "After 1 hour"
            case .after1Day: "After 1 day"
            }
        }

        public var interval: TimeInterval? {
            switch self {
            case .never: nil
            case .immediately: 0
            case .after15Minutes: 15 * 60
            case .after1Hour: 60 * 60
            case .after1Day: 24 * 60 * 60
            }
        }
    }

    public enum ClearAfterExportBehavior: String, CaseIterable, Sendable {
        case ask, keep, delete

        public var label: String {
            switch self {
            case .ask: "Always Ask"
            case .keep: "Always Keep"
            case .delete: "Always Delete"
            }
        }
    }

    public enum ClaudeCodeSessionEndBehavior: String, CaseIterable, Sendable {
        case autoDelete
        case keep
        case moveUnresolved

        public var label: String {
            switch self {
            case .autoDelete: "Delete session"
            case .keep: "Keep session"
            case .moveUnresolved: "Move unresolved to Inbox"
            }
        }
    }

    public enum OutputFormat: String, CaseIterable, Sendable {
        case markdown
        case json

        public var label: String {
            switch self {
            case .markdown: return "Markdown"
            case .json: return "JSON"
            }
        }

        public var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .json: return "json"
            }
        }
    }

    public enum WidgetCorner: String, CaseIterable, Sendable {
        case bottomRight
        case bottomLeft
        case topRight
        case topLeft
    }

    public enum TooltipPosition: String, CaseIterable, Sendable {
        case above
        case below

        public var label: String {
            switch self {
            case .above: return "Above selection"
            case .below: return "Below selection"
            }
        }
    }

    public enum SelectionDetectionMode: String, CaseIterable, Sendable {
        case auto
        case hotkeyOnly

        public var label: String {
            switch self {
            case .auto: return "Auto-detect + Hotkey"
            case .hotkeyOnly: return "Hotkey Only"
            }
        }
    }

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
        case doubleLine
        case dotted
        case blankLine

        public var label: String {
            switch self {
            case .horizontalRule: return "--- Rule"
            case .doubleLine: return "=== Double"
            case .dotted: return "\u{00B7}\u{00B7}\u{00B7} Dotted"
            case .blankLine: return "Blank Line"
            }
        }
    }

    public enum ExportDateFormat: String, CaseIterable, Sendable {
        case short
        case medium
        case long
        case iso
        case european

        public var label: String {
            let formatter = DateFormatter()
            switch self {
            case .short: formatter.dateFormat = "MMM d"
            case .medium: formatter.dateFormat = "MMM d, yyyy"
            case .long: formatter.dateFormat = "MMMM d, yyyy"
            case .iso: formatter.dateFormat = "yyyy-MM-dd"
            case .european: formatter.dateFormat = "dd/MM/yyyy"
            }
            return formatter.string(from: Date())
        }
    }

    public enum TimeFormat: String, CaseIterable, Sendable {
        case twelve
        case twentyFour

        public var label: String {
            switch self {
            case .twelve: return "12-hour"
            case .twentyFour: return "24-hour"
            }
        }

        public var use24Hour: Bool { self == .twentyFour }
    }

    public enum CommentPrefixStyle: String, CaseIterable, Sendable {
        case comment
        case note
        case dash
        case arrow
        case none

        public var label: String {
            switch self {
            case .comment: return "Comment:"
            case .note: return "Note:"
            case .dash: return "\u{2014} Dash"
            case .arrow: return "\u{2192} Arrow"
            case .none: return "None"
            }
        }
    }

    public enum MetadataDividerStyle: String, CaseIterable, Sendable {
        case pipe
        case dash
        case bullet
        case comma

        public var label: String {
            switch self {
            case .pipe: return "| Pipe"
            case .dash: return "\u{2014} Dash"
            case .bullet: return "\u{00B7} Dot"
            case .comma: return ", Comma"
            }
        }

        public var separator: String {
            switch self {
            case .pipe: return " | "
            case .dash: return " \u{2014} "
            case .bullet: return " \u{00B7} "
            case .comma: return ", "
            }
        }
    }

    public enum AutoSaveDelay: String, CaseIterable, Sendable {
        case oneSecond
        case onePointFiveSeconds
        case twoSeconds
        case threeSeconds
        case fourSeconds
        case fiveSeconds

        public var label: String {
            switch self {
            case .oneSecond: return "1s"
            case .onePointFiveSeconds: return "1.5s"
            case .twoSeconds: return "2s"
            case .threeSeconds: return "3s"
            case .fourSeconds: return "4s"
            case .fiveSeconds: return "5s"
            }
        }

        public var duration: TimeInterval {
            switch self {
            case .oneSecond: return 1.0
            case .onePointFiveSeconds: return 1.5
            case .twoSeconds: return 2.0
            case .threeSeconds: return 3.0
            case .fourSeconds: return 4.0
            case .fiveSeconds: return 5.0
            }
        }
    }
}
