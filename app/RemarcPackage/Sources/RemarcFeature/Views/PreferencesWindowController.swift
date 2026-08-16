import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class PreferencesWindowController: NSObject, NSWindowDelegate {
    public static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private var resizeObserver: Any?

    /// Notification posted when a specific prefs tab should be selected.
    static let selectTabNotification = Notification.Name("PreferencesSelectTab")

    /// Notification posted when the window should resize for a section.
    static let resizeNotification = Notification.Name("PreferencesResize")

    /// UserDefaults key for persisting the selected settings section.
    static let selectedSectionKey = "selectedSettingsSection"

    /// Window dimensions per section type.
    static let exportSize = NSSize(width: 1100, height: 580)
    static let defaultSize = NSSize(width: 750, height: 730)

    public func show() {
        showWithTab("General")
    }

    public func show(tab: String) {
        showWithTab(tab)
    }

    private func showWithTab(_ tab: String) {
        // Dismiss the menu bar popover so it doesn't cover the settings window
        MenuBarPopoverController.shared.dismiss()

        if window == nil {
            // Persist the target tab before the view initializes so its @State
            // init reads it. Otherwise the view starts on the last-persisted
            // tab and the notification below can race the onReceive setup.
            UserDefaults.standard.set(tab, forKey: Self.selectedSectionKey)
            createWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ActivationPolicyManager.shared.register(self)

        // Post on the next runloop tick so SwiftUI's onReceive subscription is
        // active by the time the notification fires (covers the case where the
        // window already existed and a fresh @State init no longer runs).
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.selectTabNotification, object: tab)
        }
    }

    private func createWindow() {
        // Determine initial size from persisted section
        let isExport = UserDefaults.standard.string(forKey: Self.selectedSectionKey) == "Export"
        let initialSize = isExport ? Self.exportSize : Self.defaultSize

        let prefsView = PreferencesView()
        let hostingView = NSHostingView(rootView: prefsView)
        hostingView.sizingOptions = []  // Prevent intrinsic content size from stretching the window

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: initialSize.width, height: initialSize.height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Remarc Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.delegate = self

        // Listen for resize requests
        resizeObserver = NotificationCenter.default.addObserver(
            forName: Self.resizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isExport = notification.object as? Bool else { return }
            let targetSize = isExport ? Self.exportSize : Self.defaultSize
            self?.resizeWindow(to: targetSize)
        }
    }

    private func resizeWindow(to targetSize: NSSize) {
        guard let window else { return }
        let currentFrame = window.frame

        // Don't animate if already at the right size
        guard abs(currentFrame.width - targetSize.width) > 1
           || abs(currentFrame.height - targetSize.height) > 1 else { return }

        // Pin top edge, center width change horizontally
        let deltaWidth = targetSize.width - currentFrame.width
        let deltaHeight = targetSize.height - currentFrame.height
        let newFrame = NSRect(
            x: currentFrame.origin.x - deltaWidth / 2,
            y: currentFrame.origin.y - deltaHeight,  // pin top edge (macOS y is bottom-up)
            width: targetSize.width,
            height: targetSize.height
        )

        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(newFrame, display: true, animate: shouldAnimate)
    }

    public var isVisible: Bool {
        window?.isVisible == true
    }

    public var isMiniaturized: Bool {
        window?.isMiniaturized == true
    }

    public func bringBack() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ActivationPolicyManager.shared.register(self)
    }

    public func windowWillClose(_ notification: Notification) {
        ActivationPolicyManager.shared.unregister(self)
    }
}

// MARK: - Preferences View

struct PreferencesView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var mcpManager = MCPManager.shared
    @ObservedObject private var harnessManager = HarnessIntegrationManager.shared

    // Claude Code plugin install state (read-only detection via `claude plugin
    // list --json`; installs go through PluginInstaller's CLI calls).
    @State private var pluginState: PluginInstallState = .zero
    @State private var pluginStateChecked = false
    @State private var installingPlugins: Set<String> = []
    @State private var pluginErrors: [String: String] = [:]
    @State private var copiedPluginCommands: String?
    private let pluginDetector = PluginInstallDetector()

    // Codex plugin install state (read-only detection via `codex plugin list
    // --json`; installs go through CodexPluginInstaller's CLI calls).
    @State private var codexPluginState: CodexPluginState = .zero
    @State private var codexPluginChecked = false
    @State private var codexInstalling = false
    @State private var codexInstallError: String?
    private let codexDetector = CodexPluginDetector()
    @ObservedObject private var webSocketService = WebSocketService.shared
    @State private var pendingHarnesses: Set<SkillInstaller.Harness> = []
    @ObservedObject private var updateManager = UpdateManager.shared
    @ObservedObject private var modelManager = WhisperKitModelManager.shared
    @ObservedObject private var parakeetManager = ParakeetModelManager.shared
    @State private var selectedSection: SettingsSection = {
        if let raw = UserDefaults.standard.string(forKey: PreferencesWindowController.selectedSectionKey),
           let section = SettingsSection(rawValue: raw) {
            return section
        }
        return .general
    }()
    @State private var hoveredHighlight: ExportHighlight?
    @State private var excludedApps: [ExcludedAppInfo] = []
    @State private var excludedSelection: Set<String> = []
    @State private var claudeDesktopCopied = false
    @State private var manualJSONCopied = false
    @State private var manualSkillCopied = false
    @State private var manualNodePath: String?
    @State private var manualMCPPath: String?
    @State private var isResolvingManualPaths = false
    @State private var manualNodeResolutionFailed = false
    @State private var manualMCPPathMissing = false
    @State private var newVocabHint: String = ""
    @State private var showResetDataConfirm = false
    @ObservedObject private var webhookService = WebhookService.shared
    @State private var webhookEditorState: WebhookEditorState?
    @State private var testingWebhookIDs: Set<UUID> = []
    @State private var webhookPendingDelete: Webhook?

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general = "General"
        case shortcuts = "Shortcuts"
        case voice = "Voice"
        case export = "Export"
        case chromeExtension = "Chrome Extension"
        case mcpIntegrations = "MCP Integrations"
        case webhooks = "Webhooks"
        case excludedApps = "Excluded Apps"
        case about = "About"
        case experimental = "Experimental"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .shortcuts: return "command"
            case .voice: return "waveform"
            case .export: return "square.and.arrow.up"
            case .chromeExtension: return "globe"
            case .mcpIntegrations: return "puzzlepiece.extension"
            case .webhooks: return "bolt"
            case .excludedApps: return "app.dashed"
            case .about: return "info.circle"
            case .experimental: return "flask"
            }
        }
    }

    private var visibleSections: [SettingsSection] {
        SettingsSection.allCases.filter { section in
            #if !DEBUG
            if section == .experimental { return false }
            #endif
            if #available(macOS 26, *) { return true }
            return section != .voice
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 0) {
            List(selection: $selectedSection) {
                ForEach(visibleSections) { section in
                    if section == .chromeExtension {
                        Label {
                            Text(section.rawValue)
                        } icon: {
                            Image("ChromeLogo")
                                .resizable()
                                .renderingMode(.template)
                                .frame(width: 14, height: 14)
                        }
                        .font(.system(size: 13))
                        .tag(section)
                    } else {
                        Label(section.rawValue, systemImage: section.icon)
                            .font(.system(size: 13))
                            .tag(section)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .tint(Color.remarcPrimary(for: colorScheme))
            }
            .frame(width: 220)
            .background(Color.remarcBackgroundGradient(for: colorScheme).opacity(0.3))

            Divider()

            // Detail pane
            Group {
                switch selectedSection {
                case .general: generalSection
                case .shortcuts: shortcutsSection
                case .voice:
                    if #available(macOS 26, *) {
                        voiceSection
                    }
                case .export: exportSection
                case .chromeExtension: chromeExtensionSection
                case .mcpIntegrations: mcpIntegrationsSection
                case .webhooks: webhooksSection
                case .excludedApps: excludedAppsSection
                case .about: aboutSection
                case .experimental:
                    #if DEBUG
                    experimentalSection
                    #else
                    EmptyView()
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.remarcBackgroundGradient(for: colorScheme).opacity(0.3))
        }
        .onReceive(NotificationCenter.default.publisher(for: PreferencesWindowController.selectTabNotification)) { notification in
            if let raw = notification.object as? String,
               let section = SettingsSection(rawValue: raw) {
                selectedSection = section
            }
        }
        .onChange(of: selectedSection) { _, newValue in
            UserDefaults.standard.set(newValue.rawValue, forKey: PreferencesWindowController.selectedSectionKey)
            NotificationCenter.default.post(
                name: PreferencesWindowController.resizeNotification,
                object: newValue == .export
            )
        }
    }

    private var generalSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // App section
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("App", description: "Startup and detection behavior.")

                    toggleRow("Launch at Login", isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.launchAtLogin = $0 }
                    ))
                    VStack(alignment: .leading, spacing: 3) {
                        toggleRow("Show in Dock", isOn: $settings.showInDock)
                        Text("When enabled, Remarc always shows in the Dock. Otherwise, it only appears while Settings or Permissions are open.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        pickerRow("Detection mode", selection: $settings.selectionDetectionMode) { $0.label }
                        Text("Auto detects text selections automatically. Hotkey only waits for your shortcut.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    pickerRow("Tooltip position", selection: $settings.tooltipPosition) { $0.label }
                    pickerRow("Date format", selection: $settings.exportDateFormat) { $0.label }
                    pickerRow("Time format", selection: $settings.timeFormat) { $0.label }
                }

                Divider()

                // Clipboard section
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Clipboard", description: "How copied content is processed.")

                    toggleRow("Clean up whitespace", isOn: $settings.normalizeWhitespace)
                    toggleRow("Add screenshots to clipboard", isOn: $settings.copyScreenshotToClipboard)
                }

                Divider()

                // Retention section
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Retention", description: "How long comments and images are kept.")

                    settingsRow("History retention") {
                        RemarcDropdown(
                            selection: $settings.historyRetentionDays,
                            options: [1, 7, 30],
                            labelFor: { days in
                                switch days {
                                case 1: return "1 day"
                                case 7: return "1 week"
                                case 30: return "1 month"
                                default: return "\(days) days"
                                }
                            },
                            width: Self.pickerWidth
                        )
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        settingsRow("Image retention") {
                            RemarcDropdown(
                                selection: $settings.imageRetentionDays,
                                options: [7, 14, 30],
                                labelFor: { days in
                                    switch days {
                                    case 7: return "1 week"
                                    case 14: return "2 weeks"
                                    case 30: return "1 month"
                                    default: return "\(days) days"
                                    }
                                },
                                width: Self.pickerWidth
                            )
                        }
                        Text("Images are kept longer so exported references stay valid.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    pickerRow("Delete resolved", selection: $settings.resolvedCommentDeletion) { $0.label }

                    VStack(alignment: .leading, spacing: 3) {
                        toggleRow("Auto-delete inactive sessions", isOn: $settings.inactiveSessionCleanupEnabled)
                        Text("Sessions with no recent activity are moved to History. The Inbox, current session, and sessions with unresolved comments are never deleted.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if settings.inactiveSessionCleanupEnabled {
                        VStack(alignment: .leading, spacing: Self.itemSpacing) {
                            pickerRow("Delete after", selection: $settings.inactiveSessionCleanupInterval) { $0.label }
                        }
                        .padding(.leading, 20)
                    }
                }

            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { mcpManager.checkDependencies() }
    }

    private var shortcutsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                sectionHeader("App Shortcuts", description: "Global keyboard shortcuts for Remarc actions.") {
                    appShortcutsResetButton
                }

                settingsRow("Comment") {
                    ConflictAwareRecorder(name: .commentOnSelection)
                }
                settingsRow("Screenshot") {
                    ConflictAwareRecorder(name: .screenshotComment)
                }
                if settings.wakeOnCommentEnabled {
                    settingsRow("Screenshot & Send Instantly") {
                        ConflictAwareRecorder(name: .screenshotCommentWake)
                    }
                }
                settingsRow("Paste All") {
                    ConflictAwareRecorder(name: .pasteAllComments)
                }
                settingsRow("Open Remarc") {
                    ConflictAwareRecorder(name: .openRemarc)
                }
                settingsRow("Start Crit Mode") {
                    ConflictAwareRecorder(name: .startCritMode)
                }
                if #available(macOS 26, *) {
                    settingsRow("Paste Last Dictation") {
                        ConflictAwareRecorder(name: .pasteLastTranscription)
                    }
                    settingsRow("Voice Input", labelAccessory: { voiceSettingsGearButton }) {
                        ConflictAwareRecorder(name: .voiceInput)
                    }
                    settingsRow("Dictation", labelAccessory: { voiceSettingsGearButton }) {
                        if settings.dictationUsesFnKey {
                            Text("fn🌐")
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.06))
                                )
                        } else {
                            ConflictAwareRecorder(name: .dictation)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                sectionHeader("Chrome Shortcuts", description: "Keyboard shortcuts for the Chrome Extension.") {
                    extensionShortcutResetButton
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(webSocketService.isClientConnected ? Color.green : Color.primary.opacity(0.25))
                        .frame(width: 6, height: 6)
                    Text(webSocketService.isClientConnected ? "Extension connected" : "Extension not connected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                settingsRow("Grab Element") {
                    ExtensionShortcutRecorder(shortcut: $settings.extensionGrabElementShortcut)
                }
                settingsRow("Select Region") {
                    ExtensionShortcutRecorder(shortcut: $settings.extensionRegionSelectShortcut)
                }

                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                        .font(.system(size: 12))
                    Text("Use ⌃⇧ or ⌥⇧ combinations. ⌘ is not supported in Chrome.")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.remarcPrimary(for: colorScheme).opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.25), lineWidth: 1)
                )

            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @available(macOS 26, *)
    private var voiceSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                // Transcription Engine
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Transcription Engine", description: "Choose which engine converts speech to text.")

                    settingsRow("Engine") {
                        RemarcDropdown(
                            selection: $settings.transcriptionEngine,
                            options: Array(TranscriptionEngineType.allCases),
                            labelFor: { $0.rawValue },
                            trailingAccessoryFor: { engine, cs in
                                switch engine {
                                case .appleSpeech:
                                    return nil
                                case .whisperKit:
                                    return downloadIndicator(
                                        downloaded: modelManager.downloadState == .downloaded,
                                        colorScheme: cs
                                    )
                                case .parakeet:
                                    return downloadIndicator(
                                        downloaded: parakeetManager.downloadState == .downloaded,
                                        colorScheme: cs
                                    )
                                }
                            },
                            width: Self.pickerWidth
                        )
                    }

                    // Info box
                    VStack(alignment: .leading, spacing: 8) {
                        engineInfoRow(
                            icon: "apple.logo",
                            title: "Apple Speech",
                            description: "Built-in macOS transcription. No download required. Good accuracy, fully private."
                        )
                        engineInfoRow(
                            icon: "waveform",
                            title: "WhisperKit",
                            description: "OpenAI Whisper via CoreML. High accuracy, multiple model sizes."
                        )
                        engineInfoRow(
                            icon: "bolt.fill",
                            title: "Parakeet",
                            description: "NVIDIA Parakeet via CoreML. Fastest inference, excellent accuracy."
                        )
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.remarcPrimary(for: colorScheme).opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.15))
                            )
                    )
                }

                if settings.transcriptionEngine == .whisperKit {
                    Divider()

                    // WhisperKit Model
                    VStack(alignment: .leading, spacing: Self.itemSpacing) {
                        sectionHeader("WhisperKit Model", description: "Select model size. Larger models are more accurate but use more memory.")

                        pickerRow("Model", selection: $settings.whisperKitModel) { $0.label }

                        // Download status
                        modelDownloadStatus
                            .animation(.easeInOut(duration: 0.25), value: modelManager.downloadState)

                        if modelManager.downloadState != .downloaded
                            && modelManager.downloadState != .preparing {
                            if modelManager.hasAnyModelDownloaded() {
                                CalloutView(.info, "Using previously downloaded model until the new one is ready.")
                            } else {
                                CalloutView(.info, "Using Apple Speech until model is ready.")
                            }
                        }
                    }
                    .onChange(of: settings.whisperKitModel) { _, newModel in
                        modelManager.refreshDownloadState(for: newModel)
                    }
                    .onAppear {
                        modelManager.refreshDownloadState(for: settings.whisperKitModel)
                        // Auto-download if not yet downloaded
                        if modelManager.downloadState == .notDownloaded {
                            Task {
                                let _ = await modelManager.prepareModel(settings.whisperKitModel)
                            }
                        }
                    }
                }

                if settings.transcriptionEngine == .parakeet {
                    Divider()

                    // Parakeet Model
                    VStack(alignment: .leading, spacing: Self.itemSpacing) {
                        sectionHeader("Parakeet Model", description: "NVIDIA Parakeet on-device model via FluidAudio.")

                        pickerRow("Model", selection: $settings.parakeetModelVersion) { $0.label }

                        parakeetDownloadStatus
                            .animation(.easeInOut(duration: 0.25), value: parakeetManager.downloadState)

                        if parakeetManager.downloadState != .downloaded
                            && parakeetManager.downloadState != .preparing {
                            CalloutView(.info, "Using Apple Speech until model is ready.")
                        }
                    }
                    .onChange(of: settings.parakeetModelVersion) { _, newVersion in
                        parakeetManager.refreshDownloadState(for: newVersion)
                    }
                    .onAppear {
                        parakeetManager.refreshDownloadState(for: settings.parakeetModelVersion)
                        if parakeetManager.downloadState == .notDownloaded {
                            Task {
                                let _ = await parakeetManager.prepareModel(settings.parakeetModelVersion)
                            }
                        }
                    }
                }

                if settings.transcriptionEngine != .appleSpeech {
                    VStack(alignment: .leading, spacing: 3) {
                        toggleRow("Keep model in memory", isOn: $settings.keepModelInMemory)
                        Text("Prevents the model from being unloaded after use. Faster response times but uses more RAM (~200–500 MB depending on model). Recommended if you have 16 GB+ RAM.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if settings.keepModelInMemory {
                        VStack(alignment: .leading, spacing: 3) {
                            toggleRow("Load model on launch", isOn: $settings.preloadModelOnLaunch)
                            Text("Loads the model into memory when Remarc starts so dictation is instant on first use.")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.35))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 20)
                    }
                }

                Divider()

                // Shortcut
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Shortcut", description: "Keyboard shortcut for voice comments. Also editable in the Shortcuts tab.")

                    settingsRow("Voice Input") {
                        ConflictAwareRecorder(name: .voiceInput)
                    }
                }

                Divider()

                // Behavior
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Behavior", description: "Voice input behavior settings.")

                    toggleRow("Sound effects", isOn: $settings.soundEffectsEnabled)

                    VStack(alignment: .leading, spacing: 3) {
                        toggleRow("Mute audio while recording", isOn: $settings.pauseMusicWhileRecording)
                        Text("Mutes system audio when you start recording and restores it when you stop.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        toggleRow("Prefer Mac built-in mic", isOn: $settings.smartMicrophoneSelection)
                        Text("Uses known studio USB mics when present; otherwise prefers the Mac built-in microphone over AirPods and headset mics.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        toggleRow("Auto-save voice notes", isOn: $settings.autoSaveVoiceNotes)
                        Text("Automatically saves comments created with the voice shortcut. Does not apply to comments invoked manually.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if settings.autoSaveVoiceNotes {
                        pickerRow("Auto-save delay", selection: $settings.autoSaveDelay, width: 80) { $0.label }
                    }
                }

                Divider()

                // Dictation
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Dictation", description: "Transcribe speech directly into any text field. Uses the same engine selected above.")

                    VStack(alignment: .leading, spacing: 3) {
                        toggleRow("Enable dictation", isOn: $settings.dictationEnabled)
                        Text("When disabled, dictation shortcuts are ignored and the feature is fully off.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.35))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if settings.dictationEnabled {
                        settingsRow("Push to talk") {
                            ConflictAwareRecorder(name: .dictation)
                                .disabled(settings.dictationUsesFnKey)
                                .opacity(settings.dictationUsesFnKey ? 0.4 : 1.0)
                        }
                        toggleRow("Use fn🌐 key", isOn: $settings.dictationUsesFnKey)

                        pickerRow("Hands-free mode", selection: $settings.dictationHandsFreeMode) { $0.rawValue }

                        if settings.dictationHandsFreeMode == .customShortcut {
                            settingsRow("Hands-free shortcut") {
                                ConflictAwareRecorder(name: .dictationHandsFree)
                                    .disabled(settings.dictationHandsFreeUsesFnKey)
                                    .opacity(settings.dictationHandsFreeUsesFnKey ? 0.4 : 1.0)
                            }
                            toggleRow("Use fn🌐 key", isOn: $settings.dictationHandsFreeUsesFnKey)
                        }

                        settingsRow("Paste last dictation") {
                            ConflictAwareRecorder(name: .pasteLastTranscription)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            settingsRow("History retention") {
                                RemarcDropdown(
                                    selection: $settings.transcriptionRetentionDays,
                                    options: [1, 7, 30, 90],
                                    labelFor: { days in
                                        switch days {
                                        case 1: return "1 day"
                                        case 7: return "1 week"
                                        case 30: return "1 month"
                                        case 90: return "3 months"
                                        default: return "\(days) days"
                                        }
                                    },
                                    width: Self.pickerWidth
                                )
                            }
                            Text("How long dictation transcriptions are kept in history.")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.35))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Info card
                        VStack(alignment: .leading, spacing: 8) {
                            engineInfoRow(
                                icon: "hand.point.down",
                                title: "Push to talk",
                                description: "Hold the shortcut to record. Release to transcribe and paste into the focused text field."
                            )
                            engineInfoRow(
                                icon: "hand.tap",
                                title: "Hands-free",
                                description: {
                                    switch settings.dictationHandsFreeMode {
                                    case .singleTap:
                                        return "Tap the shortcut to start hands-free recording. A pill with Stop and Cancel buttons stays on screen."
                                    case .doubleTap:
                                        return "Double-tap the shortcut to start hands-free recording. A single tap does a quick record-and-paste."
                                    case .customShortcut:
                                        return "Press the hands-free shortcut to start recording. The push-to-talk shortcut is hold-only."
                                    }
                                }()
                            )
                            engineInfoRow(
                                icon: "escape",
                                title: "Cancel",
                                description: "Press Escape or click ✕ to discard without pasting."
                            )
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.remarcPrimary(for: colorScheme).opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.remarcPrimary(for: colorScheme).opacity(0.15))
                                )
                        )
                    }
                }

            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Model Download Status

    @available(macOS 26, *)
    @ViewBuilder
    private var modelDownloadStatus: some View {
        let state = modelManager.downloadState

        switch state {
        case .failed(let message):
            CalloutView(.error, "Download failed: \(message)", actionLabel: "Retry") {
                Task {
                    let _ = await modelManager.prepareModel(settings.whisperKitModel)
                }
            }

        default:
            // Unified layout for notDownloaded → downloading → preparing → downloaded
            VStack(alignment: .leading, spacing: 6) {
                // Row 1: Status icon + text + action button
                HStack(spacing: 6) {
                    Group {
                        switch state {
                        case .downloaded:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.remarcSuccess(for: colorScheme))
                        case .downloading, .preparing:
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                        default:
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.primary.opacity(0.4))
                        }
                    }
                    .font(.system(size: 11))

                    Group {
                        switch state {
                        case .downloaded:
                            Text("Downloaded")
                        case .downloading(let progress):
                            Text("Downloading \(settings.whisperKitModel.rawValue)... \(Int(progress * 100))%")
                        case .preparing:
                            Text("Preparing model...")
                        default:
                            Text(settings.whisperKitModel.label)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.6))
                    .contentTransition(.numericText())

                    Spacer()

                    // Action button — always on the status text row
                    switch state {
                    case .downloading:
                        textButton("Cancel") {
                            modelManager.cancelDownload()
                        }
                    case .downloaded:
                        textButton("Delete", color: Color.remarcError(for: colorScheme).opacity(0.8)) {
                            modelManager.deleteModel(settings.whisperKitModel)
                        }
                    case .notDownloaded:
                        textButton("Download") {
                            Task {
                                let _ = await modelManager.prepareModel(settings.whisperKitModel)
                            }
                        }
                    default:
                        EmptyView()
                    }
                }

                // Row 2: Progress bar (full width, no button)
                if case .downloading(let progress) = state {
                    ProgressView(value: progress)
                        .tint(Color.remarcPrimary(for: colorScheme))
                        .transition(.opacity)
                } else if case .preparing = state {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.remarcPrimary(for: colorScheme))
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Parakeet Download Status

    @available(macOS 26, *)
    @ViewBuilder
    private var parakeetDownloadStatus: some View {
        let state = parakeetManager.downloadState

        switch state {
        case .failed(let message):
            CalloutView(.error, "Download failed: \(message)", actionLabel: "Retry") {
                Task {
                    let _ = await parakeetManager.prepareModel(settings.parakeetModelVersion)
                }
            }

        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Group {
                        switch state {
                        case .downloaded:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.remarcSuccess(for: colorScheme))
                        case .downloading, .preparing:
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                        default:
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.primary.opacity(0.4))
                        }
                    }
                    .font(.system(size: 11))

                    Group {
                        switch state {
                        case .downloaded:
                            Text("Downloaded")
                        case .downloading(let progress):
                            Text("Downloading Parakeet... \(Int(progress * 100))%")
                        case .preparing:
                            Text("Preparing model...")
                        default:
                            Text(settings.parakeetModelVersion.label)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.6))
                    .contentTransition(.numericText())

                    Spacer()

                    switch state {
                    case .downloading:
                        textButton("Cancel") {
                            parakeetManager.cancelDownload()
                        }
                    case .downloaded:
                        textButton("Delete", color: Color.remarcError(for: colorScheme).opacity(0.8)) {
                            parakeetManager.deleteModel(settings.parakeetModelVersion)
                        }
                    case .notDownloaded:
                        textButton("Download") {
                            Task {
                                let _ = await parakeetManager.prepareModel(settings.parakeetModelVersion)
                            }
                        }
                    default:
                        EmptyView()
                    }
                }

                if case .downloading(let progress) = state {
                    ProgressView(value: progress)
                        .tint(Color.remarcPrimary(for: colorScheme))
                        .transition(.opacity)
                } else if case .preparing = state {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Color.remarcPrimary(for: colorScheme))
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Download Indicator

    private func downloadIndicator(downloaded: Bool, colorScheme cs: ColorScheme) -> AnyView {
        AnyView(
            Image(systemName: downloaded ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 11))
                .foregroundStyle(downloaded ? Color.remarcSuccess(for: cs) : .primary.opacity(0.4))
        )
    }

    // MARK: - Engine Info Row

    private func engineInfoRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Text button with hover state for settings CTAs.
    private func textButton(
        _ title: String,
        color: Color? = nil,
        restOpacity: Double = 0.8,
        action: @escaping () -> Void
    ) -> some View {
        TextButton(title: title, color: color ?? Color.remarcPrimary(for: colorScheme), restOpacity: restOpacity, action: action)
    }

    // MARK: - Settings Design System
    //
    // Labels are left-aligned, controls are right-aligned, using HStack { label; Spacer; control }.
    // Section headers use .headline-weight at 13pt, descriptions at 11pt secondary.
    // Toggles use .switch style (native macOS toggle, not checkbox).
    // Spacing: 20pt between sections, 10pt between items, 4pt header-to-description.

    private static let sectionSpacing: CGFloat = 20
    private static let itemSpacing: CGFloat = 10
    private static let headerDescriptionSpacing: CGFloat = 4
    private static let pickerWidth: CGFloat = 180

    private var appShortcutsResetButton: some View {
        textButton("Reset", restOpacity: 0.6) {
            KeyboardShortcuts.reset(.commentOnSelection, .screenshotComment, .screenshotCommentWake, .pasteAllComments, .voiceInput, .dictation, .dictationHandsFree, .pasteLastTranscription, .openRemarc, .startCritMode)
        }
    }

    /// Reset button for extension shortcuts, used in both Shortcuts and Chrome Extension tabs.
    private var extensionShortcutResetButton: some View {
        textButton("Reset", restOpacity: 0.6) {
            settings.extensionGrabElementShortcut = .defaultGrabElement
            settings.extensionRegionSelectShortcut = .defaultRegionSelect
        }
    }

    /// Section header with optional description subtitle and optional trailing view aligned to the title.
    private func sectionHeader(_ title: String, leadingIcon: String? = nil, description: String? = nil, badge: String? = nil, badgeTooltip: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Self.headerDescriptionSpacing) {
            HStack(spacing: 6) {
                if let leadingIcon {
                    Image(leadingIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let badge {
                    BadgeView(text: badge, tooltip: badgeTooltip, colorScheme: colorScheme)
                }
            }
            if let description {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionHeader<Trailing: View>(_ title: String, description: String? = nil, badge: String? = nil, badgeTooltip: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        VStack(alignment: .leading, spacing: Self.headerDescriptionSpacing) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let badge {
                    BadgeView(text: badge, tooltip: badgeTooltip, colorScheme: colorScheme)
                }
                Spacer()
                trailing()
            }
            if let description {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Inline hint with icon and descriptive text (info, warning, or muted).
    private func settingsHint(_ text: String, icon: String = "info.circle.fill", tint: Color) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A settings row: left-aligned label, right-aligned control, full-width.
    private func settingsRow<Content: View, Accessory: View>(
        _ label: String,
        highlight: ExportHighlight? = nil,
        @ViewBuilder labelAccessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                labelAccessory()
            }
            Spacer(minLength: 4)
            content()
        }
        .onHover { hovering in
            if let highlight {
                hoveredHighlight = hovering ? highlight : nil
            }
        }
    }

    private var voiceSettingsGearButton: some View {
        VoiceSettingsGearButton { selectedSection = .voice }
    }

    /// A picker row using custom RemarcDropdown for uniform width and proper hover states.
    private func pickerRow<T: Hashable & CaseIterable & RawRepresentable>(
        _ label: String,
        selection: Binding<T>,
        highlight: ExportHighlight? = nil,
        width: CGFloat = pickerWidth,
        labelFor: @escaping (T) -> String
    ) -> some View where T.AllCases: RandomAccessCollection {
        settingsRow(label, highlight: highlight) {
            RemarcDropdown(
                selection: selection,
                options: Array(T.allCases),
                labelFor: labelFor,
                width: width
            )
        }
    }

    /// A toggle row using the settingsRow pattern with native switch style.
    private func toggleRow(
        _ label: String,
        isOn: Binding<Bool>,
        highlight: ExportHighlight? = nil,
        disabled: Bool = false
    ) -> some View {
        settingsRow(label, highlight: highlight) {
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
        .opacity(disabled ? 0.5 : 1.0)
    }

    // MARK: - Export Tab

    private var exportSection: some View {
        HStack(alignment: .top, spacing: 32) {
            // Left column: controls
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                // Clipboard Format section
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(
                        "Clipboard Format",
                        description: "Controls how comments are formatted when copied to clipboard."
                    )

                    pickerRow("Reference prefix", selection: $settings.referenceStyle, highlight: .reference) { $0.label }
                    pickerRow("Comment prefix", selection: $settings.commentPrefixStyle, highlight: .commentPrefix) { $0.label }
                    pickerRow("List style", selection: $settings.numberingStyle, highlight: .numbering) { $0.label }
                    pickerRow("Comment dividers", selection: $settings.dividerStyle, highlight: .divider) { $0.label }
                    pickerRow("Metadata divider", selection: $settings.metadataDividerStyle, highlight: .metadataDivider) { $0.label }
                }

                Divider()

                // Metadata toggles
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(
                        "Include in Export",
                        description: "Choose which metadata to attach to each comment."
                    )

                    toggleRow("Type", isOn: $settings.includeType, highlight: .type)
                    toggleRow("Source app", isOn: $settings.includeSource, highlight: .source)
                    toggleRow("Date", isOn: $settings.includeDate, highlight: .date)
                    toggleRow("Include time", isOn: $settings.includeTime, highlight: .date, disabled: !settings.includeDate)
                    toggleRow("Status", isOn: $settings.includeStatus, highlight: .status)
                    toggleRow("Comment ID", isOn: $settings.includeRemarkID, highlight: .remarkID)
                    toggleRow("MCP hint", isOn: $settings.includeAIHint, highlight: .aiHint)
                    if settings.includeAIHint && settings.clearAfterExportBehavior == .delete {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 12))
                            Text("Always Delete is on, so comments are removed after copy and MCP tools won't find them to resolve.")
                                .font(.system(size: 11))
                                .foregroundStyle(.primary.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.orange.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                        )
                    }
                }

                Divider()

                // Behavior
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(
                        "After Export",
                        description: "What happens after copying or saving comments."
                    )

                    pickerRow("After copying", selection: $settings.clearAfterExportBehavior) { $0.label }
                }

                Divider()

                // File export format
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(
                        "File Export",
                        description: "Default format when saving comments to a file."
                    )

                    pickerRow("Format", selection: $settings.outputFormat) { $0.label }
                }

                Spacer()
            }
            .frame(width: 330)

            // Right column: live preview
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(
                    "Preview",
                    description: "Live preview of how your comments will look when copied."
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(exportPreviewLines) { line in
                            let lineHasHighlight = hoveredHighlight != nil
                                && line.segments.contains { $0.highlights.contains(hoveredHighlight!) }
                            let isEmpty = line.segments.allSatisfy { $0.text.isEmpty }

                            if isEmpty {
                                let emptyHighlight = hoveredHighlight != nil
                                    && line.segments.contains { $0.highlights.contains(hoveredHighlight!) }
                                Text(" ")
                                    .font(.system(size: 13, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(emptyHighlight ? Color.remarcPrimary(for: colorScheme).opacity(0.08) : .clear)
                                    )
                                    .animation(.easeInOut(duration: 0.15), value: hoveredHighlight)
                            } else {
                                let metadataHighlights: Set<ExportHighlight> = [.source, .date, .dateFormat, .status, .metadataDivider, .remarkID, .aiHint, .type]
                                let isMetadataLine = line.segments.contains { !$0.highlights.isDisjoint(with: metadataHighlights) }
                                line.segments.reduce(Text("")) { result, segment in
                                    let hit = hoveredHighlight != nil && segment.highlights.contains(hoveredHighlight!)
                                    let defaultColor: Color = isMetadataLine ? .primary.opacity(0.6) : .primary
                                    return result + Text(segment.text)
                                        .foregroundColor(hit ? Color.remarcPrimary(for: colorScheme) : defaultColor)
                                }
                                .font(.system(size: 13, design: .monospaced))
                                .lineLimit(isMetadataLine && line.segments.contains { $0.highlights.contains(.aiHint) } ? nil : 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(lineHasHighlight ? Color.remarcPrimary(for: colorScheme).opacity(0.08) : .clear)
                                )
                                .animation(.easeInOut(duration: 0.15), value: hoveredHighlight)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .padding(12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @Environment(\.colorScheme) private var colorScheme

    private var exportPreviewLines: [PreviewLine] {
        ExportManager.shared.previewLines(
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
            metadataDivider: settings.metadataDividerStyle,
            includeAIHint: settings.includeAIHint
        )
    }

    // MARK: - Extension Tab

    private var extensionStatusColor: Color {
        if webSocketService.serverError != nil { return .red }
        if !webSocketService.isRunning { return .orange }
        if webSocketService.isClientConnected { return .green }
        return .primary.opacity(0.2)
    }

    private var extensionStatusText: String {
        if let error = webSocketService.serverError { return error }
        if !webSocketService.isRunning { return "Starting server\u{2026}" }
        if webSocketService.isClientConnected { return "Extension connected" }
        if settings.hasExtensionEverConnected { return "Extension not connected" }
        return "Waiting for extension"
    }

    private var chromeExtensionSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Connection section
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Connection", description: "Chrome extension connectivity.") {
                        GetExtensionButton {
                            NSWorkspace.shared.open(AppConstants.chromeExtensionURL)
                        }
                    }

                    // Status row
                    HStack(spacing: 8) {
                        Circle()
                            .fill(extensionStatusColor)
                            .frame(width: 8, height: 8)
                        Text(extensionStatusText)
                            .font(.system(size: 13))
                        Spacer()
                        Text("Port \(AppConstants.webSocketPort)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.35))
                    }

                    // Server error state
                    if webSocketService.serverError != nil {
                        settingsHint("Another app may be using this port.", icon: "exclamationmark.triangle.fill", tint: Color.remarcWarning(for: colorScheme))
                        Button("Retry") {
                            webSocketService.retryServer()
                        }
                        .font(.system(size: 12))
                    }

                    // Reconnection hint
                    if webSocketService.isRunning && !webSocketService.isClientConnected && settings.hasExtensionEverConnected {
                        settingsHint("Open a Chrome tab to reconnect.", tint: Color.remarcInfo(for: colorScheme))
                    }

                    // First-time onboarding card
                    if !settings.hasExtensionEverConnected {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "puzzlepiece.extension")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Color.remarcPrimary(for: colorScheme))
                                Text("Get more context from web pages")
                                    .font(.system(size: 13, weight: .medium))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                onboardingBullet("React component names and file paths")
                                onboardingBullet("Computed styles and accessibility info")
                                onboardingBullet("Layout structure and nearby elements")
                            }

                            Button("Installation Guide\u{2026}") {
                                NSWorkspace.shared.open(AppConstants.chromeExtensionURL)
                            }
                            .font(.system(size: 12))
                        }
                    }
                }

                Divider()

                // Extension Shortcuts subsection
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Chrome Shortcuts", description: "Configure keyboard shortcuts for element capture.")

                    settingsRow("Grab Element") {
                        ExtensionShortcutRecorder(shortcut: $settings.extensionGrabElementShortcut)
                    }
                    settingsRow("Select Region") {
                        ExtensionShortcutRecorder(shortcut: $settings.extensionRegionSelectShortcut)
                    }

                    Text("Use ⌃⇧ or ⌥⇧ combinations. ⌘ is not supported in Chrome.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Button("Reset to Defaults") {
                        settings.extensionGrabElementShortcut = .defaultGrabElement
                        settings.extensionRegionSelectShortcut = .defaultRegionSelect
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }

                Divider()

                // Captured Metadata section
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader("Captured Metadata", description: "Choose which web context data is saved with comments.")

                    let disabled = !settings.hasExtensionEverConnected

                    metadataToggle("React components", detail: "Component name, file path, hierarchy",
                                   isOn: $settings.webContextReactEnabled, disabled: disabled)
                    metadataToggle("Computed styles", detail: "CSS properties on the element",
                                   isOn: $settings.webContextStylesEnabled, disabled: disabled)
                    metadataToggle("Accessibility", detail: "ARIA roles, labels, tab index",
                                   isOn: $settings.webContextAccessibilityEnabled, disabled: disabled)
                    metadataToggle("Layout & structure", detail: "Bounding box, parent, nearby elements",
                                   isOn: $settings.webContextLayoutEnabled, disabled: disabled)
                    metadataToggle("Element identity", detail: "CSS selector, HTML snippet, page URL",
                                   isOn: $settings.webContextIdentityEnabled, disabled: disabled)

                    if !settings.hasExtensionEverConnected {
                        settingsHint("Connect the extension to configure.", tint: .primary.opacity(0.35))
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { webSocketService.ensureStarted() }
    }

    private func metadataToggle(
        _ label: String,
        detail: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.45))
            }
            Spacer(minLength: 4)
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
        .opacity(disabled ? 0.5 : 1.0)
    }

    private func onboardingBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("\u{2022}")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.45))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.6))
        }
    }

    private enum IntegrationRowStatus {
        case installed(String)
        case warning(String)
        case absent(String)
        case inactive(String)
        case pending(String)
    }

    private var mcpIntegrationsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                instantDeliverySection
                Divider()
                claudeCodeIntegrationSection
                Divider()
                codexIntegrationSection
                Divider()
                harnessIntegrationSection(.cursor)
                Divider()
                claudeDesktopSection
                Divider()
                otherMCPClientsSection
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            mcpManager.checkDependencies()
            Task { await harnessManager.installAll() }
        }
        .task {
            await refreshPluginState()
            codexPluginState = await codexDetector.read()
            codexPluginChecked = true
            await resolveManualPaths()
        }
    }

    // MARK: - Webhooks Tab

    private var webhooksSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.itemSpacing) {
                sectionHeader(
                    "Webhooks",
                    description: "Send comment events to any service as HTTP POST requests."
                ) {
                    addWebhookButton
                }

                CalloutView(.info, "Works with Zapier, Make, n8n, IFTTT, Slack incoming webhooks, or any endpoint that accepts JSON.")

                if settings.webhooks.isEmpty {
                    Text("No webhooks yet. Add one to send comment events - created, resolved, deleted - to any URL, or send individual cards manually from their paperplane action.")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(settings.webhooks) { webhook in
                            webhookRow(webhook)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $webhookEditorState) { state in
            WebhookEditorSheet(state: state) { saved in
                if let index = settings.webhooks.firstIndex(where: { $0.id == saved.id }) {
                    settings.webhooks[index] = saved
                } else {
                    settings.webhooks.append(saved)
                }
            }
        }
        .confirmationDialog(
            "Delete webhook \"\(webhookPendingDelete?.name ?? "")\"?",
            isPresented: Binding(
                get: { webhookPendingDelete != nil },
                set: { if !$0 { webhookPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pending = webhookPendingDelete {
                    settings.webhooks.removeAll { $0.id == pending.id }
                }
                webhookPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                webhookPendingDelete = nil
            }
        }
    }

    private var addWebhookButton: some View {
        textButton("Add Webhook") {
            webhookEditorState = WebhookEditorState(webhook: Webhook(), isNew: true)
        }
        .help("Add a new webhook endpoint")
    }

    private func webhookRow(_ webhook: Webhook) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(webhook.name)
                        .font(.system(size: 13, weight: .medium))
                    webhookStatusIcon(webhook)
                }
                Text(webhook.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if testingWebhookIDs.contains(webhook.id) {
                ProgressView()
                    .controlSize(.small)
                    .help("Sending test event")
            } else {
                CardActionButton(icon: "paperplane", tooltip: "Send test event", tint: Color.remarcPrimary(for: colorScheme)) {
                    sendTestWebhook(webhook)
                }
            }
            CardActionButton(icon: "pencil", tooltip: "Edit", tint: Color.remarcPrimary(for: colorScheme)) {
                webhookEditorState = WebhookEditorState(webhook: webhook, isNew: false)
            }
            CardActionButton(icon: "trash", tooltip: "Delete", tint: Color.remarcError(for: colorScheme)) {
                webhookPendingDelete = webhook
            }
            Toggle("Enable \(webhook.name)", isOn: webhookEnabledBinding(webhook))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(webhook.isEnabled ? "Disable this webhook" : "Enable this webhook")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
        .opacity(webhook.isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    private func webhookStatusIcon(_ webhook: Webhook) -> some View {
        switch webhookService.lastDeliveries[webhook.id] {
        case .success(let date):
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.remarcSuccess(for: colorScheme))
                .help("Delivered at \(date.formatted(date: .omitted, time: .shortened))")
        case .failure(let date, let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.remarcWarning(for: colorScheme))
                .help("Failed at \(date.formatted(date: .omitted, time: .shortened)): \(message)")
        case nil:
            EmptyView()
        }
    }

    private func webhookEnabledBinding(_ webhook: Webhook) -> Binding<Bool> {
        Binding(
            get: { settings.webhooks.first(where: { $0.id == webhook.id })?.isEnabled ?? false },
            set: { newValue in
                if let index = settings.webhooks.firstIndex(where: { $0.id == webhook.id }) {
                    settings.webhooks[index].isEnabled = newValue
                }
            }
        )
    }

    // Feedback comes from the row's status icon - the toast overlay lives in the
    // menu bar popover, which is closed whenever Settings is open.
    private func sendTestWebhook(_ webhook: Webhook) {
        testingWebhookIDs.insert(webhook.id)
        Task { @MainActor in
            await webhookService.sendTest(webhook)
            testingWebhookIDs.remove(webhook.id)
        }
    }

    private var claudeCodeIntegrationSection: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                "Claude Code",
                description: "Remarc integrates through Claude Code plugins from the \(PluginInstaller.marketplaceSlug) marketplace."
            )

            pluginRow(
                plugin: "remarc",
                title: "remarc",
                subtitle: "Required. MCP server and skill for managing comments.",
                installed: pluginState.remarcInstalled,
                enabled: pluginState.remarcEnabled,
                healthy: pluginState.remarcInstalled,
                needsAction: !pluginState.remarcInstalled,
                actionTitle: "Install",
                installAllowed: true,
                checked: pluginStateChecked,
                installing: installingPlugins.contains("remarc"),
                manualCommands: PluginInstaller.manualCommands(plugin: "remarc"),
                installAction: { installPlugin("remarc") }
            )

            claudeCodeUpdateRow

            Divider()
                .padding(.vertical, 4)

            pluginRow(
                plugin: "remarc-hooks",
                title: "remarc-hooks",
                subtitle: "Optional, experimental. Auto-links Claude Code sessions to Remarc and injects open comments at session start.",
                installed: pluginState.remarcHooksInstalled,
                enabled: pluginState.remarcHooksEnabled,
                healthy: pluginState.remarcHooksInstalled,
                needsAction: !pluginState.remarcHooksInstalled,
                actionTitle: "Install",
                installAllowed: pluginState.remarcInstalled,
                checked: pluginStateChecked,
                installing: installingPlugins.contains("remarc-hooks"),
                manualCommands: PluginInstaller.manualCommands(plugin: "remarc-hooks"),
                installAction: { installPlugin("remarc-hooks") }
            )

            if pluginState.remarcHooksInstalled {
                hooksSettingsRows
            }
        }
    }

    /// The remarc plugin's update affordance: the exact update command, always
    /// copyable (Claude Code owns its own update lifecycle, so the app never
    /// runs it), elevated to a warning callout when the installed plugin is
    /// older than the version this app vendored, plus a pointer to auto-update.
    @ViewBuilder
    private var claudeCodeUpdateRow: some View {
        if pluginStateChecked && pluginState.remarcInstalled {
            let updateCommand = PluginInstaller.updateCommand(plugin: "remarc")
            let behind = PluginInstaller.updateAvailable(
                installedVersion: pluginState.remarcVersion,
                bundledVersion: BundledPluginVersion.remarc
            )
            VStack(alignment: .leading, spacing: 8) {
                if behind {
                    let have = pluginState.remarcVersion.map { " (you have \($0))" } ?? ""
                    CalloutView(.warning, "remarc \(BundledPluginVersion.remarc) is available\(have). Update for the latest fixes, including screenshots delivered as images.")
                }
                HStack(alignment: .center, spacing: 8) {
                    Text(updateCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(behind ? 0.7 : 0.55))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CardActionButton(
                        icon: copiedPluginCommands == "remarc-update" ? "checkmark" : "doc.on.doc",
                        tooltip: "Copy update command",
                        tint: Color.remarcPrimary(for: colorScheme)
                    ) {
                        copyCommands(updateCommand, key: "remarc-update")
                    }
                }
                settingsHint(
                    "Updates aren't automatic for this marketplace. Turn them on once: run /plugin, open Marketplaces, select remarc, then Enable auto-update.",
                    tint: .primary.opacity(0.35)
                )
            }
            .padding(.top, 2)
        }
    }

    private var instantDeliverySection: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                "Instant delivery",
                description: "Let a live, paired agent receive a newly saved comment without waiting for the next prompt."
            )

            toggleRow(
                "Allow comments to wake paired agent sessions",
                isOn: $settings.wakeOnCommentEnabled
            )

            settingsHint(
                "Send Instantly appears only when the selected Remarc session has a live pairing.",
                tint: .primary.opacity(0.35)
            )

            if settings.wakeOnCommentEnabled && !settings.wakeHooksAvailable {
                settingsHint(
                    "No live pairing is currently reachable. Pair from a supported agent session, then return to Remarc.",
                    tint: .primary.opacity(0.35)
                )
            }

            Link(
                "Set up OMP instant delivery",
                destination: URL(string: "https://github.com/metedata/remarc-agent-plugins/blob/main/docs/integrations/omp.md")!
            )
            .font(.system(size: 11))
        }
    }

    private var codexIntegrationSection: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                "Codex",
                description: "Remarc integrates through a Codex plugin from the \(CodexPluginInstaller.marketplaceSlug) marketplace."
            )

            pluginRow(
                plugin: "codex-remarc",
                title: "remarc",
                subtitle: "MCP server and skill for managing comments from Codex.",
                installed: codexPluginState.remarcInstalled,
                enabled: codexPluginState.remarcEnabled,
                healthy: codexHealthy,
                needsAction: !codexHealthy,
                actionTitle: codexPluginState.remarcInstalled ? "Repair" : "Install",
                installAllowed: true,
                checked: codexPluginChecked,
                installing: codexInstalling,
                manualCommands: CodexPluginInstaller.manualCommands(),
                installAction: { installCodexPlugin() }
            )

            if let error = codexInstallError {
                settingsHint(error, icon: "exclamationmark.triangle.fill", tint: Color.remarcWarning(for: colorScheme))
            }
        }
    }

    private var codexHealthy: Bool {
        codexPluginState.remarcInstalled
            && codexPluginState.remarcEnabled
            && (codexPluginState.remarcVersion.map(CodexPluginInstaller.isNumericVersion) ?? false)
    }

    private func installCodexPlugin() {
        guard !codexInstalling else { return }
        codexInstalling = true
        codexInstallError = nil
        Task { @MainActor in
            switch await CodexPluginInstaller.install() {
            case .success:
                break
            case .codexNotFound:
                codexInstallError = "Codex CLI not found. Install Codex first, or run the commands in a terminal."
            case .failed(let message):
                codexInstallError = message
            }
            codexPluginState = await codexDetector.read()
            codexPluginChecked = true
            codexInstalling = false
        }
    }

    private func pluginRowStatus(checked: Bool, installed: Bool, enabled: Bool, healthy: Bool) -> IntegrationRowStatus {
        if !checked { return .pending("Checking") }
        if installed && enabled && healthy { return .installed("Installed") }
        if installed && enabled { return .warning("Needs repair") }
        if installed { return .warning("Installed (disabled)") }
        return .inactive("Not installed")
    }

    /// One row per plugin: name + status, description, and - while
    /// `needsAction` - the exact commands the action button runs, a copy
    /// fallback, and the button itself. `installAllowed` hides the button
    /// for remarc-hooks until the required remarc plugin is present.
    @ViewBuilder
    private func pluginRow(
        plugin: String,
        title: String,
        subtitle: String,
        installed: Bool,
        enabled: Bool,
        healthy: Bool,
        needsAction: Bool,
        actionTitle: String,
        installAllowed: Bool,
        checked: Bool,
        installing: Bool,
        manualCommands: String,
        installAction: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    integrationStatusLabel(pluginRowStatus(checked: checked, installed: installed, enabled: enabled, healthy: healthy))
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                if checked && needsAction && !manualCommands.isEmpty {
                    Text(manualCommands)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.55))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if let error = pluginErrors[plugin] {
                    settingsHint(error, icon: "exclamationmark.triangle.fill", tint: Color.remarcWarning(for: colorScheme))
                }
            }

            Spacer(minLength: 8)

            if installing {
                ProgressView()
                    .controlSize(.small)
                    .help("Installing - the first run clones the marketplace and can take a minute")
            } else if checked && needsAction {
                if !manualCommands.isEmpty {
                    CardActionButton(
                        icon: copiedPluginCommands == plugin ? "checkmark" : "doc.on.doc",
                        tooltip: "Copy \(actionTitle.lowercased()) commands",
                        tint: Color.remarcPrimary(for: colorScheme)
                    ) {
                        copyCommands(manualCommands, key: plugin)
                    }
                }
                if installAllowed {
                    textButton(actionTitle) {
                        installAction()
                    }
                    .help("Runs the commands shown via the CLI")
                }
            }
        }
    }

    private var hooksSettingsRows: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            toggleRow("Auto-create session for new conversations", isOn: $settings.claudeCodeAutoCreateSession)

            if !settings.claudeCodeAutoCreateSession {
                settingsHint("Use the remarc_create_session MCP tool to create sessions manually", tint: .primary.opacity(0.35))
            }

            settingsHint("Quitting an agent only unlinks its session - the session and its comments stay. This applies when you clear the conversation, which is the one ending that means the work is done.", tint: .primary.opacity(0.35))

            settingsRow("When a conversation is cleared") {
                Picker("", selection: $settings.claudeCodeSessionEndBehavior) {
                    ForEach(SettingsManager.ClaudeCodeSessionEndBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
    }

    private func refreshPluginState() async {
        pluginState = await pluginDetector.read()
        pluginStateChecked = true
        settings.refreshWakeReachability()
    }

    private func installPlugin(_ plugin: String) {
        guard !installingPlugins.contains(plugin) else { return }
        installingPlugins.insert(plugin)
        pluginErrors[plugin] = nil
        Task { @MainActor in
            switch await PluginInstaller.install(plugin: plugin) {
            case .success:
                break
            case .claudeNotFound:
                pluginErrors[plugin] = "Claude Code CLI not found. Install Claude Code first, or run the commands in a terminal."
            case .failed(let message):
                pluginErrors[plugin] = message
            }
            await refreshPluginState()
            installingPlugins.remove(plugin)
        }
    }

    private func copyCommands(_ commands: String, key: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(commands, forType: .string)
        copiedPluginCommands = key
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedPluginCommands == key { copiedPluginCommands = nil }
        }
    }

    private func harnessIntegrationSection(_ harness: SkillInstaller.Harness) -> some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                harness.rawValue,
                description: harnessDescription(harness)
            )

            harnessToggleRow(for: harness)

            harnessStatusRow(
                label: "Skill",
                state: skillStatus(for: harness)
            )
            harnessStatusRow(
                label: "MCP server",
                state: mcpStatus(for: harness)
            )
        }
    }

    private func harnessDescription(_ harness: SkillInstaller.Harness) -> String {
        switch harness {
        case .claudeCode:
            return "Installs the Remarc skill and registers the shared MCP server with Claude Code."
        case .codex:
            return "Installs the Remarc skill and registers the shared MCP server with Codex."
        case .cursor:
            return "Installs the Remarc skill and registers the shared MCP server with Cursor."
        }
    }

    private func skillStatus(for harness: SkillInstaller.Harness) -> IntegrationRowStatus {
        guard let status = harnessManager.statuses[harness]?.skill else {
            return harnessManager.isWorking ? .pending("Checking") : .pending("Not checked yet")
        }

        switch status {
        case .installed, .updated, .unchanged:
            return .installed("Installed")
        case .notInstalled:
            return .inactive("Off")
        case .skippedHarnessAbsent:
            return .absent("Not detected")
        case .failed(let message):
            return .warning("Could not install: \(message)")
        }
    }

    private func mcpStatus(for harness: SkillInstaller.Harness) -> IntegrationRowStatus {
        if harness == .claudeCode {
            if mcpManager.isEnabled {
                return .installed("Installed")
            }
            if mcpManager.nodeStatus == .unchecked || mcpManager.claudeStatus == .unchecked {
                return harnessManager.isWorking ? .pending("Checking") : .pending("Not checked yet")
            }
            if mcpManager.nodeStatus == .notFound {
                return .warning("Node.js not found")
            }
            if mcpManager.claudeStatus == .notFound {
                return .warning("Claude Code not found")
            }
            if let status = harnessManager.statuses[.claudeCode], status.mcp == .notInstalled {
                return .inactive("Off")
            }
            return .warning("Not registered")
        }

        guard let status = harnessManager.statuses[harness]?.mcp else {
            return harnessManager.isWorking ? .pending("Checking") : .pending("Not checked yet")
        }

        switch status {
        case .installed:
            return .installed("Installed")
        case .notInstalled:
            return .inactive("Off")
        case .skippedHarnessAbsent:
            return .absent("Not detected")
        case .skippedNoNode:
            return .warning("Node.js not found")
        case .failed(let message):
            return .warning(message)
        }
    }

    private func harnessToggleRow(for harness: SkillInstaller.Harness) -> some View {
        let isUpdating = pendingHarnesses.contains(harness)
            || harnessManager.workingHarnesses.contains(harness)
            || harnessManager.isWorking
        let isUnavailable = isHarnessUnavailable(harness)

        return settingsRow("Enable integration") {
            Toggle("Enable \(harness.rawValue) integration", isOn: Binding(
                get: { isHarnessEnabled(harness) },
                set: { enabled in
                    beginSetHarness(harness, enabled: enabled)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(isUnavailable)
            .allowsHitTesting(!isUpdating && !isUnavailable)
            .help("\(isHarnessEnabled(harness) ? "Disable" : "Enable") \(harness.rawValue)")
        }
    }

    private func isHarnessUnavailable(_ harness: SkillInstaller.Harness) -> Bool {
        guard let status = harnessManager.statuses[harness] else { return false }
        return status.skill == .skippedHarnessAbsent
            && status.mcp == .skippedHarnessAbsent
    }

    private func isHarnessEnabled(_ harness: SkillInstaller.Harness) -> Bool {
        guard let status = harnessManager.statuses[harness] else {
            return harness == .claudeCode && mcpManager.isEnabled
        }
        return skillIsInstalled(status.skill)
            || status.mcp.isInstalled
    }

    private func skillIsInstalled(_ result: SkillInstaller.Result) -> Bool {
        switch result {
        case .installed, .updated, .unchanged:
            return true
        case .notInstalled, .skippedHarnessAbsent, .failed:
            return false
        }
    }

    private func beginSetHarness(_ harness: SkillInstaller.Harness, enabled: Bool) {
        guard !pendingHarnesses.contains(harness),
              !harnessManager.workingHarnesses.contains(harness) else {
            return
        }

        pendingHarnesses.insert(harness)
        Task { @MainActor in
            await setHarness(harness, enabled: enabled)
            pendingHarnesses.remove(harness)
        }
    }

    private func setHarness(_ harness: SkillInstaller.Harness, enabled: Bool) async {
        if enabled {
            await harnessManager.enable(harness)
        } else {
            await harnessManager.uninstall(harness)
        }
    }

    private func harnessStatusRow(
        label: String,
        state: IntegrationRowStatus
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
            Spacer(minLength: 8)
            integrationStatusLabel(state)
        }
    }

    private func integrationStatusLabel(_ state: IntegrationRowStatus) -> some View {
        let icon: String
        let tint: Color
        let text: String

        switch state {
        case .installed(let message):
            icon = "checkmark.circle.fill"
            tint = Color.remarcSuccess(for: colorScheme)
            text = message
        case .warning(let message):
            icon = "exclamationmark.triangle.fill"
            tint = Color.remarcWarning(for: colorScheme)
            text = message
        case .absent(let message):
            icon = "slash.circle.fill"
            tint = .secondary
            text = message
        case .inactive(let message):
            icon = "circle"
            tint = .secondary
            text = message
        case .pending(let message):
            icon = "clock.fill"
            tint = Color.remarcInfo(for: colorScheme)
            text = message
        }

        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var claudeDesktopSection: some View {
        let hasNode = mcpManager.resolvedNodePath != nil
        let hasMCPPath = mcpManager.resolvedMCPPath != nil

        return VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                "Claude Desktop",
                description: "You can also use Remarc with the Claude Desktop app. Add this snippet to your config file (Claude > Settings > Developer > Edit Config), then restart Claude Desktop."
            )

            if hasNode && hasMCPPath {
                claudeDesktopSnippet

                CalloutView(.info, "Tip: After connecting, go to Customize > Connectors > Remarc and set permissions to \"Always allow\" to avoid constant approval prompts.")
            } else {
                CalloutView(.warning, "Node.js is required for Claude Desktop integration. Install it from nodejs.org, then relaunch Remarc.")
            }
        }
    }

    private var claudeDesktopSnippet: some View {
        let snippet = CursorMCPInstaller.snippet(
            nodePath: mcpManager.resolvedNodePath,
            mcpPath: mcpManager.resolvedMCPPath
        )

        return manualMCPSnippet(
            label: "Claude Desktop config",
            body: snippet,
            copied: $claudeDesktopCopied
        )
    }

    private var otherMCPClientsSection: some View {
        let jsonSnippet = CursorMCPInstaller.snippet(nodePath: manualNodePath, mcpPath: manualMCPPath)
        let skillContent = SkillInstaller.bundledSkillContent() ?? "Bundled SKILL.md resource not found."

        return VStack(alignment: .leading, spacing: Self.itemSpacing) {
            sectionHeader(
                "Other MCP clients",
                description: "Use these snippets to install Remarc in any other MCP-compatible agent harness, including OpenCode, Continue, Windsurf, or any client that takes JSON config."
            )

            if isResolvingManualPaths || (manualNodePath == nil && !manualNodeResolutionFailed) {
                settingsHint("Resolving Node.js...", tint: Color.remarcInfo(for: colorScheme))
            } else if manualNodeResolutionFailed {
                HStack(spacing: 8) {
                    settingsHint("Node.js not found on PATH. Install Node 18+ from nodejs.org, then click Retry.", icon: "exclamationmark.triangle.fill", tint: Color.remarcWarning(for: colorScheme))
                    Link("Help", destination: URL(string: "https://nodejs.org/")!)
                    Button("Retry") {
                        Task { await resolveManualPaths() }
                    }
                    .font(.system(size: 11))
                }
            } else if manualMCPPathMissing {
                settingsHint("Remarc MCP server bundle not found. Rebuild and relaunch Remarc.", icon: "exclamationmark.triangle.fill", tint: Color.remarcWarning(for: colorScheme))
            }

            Text("For UI-only clients, paste the JSON snippet into your client's MCP server settings.")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            manualMCPSnippet(
                label: "MCP server config (JSON)",
                body: jsonSnippet,
                copied: $manualJSONCopied,
                isCopyDisabled: manualSnippetCopyDisabled
            )

            manualMCPSnippet(
                label: "Skill content (SKILL.md)",
                body: skillContent,
                copied: $manualSkillCopied
            )
        }
    }

    private var manualSnippetCopyDisabled: Bool {
        isResolvingManualPaths || (manualNodePath == nil && !manualNodeResolutionFailed)
    }

    private func resolveManualPaths() async {
        isResolvingManualPaths = true
        defer { isResolvingManualPaths = false }

        let node = await BundledMCP.nodePath()
        let mcpPath = BundledMCP.mcpServerPath

        manualNodePath = node
        manualMCPPath = mcpPath
        manualNodeResolutionFailed = node == nil
        manualMCPPathMissing = mcpPath == nil
    }

    private func manualMCPSnippet(
        label: String,
        body: String,
        copied: Binding<Bool>,
        isCopyDisabled: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.7))
            Text(body)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.7))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    Button {
                        copy(body, copied: copied)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copied.wrappedValue ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(copyButtonTitle(copied: copied.wrappedValue, disabled: isCopyDisabled))
                                .font(.system(size: 11))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied.wrappedValue ? Color.remarcSuccess(for: colorScheme) : .secondary)
                    .disabled(isCopyDisabled)
                    .padding(4)
                }
        }
    }

    private func copyButtonTitle(copied: Bool, disabled: Bool) -> String {
        if copied { return "Copied" }
        return disabled ? "Resolving Node.js..." : "Copy"
    }

    private func copy(_ text: String, copied: Binding<Bool>) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied.wrappedValue = false
        }
    }

    private var excludedAppsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Excluded Apps",
                description: "Remarc won't show the comment tooltip in these apps."
            )

            List(excludedApps, selection: $excludedSelection) { app in
                HStack(spacing: 8) {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                    }
                    Text(app.name)
                        .font(.system(size: 13))
                    Spacer()
                    Text(app.bundleID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.35))
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if excludedApps.isEmpty {
                    VStack(spacing: 4) {
                        Text("No excluded apps")
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.4))
                        Text("Click + to add an application.")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.3))
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: addExcludedApp) {
                    Image(systemName: "plus")
                }
                .help("Add application")

                Button(action: removeSelectedApps) {
                    Image(systemName: "minus")
                }
                .disabled(excludedSelection.isEmpty)
                .help("Remove selected")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 13))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loadExcludedApps() }
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Select applications to exclude"

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let bundle = Bundle(url: url),
                      let bundleID = bundle.bundleIdentifier else { continue }
                if !self.settings.excludedAppBundleIDs.contains(bundleID) {
                    self.settings.excludedAppBundleIDs.append(bundleID)
                }
            }
            self.loadExcludedApps()
        }

        // Present as sheet so it appears above the high-level settings window
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    private func removeSelectedApps() {
        settings.excludedAppBundleIDs.removeAll { excludedSelection.contains($0) }
        excludedSelection.removeAll()
        loadExcludedApps()
    }

    private func loadExcludedApps() {
        excludedApps = settings.excludedAppBundleIDs.map { bundleID in
            let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
            let name = path.map { FileManager.default.displayName(atPath: $0) } ?? bundleID
            let icon = path.map { NSWorkspace.shared.icon(forFile: $0) }
            return ExcludedAppInfo(bundleID: bundleID, name: name, icon: icon)
        }
    }

    private var aboutSection: some View {
        VStack(spacing: 16) {
            Spacer()

            if let appIcon = NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 96, height: 96)
            }

            Text("Remarc")
                .font(.system(size: 24, weight: .semibold))

            Text("Contextual comments on any text selection")
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.6))

            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                Text("v\(version) (\(build))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.35))
            }

            Text("\(PersistenceManager.shared.appState.totalCommentsCreated) remarks created")
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.35))

            Button("Check for Updates\u{2026}") {
                UpdateManager.shared.checkForUpdates()
            }
            .disabled(!updateManager.canCheckForUpdates)

            HStack(spacing: 16) {
                Link("Website", destination: URL(string: "https://remarc.app")!)
                Link("Documentation", destination: URL(string: "https://docs.remarc.app")!)
                Link("GitHub", destination: URL(string: "https://github.com/metedata/Remarc")!)
            }
            .font(.system(size: 12))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    #if DEBUG
    private var experimentalSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(
                        "Vocabulary Hints",
                        description: "Words and phrases that improve speech recognition accuracy. These bias the WhisperKit decoder toward domain-specific terms."
                    )

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(settings.vocabularyHints, id: \.self) { hint in
                            HStack {
                                Text(hint)
                                    .font(.system(size: 13))
                                Spacer()
                                Button {
                                    settings.vocabularyHints.removeAll { $0 == hint }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Add word or phrase", text: $newVocabHint)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .onSubmit { addVocabHint() }

                        Button("Add") { addVocabHint() }
                            .disabled(newVocabHint.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(
                        "HyperFrames Context",
                        leadingIcon: "HyperFramesLogo",
                        description: "Attach HyperFrames composition context (beat, active tweens, source-line ranges) to web-element, region, and quick-note comments captured on HF compositions. Experimental — requires a `window.__remarcHFContext` bridge in the composition."
                    )

                    toggleRow("Capture HyperFrames context", isOn: $settings.webContextHyperframesEnabled)

                    if settings.webContextHyperframesEnabled {
                        Text("When grabbing an element (or region) on a page that exposes `window.__remarcHFContext`, Remarc captures the current paused timeline moment, the active beat, and the top-3 active tweens with their `timeline.js` source-line ranges. Use Alt+Shift+N for a quick note tied only to the timeline moment (no DOM target).")
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: Self.itemSpacing) {
                    sectionHeader(
                        "Reset",
                        description: "Experimental reset actions. These are destructive."
                    )

                    HStack(spacing: 12) {
                        Button("Reset Data") {
                            showResetDataConfirm = true
                        }
                        .foregroundStyle(.red)
                        .alert("Reset Data", isPresented: $showResetDataConfirm) {
                            Button("Cancel", role: .cancel) {}
                            Button("Reset", role: .destructive) {
                                resetDataForTesting()
                            }
                        } message: {
                            Text("This will delete all comments and sessions. Restart the app to complete the reset.")
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func addVocabHint() {
        let trimmed = newVocabHint.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !settings.vocabularyHints.contains(trimmed) else { return }
        settings.vocabularyHints.append(trimmed)
        newVocabHint = ""
    }

    private func resetDataForTesting() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let commentsFile = appSupport.appendingPathComponent("Remarc/comments.json")
        let legacyFile = appSupport.appendingPathComponent("Remarc/data.json")
        try? FileManager.default.removeItem(at: commentsFile)
        try? FileManager.default.removeItem(at: legacyFile)
        debugLog("Data file removed - restart app to reset")
    }
    #endif

}

private struct GetExtensionButton: View {
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 10.5, weight: .medium))

                Text("Get Extension")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.primary.opacity(isHovered ? 0.7 : 0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(isHovered ? 0.1 : 0.06))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.16 : 0.1), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Get Chrome extension")
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

private struct VoiceSettingsGearButton: View {
    var action: () -> Void
    @State private var isHovered = false

    private let collapsedWidth: CGFloat = 15
    private let expandedWidth: CGFloat = 96

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "gearshape")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.primary.opacity(isHovered ? 0.55 : 0.25))

                Text("More settings")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, isHovered ? 6 : 3)
            .padding(.vertical, 2)
            .frame(width: isHovered ? expandedWidth : collapsedWidth, alignment: .leading)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.12 : 0), lineWidth: 0.5)
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open Voice settings")
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                isHovered = hovering
            }
        }
    }
}

/// Shortcut recorder styled to match KeyboardShortcuts.Recorder (NSSearchField-based).
private struct ExtensionShortcutRecorder: View {
    @Binding var shortcut: ExtensionShortcut

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ExtensionShortcutRecorderField(shortcut: $shortcut, conflictWarning: $conflictWarning)
                .frame(width: 130, height: 22)

            if let conflictWarning {
                Text(conflictWarning)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    @State private var conflictWarning: String?
}

/// NSViewRepresentable wrapping an NSSearchField to match the native KeyboardShortcuts.Recorder appearance.
/// Uses local event monitors for both click and key detection since NSSearchField with isEditable=false
/// swallows mouse events and prevents normal target/action interaction.
private struct ExtensionShortcutRecorderField: NSViewRepresentable {
    @Binding var shortcut: ExtensionShortcut
    @Binding var conflictWarning: String?

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.centersPlaceholder = true
        field.alignment = .center
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = "Record Shortcut"
        field.stringValue = shortcut.displayString
        field.isEditable = false
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if context.coordinator.isRecording {
            field.stringValue = ""
        } else {
            field.stringValue = shortcut.displayString
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shortcut: $shortcut, conflictWarning: $conflictWarning)
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding var shortcut: ExtensionShortcut
        @Binding var conflictWarning: String?
        var isRecording = false
        nonisolated(unsafe) var keyMonitor: Any?
        nonisolated(unsafe) var clickMonitor: Any?
        weak var field: NSSearchField?

        init(shortcut: Binding<ExtensionShortcut>, conflictWarning: Binding<String?>) {
            _shortcut = shortcut
            _conflictWarning = conflictWarning
            super.init()
            installClickMonitor()
        }

        deinit {
            let km = keyMonitor
            let cm = clickMonitor
            DispatchQueue.main.async {
                if let km { NSEvent.removeMonitor(km) }
                if let cm { NSEvent.removeMonitor(cm) }
            }
        }

        private func installClickMonitor() {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let field = self.field else { return event }
                guard let fieldWindow = field.window, fieldWindow == event.window else {
                    if self.isRecording { self.stopRecording() }
                    return event
                }
                let point = field.convert(event.locationInWindow, from: nil)
                guard field.bounds.contains(point) else {
                    if self.isRecording { self.stopRecording() }
                    return event
                }
                // Toggle recording
                if self.isRecording {
                    self.stopRecording()
                } else {
                    self.startRecording()
                }
                return nil
            }
        }

        private func startRecording() {
            isRecording = true
            conflictWarning = nil
            field?.stringValue = ""
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 53 { // Escape — cancel
                    self.stopRecording()
                    return nil
                }
                if let newShortcut = ExtensionShortcut.from(event: event), newShortcut.isValid {
                    if newShortcut.modifiers.contains("Meta") {
                        // Chrome intercepts ⌘ shortcuts — reject and keep recording
                        self.conflictWarning = "⌘ shortcuts won't work in Chrome"
                    } else {
                        self.shortcut = newShortcut
                        self.conflictWarning = self.checkConflict(newShortcut)
                        self.stopRecording()
                    }
                }
                return nil
            }
        }

        private func stopRecording() {
            isRecording = false
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            keyMonitor = nil
            field?.stringValue = shortcut.displayString
        }

        private func checkConflict(_ candidate: ExtensionShortcut) -> String? {
            let appShortcuts: [KeyboardShortcuts.Name] = [
                .commentOnSelection, .screenshotComment, .pasteAllComments, .voiceInput, .pasteLastTranscription, .openRemarc, .startCritMode
            ]
            guard let candidateKeyCode = candidate.carbonKeyCode else { return nil }
            for name in appShortcuts {
                guard let existing = KeyboardShortcuts.getShortcut(for: name) else { continue }
                var mods: [String] = []
                if existing.modifiers.contains(.command) { mods.append("Meta") }
                if existing.modifiers.contains(.control) { mods.append("Control") }
                if existing.modifiers.contains(.option)  { mods.append("Alt") }
                if existing.modifiers.contains(.shift)   { mods.append("Shift") }
                if existing.key?.rawValue == candidateKeyCode,
                   Set(mods) == Set(candidate.modifiers) {
                    return "Conflicts with \(name.rawValue)"
                }
            }
            return nil
        }
    }
}

private struct ExcludedAppInfo: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var id: String { bundleID }
}

// MARK: - Text Button with Hover State

private struct TextButton: View {
    let title: String
    let color: Color
    var restOpacity: Double = 0.8
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .opacity(isHovered ? 1.0 : restOpacity)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Badge View (with optional hover tooltip)

private struct BadgeView: View {
    let text: String
    let tooltip: String?
    let colorScheme: ColorScheme

    @State private var showTooltip = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.remarcPrimary(for: colorScheme).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onHover { hovering in
                if tooltip != nil { showTooltip = hovering }
            }
            .popover(isPresented: $showTooltip, arrowEdge: .bottom) {
                if let tooltip {
                    Text(tooltip)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.8))
                        .padding(10)
                        .frame(width: 240)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
    }
}
