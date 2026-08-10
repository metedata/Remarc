import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let commentOnSelection = Self(
        "commentOnSelection",
        initial: .init(.c, modifiers: [.control, .option])
    )
    static let screenshotComment = Self(
        "screenshotComment",
        initial: .init(.s, modifiers: [.control, .option])
    )
    /// Screenshot capture whose save wakes a running session. No default
    /// binding: waking is opt-in, so this stays unassigned until asked for.
    static let screenshotCommentWake = Self("screenshotCommentWake")
    static let pasteAllComments = Self(
        "pasteAllComments",
        initial: .init(.p, modifiers: [.control, .option])
    )
    static let voiceInput = Self(
        "voiceInput",
        initial: .init(.v, modifiers: [.control, .option])
    )
    static let dictation = Self(
        "dictation",
        initial: .init(.d, modifiers: [.control, .option])
    )
    static let dictationHandsFree = Self(
        "dictationHandsFree",
        initial: .init(.h, modifiers: [.control, .option])
    )
    static let pasteLastTranscription = Self(
        "pasteLastTranscription",
        initial: .init(.l, modifiers: [.control, .option])
    )
    static let openRemarc = Self(
        "openRemarc",
        initial: .init(.r, modifiers: [.control, .option])
    )
    static let startCritMode = Self(
        "startCritMode",
        initial: .init(.m, modifiers: [.control, .option])
    )
}

@MainActor
public final class GlobalHotkey {
    public static let shared = GlobalHotkey()

    private init() {}

    private var voiceKeyDownTime: Date?
    private var dictationKeyDownTime: Date?
    private var awaitingSecondTap: Bool = false
    private var secondTapTimer: DispatchWorkItem?
    private var dictationForwardedToVoiceInput = false
    private let holdThreshold: TimeInterval = 0.4

    /// Register the configurable global hotkey for comment-on-selection
    public func register() {
        KeyboardShortcuts.onKeyDown(for: .commentOnSelection) { [weak self] in
            Task { @MainActor in
                self?.handleHotkey()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .screenshotComment) { [weak self] in
            Task { @MainActor in
                self?.handleScreenshotHotkey()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .screenshotCommentWake) { [weak self] in
            Task { @MainActor in
                self?.handleScreenshotHotkey(wakeOnSave: true)
            }
        }
        KeyboardShortcuts.onKeyDown(for: .pasteAllComments) { [weak self] in
            Task { @MainActor in
                self?.handlePasteAllHotkey()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .pasteLastTranscription) { [weak self] in
            Task { @MainActor in
                self?.handlePasteLastTranscription()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .openRemarc) { [weak self] in
            Task { @MainActor in
                self?.handleOpenRemarc()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .startCritMode) { [weak self] in
            Task { @MainActor in
                self?.handleStartCritMode()
            }
        }
        if #available(macOS 26, *) {
            KeyboardShortcuts.onKeyDown(for: .voiceInput) { [weak self] in
                Task { @MainActor in
                    self?.handleVoiceInputKeyDown()
                }
            }
            KeyboardShortcuts.onKeyUp(for: .voiceInput) { [weak self] in
                Task { @MainActor in
                    self?.handleVoiceInputKeyUp()
                }
            }
            KeyboardShortcuts.onKeyDown(for: .dictation) { [weak self] in
                Task { @MainActor in
                    guard SettingsManager.shared.dictationEnabled else { return }
                    guard !SettingsManager.shared.dictationUsesFnKey else { return }
                    self?.handleDictationKeyDown()
                }
            }
            KeyboardShortcuts.onKeyUp(for: .dictation) { [weak self] in
                Task { @MainActor in
                    guard SettingsManager.shared.dictationEnabled else { return }
                    guard !SettingsManager.shared.dictationUsesFnKey else { return }
                    self?.handleDictationKeyUp()
                }
            }
            KeyboardShortcuts.onKeyDown(for: .dictationHandsFree) { [weak self] in
                Task { @MainActor in
                    guard SettingsManager.shared.dictationEnabled else { return }
                    guard !SettingsManager.shared.dictationHandsFreeUsesFnKey else { return }
                    self?.handleDictationHandsFree()
                }
            }

            // Fn key monitor — installed once, checks settings in callback
            FnKeyMonitor.shared.install()
            FnKeyMonitor.shared.onFnKeyDown = { [weak self] in
                if #available(macOS 26, *) {
                    Task { @MainActor in
                        guard let self else { return }
                        guard SettingsManager.shared.dictationEnabled else { return }
                        if SettingsManager.shared.dictationUsesFnKey {
                            self.handleDictationKeyDown()
                        } else if SettingsManager.shared.dictationHandsFreeUsesFnKey {
                            self.handleDictationHandsFree()
                        }
                    }
                }
            }
            FnKeyMonitor.shared.onFnKeyUp = { [weak self] in
                if #available(macOS 26, *) {
                    Task { @MainActor in
                        guard let self else { return }
                        guard SettingsManager.shared.dictationEnabled else { return }
                        if SettingsManager.shared.dictationUsesFnKey {
                            self.handleDictationKeyUp()
                        }
                        // No keyUp handler needed for hands-free (it's a toggle)
                    }
                }
            }
        }
        debugLog("GlobalHotkey: Registered (KeyboardShortcuts)")
    }

    public func unregister() {
        KeyboardShortcuts.disable(.commentOnSelection)
        KeyboardShortcuts.disable(.screenshotComment)
        KeyboardShortcuts.disable(.screenshotCommentWake)
        KeyboardShortcuts.disable(.pasteAllComments)
        KeyboardShortcuts.disable(.voiceInput)
        KeyboardShortcuts.disable(.dictation)
        KeyboardShortcuts.disable(.dictationHandsFree)
        KeyboardShortcuts.disable(.pasteLastTranscription)
        KeyboardShortcuts.disable(.openRemarc)
        KeyboardShortcuts.disable(.startCritMode)
        FnKeyMonitor.shared.onFnKeyDown = nil
        FnKeyMonitor.shared.onFnKeyUp = nil
        debugLog("GlobalHotkey: Unregistered")
    }

    private func handleOpenRemarc() {
        debugLog("GlobalHotkey: handleOpenRemarc fired")
        let popover = MenuBarPopoverController.shared
        if popover.isDetached {
            DetachedWindowController.shared.bringToFront()
        } else if !popover.isVisible {
            popover.show()
        }
    }

    private func handleStartCritMode() {
        debugLog("GlobalHotkey: handleStartCritMode fired")
        guard !SettingsManager.shared.isPaused else {
            debugLog("GlobalHotkey: paused, ignoring start-crit-mode")
            return
        }

        let popover = MenuBarPopoverController.shared
        if popover.isDetached {
            DetachedWindowController.shared.bringToFront()
        } else if !popover.isVisible {
            popover.show()
        }
        // Defer signal so the SwiftUI onChange observer is installed after show()
        DispatchQueue.main.async {
            popover.requestCritMode = true
        }
    }

    private func handleHotkey() {
        debugLog("GlobalHotkey: handleHotkey fired")
        guard !SettingsManager.shared.isPaused else {
            debugLog("GlobalHotkey: paused, ignoring")
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        debugLog("GlobalHotkey: frontmost app = \(frontApp?.bundleIdentifier ?? "nil") (pid \(frontApp?.processIdentifier ?? -1))")

        if let selection = SelectionMonitor.shared.readCurrentSelection() {
            debugLog("GlobalHotkey: got selection: \"\(selection.text.prefix(40))\"")
            CommentInputController.shared.showForSelection(selection)
        } else {
            debugLog("GlobalHotkey: readCurrentSelection returned nil — opening quick note")
            CommentInputController.shared.showStandaloneNote()
        }
    }

    private func handleScreenshotHotkey(wakeOnSave: Bool = false) {
        debugLog("GlobalHotkey: handleScreenshotHotkey fired (wakeOnSave=\(wakeOnSave))")
        guard !SettingsManager.shared.isPaused else {
            debugLog("GlobalHotkey: paused, ignoring screenshot hotkey")
            return
        }
        // Only pre-arm when a wake could actually be honoured; otherwise this
        // behaves as an ordinary screenshot comment. The shortcut files to the
        // active session, so that is the pairing that has to be live - the
        // composer opens on the same session and its button agrees.
        let armWake = wakeOnSave
            && SettingsManager.shared.wakeAvailable(
                for: PersistenceManager.shared.appState.activeSessionID
            )

        ScreenCaptureService.shared.startCapture(
            onRegionSelected: { captureRect, sourceBundleID in
                Task { @MainActor in
                    CommentInputController.shared.wakeOnSave = armWake
                    CommentInputController.shared.showForScreenshot(captureRect: captureRect, sourceBundleID: sourceBundleID)
                }
            },
            onCancel: {
                Task { @MainActor in
                    debugLog("GlobalHotkey: screenshot capture cancelled")
                }
            }
        )
    }

    private func handlePasteAllHotkey() {
        debugLog("GlobalHotkey: handlePasteAllHotkey fired")
        guard !SettingsManager.shared.isPaused else {
            debugLog("GlobalHotkey: paused, ignoring paste-all hotkey")
            return
        }

        guard let session = PersistenceManager.shared.activeSession else {
            debugLog("GlobalHotkey: no active session, ignoring paste-all")
            return
        }

        let comments = PersistenceManager.shared.activeComments
        guard !comments.isEmpty else {
            debugLog("GlobalHotkey: no comments to paste")
            return
        }

        let format = SettingsManager.shared.outputFormat
        ExportManager.shared.copySessionToClipboard(session, comments: comments, format: format)
        debugLog("GlobalHotkey: copied \(comments.count) comments, simulating Cmd+V")

        // Brief delay for clipboard to settle, then simulate Cmd+V
        simulatePaste()

        ToastManager.shared.show("Pasted \(comments.count) comment\(comments.count == 1 ? "" : "s")")

        if SettingsManager.shared.clearAfterExportBehavior == .delete {
            // Use a delay to allow the paste to complete before clearing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let sessionID = PersistenceManager.shared.appState.activeSessionID {
                    PersistenceManager.shared.clearAllComments(in: sessionID)
                    debugLog("GlobalHotkey: auto-cleared comments after paste-all")
                }
            }
        }
    }

    @available(macOS 26, *)
    private func handleVoiceInputKeyDown() {
        debugLog("GlobalHotkey: voiceInput keyDown")
        guard !SettingsManager.shared.isPaused else {
            debugLog("GlobalHotkey: paused, ignoring voice input")
            return
        }

        // Cancel any active auto-save countdown (new recording supersedes)
        CommentInputController.shared.cancelAutoSaveCountdown()
        FloatingEditorController.shared.cancelAutoSaveCountdown()

        let voiceService = VoiceInputService.shared
        if voiceService.state == .recording {
            // Already recording — stop (double-press or toggle)
            Task { @MainActor in
                let text = try? await voiceService.stopRecording()
                if let text, !text.isEmpty {
                    self.appendVoiceTextToActiveEditor(text)
                }
            }
            return
        }

        voiceKeyDownTime = Date()

        // Open comment panel if not already visible
        if activeRemarcEditorVoiceTarget() == nil {
            if let selection = SelectionMonitor.shared.readCurrentSelection() {
                CommentInputController.shared.showForSelection(selection)
            } else {
                CommentInputController.shared.showStandaloneNote()
            }
        }
        switch activeRemarcEditorVoiceTarget() {
        case .floatingEditor:
            FloatingEditorController.shared.markVoiceInvoked()
        case .commentInput:
            CommentInputController.shared.isVoiceInvoked = true
        case nil:
            break
        }

        // Start recording
        Task {
            do {
                try await voiceService.startRecording()
            } catch {
                debugLog("GlobalHotkey: voice recording failed: \(error)")
                ToastManager.shared.show("Microphone access required")
            }
        }
    }

    @available(macOS 26, *)
    private func handleVoiceInputKeyUp() {
        debugLog("GlobalHotkey: voiceInput keyUp")
        guard let keyDownTime = voiceKeyDownTime else { return }
        voiceKeyDownTime = nil

        let holdDuration = Date().timeIntervalSince(keyDownTime)
        let voiceService = VoiceInputService.shared

        if voiceService.state == .recording && holdDuration > holdThreshold {
            // Was a hold — stop recording on release
            Task { @MainActor in
                let text = try? await voiceService.stopRecording()
                if let text, !text.isEmpty {
                    self.appendVoiceTextToActiveEditor(text)
                }
            }
        }
        // If holdDuration <= threshold, it was a tap — recording continues
        // until next keyDown (handled in handleVoiceInputKeyDown)
    }

    // MARK: - Dictation Mode
    //
    // Push-to-talk shortcut: hold to record, release to stop & paste.
    // Hands-free: configurable via setting — single tap / double tap / custom shortcut.

    private func activeRemarcEditorVoiceTarget() -> RemarcEditorVoiceTarget? {
        RemarcEditorVoiceRouter.activeTarget(
            commentInputVisible: CommentInputController.shared.isVisible,
            floatingEditorVisible: FloatingEditorController.shared.isVisible
        )
    }

    private func appendVoiceTextToActiveEditor(_ text: String) {
        switch activeRemarcEditorVoiceTarget() {
        case .floatingEditor:
            FloatingEditorController.shared.appendVoiceText(text)
        case .commentInput:
            CommentInputController.shared.appendVoiceText(text)
        case nil:
            CommentInputController.shared.appendVoiceText(text)
        }
    }

    @available(macOS 26, *)
    private func handleDictationKeyDown() {
        debugLog("GlobalHotkey: dictation keyDown")
        let dictationService = DictationService.shared
        let handsFreeMode = SettingsManager.shared.dictationHandsFreeMode

        // If already recording in persistent mode, toggle stop (allow even when paused)
        if dictationService.state == .recording && dictationService.persistentMode {
            Task { await stopDictationAndPaste() }
            return
        }

        guard !SettingsManager.shared.isPaused else {
            debugLog("GlobalHotkey: paused, ignoring dictation")
            return
        }

        // Double-tap detection (only in doubleTap mode)
        if awaitingSecondTap && handsFreeMode == .doubleTap {
            debugLog("GlobalHotkey: dictation double-tap → hands-free")
            secondTapTimer?.cancel()
            secondTapTimer = nil
            awaitingSecondTap = false
            dictationService.persistentMode = true
            if dictationService.state == .idle {
                startDictationRecording()
            }
            return
        }

        // Remarc editor focus passthrough
        if activeRemarcEditorVoiceTarget() != nil {
            dictationForwardedToVoiceInput = true
            handleVoiceInputKeyDown()
            return
        }

        dictationKeyDownTime = Date()

        DictationPillController.shared.show()
        startDictationRecording()
    }

    @available(macOS 26, *)
    private func handleDictationKeyUp() {
        debugLog("GlobalHotkey: dictation keyUp")

        // If keyDown was forwarded to voice input (Remarc editor visible),
        // forward keyUp there too so push-to-talk stop works.
        if dictationForwardedToVoiceInput {
            dictationForwardedToVoiceInput = false
            handleVoiceInputKeyUp()
            return
        }

        guard let keyDownTime = dictationKeyDownTime else { return }
        dictationKeyDownTime = nil

        let holdDuration = Date().timeIntervalSince(keyDownTime)

        if holdDuration >= holdThreshold {
            // Hold: stop immediately on release
            Task { await stopDictationAndPaste() }
        } else {
            switch SettingsManager.shared.dictationHandsFreeMode {
            case .singleTap:
                DictationService.shared.persistentMode = true
            case .doubleTap:
                awaitingSecondTap = true
                let timer = DispatchWorkItem { [weak self] in
                    Task { @MainActor in
                        guard let self, self.awaitingSecondTap else { return }
                        self.awaitingSecondTap = false
                        let ds = DictationService.shared
                        if ds.state == .recording || ds.state == .warmingUp {
                            await self.stopDictationAndPaste()
                        }
                    }
                }
                secondTapTimer = timer
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: timer)
            case .customShortcut:
                // In custom shortcut mode, tap of push-to-talk just does brief record
                Task { await stopDictationAndPaste() }
            }
        }
    }

    /// Dedicated hands-free shortcut handler — directly enters persistent mode.
    @available(macOS 26, *)
    private func handleDictationHandsFree() {
        debugLog("GlobalHotkey: dictation hands-free shortcut")
        let dictationService = DictationService.shared

        // Toggle: if already recording persistently, stop
        if dictationService.state == .recording && dictationService.persistentMode {
            Task { await stopDictationAndPaste() }
            return
        }

        guard !SettingsManager.shared.isPaused else { return }
        if activeRemarcEditorVoiceTarget() != nil {
            handleVoiceInputKeyDown()
            return
        }

        dictationService.persistentMode = true
        DictationPillController.shared.show()
        startDictationRecording()
    }

    @available(macOS 26, *)
    private func startDictationRecording() {
        Task {
            do {
                try await DictationService.shared.startRecording()
            } catch {
                debugLog("GlobalHotkey: dictation recording failed: \(error)")
                DictationPillController.shared.dismiss()
                ToastManager.shared.show("Microphone access required")
            }
        }
    }

    // MARK: - Dictation Paste Flow

    @available(macOS 26, *)
    func stopDictationAndPaste() async {
        let dictationService = DictationService.shared

        // If still warming up (model loading), switch to persistent mode so the user
        // can record once warmup finishes, instead of stopping immediately with 0 buffers.
        if dictationService.state == .warmingUp {
            debugLog("GlobalHotkey: still warming up, switching to persistent mode")
            dictationService.persistentMode = true
            DictationPillController.shared.updateSize()
            return
        }

        // If we never reached recording (e.g. cancelled), bail
        guard dictationService.state == .recording else {
            debugLog("GlobalHotkey: dictation not in recording state, dismissing")
            dictationService.cancelRecording()
            DictationPillController.shared.dismiss()
            return
        }

        // Deep-copy clipboard before overwriting
        let pasteboard = NSPasteboard.general
        let savedItems = deepCopyPasteboard(pasteboard)

        let text: String
        do {
            text = try await dictationService.stopRecording()
        } catch {
            debugLog("GlobalHotkey: dictation transcription failed: \(error)")
            DictationPillController.shared.showError("Transcription failed")
            return
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            debugLog("GlobalHotkey: dictation produced empty text")
            DictationPillController.shared.dismiss()
            return
        }

        DictationPillController.shared.dismiss()

        // Save to transcription history
        let frontApp = NSWorkspace.shared.frontmostApplication
        let appBundleID = frontApp?.bundleIdentifier
        let appName: String? = if let url = frontApp?.bundleURL {
            FileManager.default.displayName(atPath: url.path)
        } else {
            nil
        }
        PersistenceManager.shared.addTranscription(text: text, appBundleID: appBundleID, appName: appName)

        // Write text to pasteboard and simulate Cmd+V
        pasteboard.clearContents()
        pasteboard.setString(text + " ", forType: .string)

        DictationSounds.playStop()

        simulatePaste()

        // Restore original clipboard after paste settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [savedItems] in
            pasteboard.clearContents()
            for item in savedItems {
                pasteboard.writeObjects([item])
            }
            debugLog("GlobalHotkey: clipboard restored")
        }
    }

    // MARK: - Paste Last Transcription

    private func handlePasteLastTranscription() {
        debugLog("GlobalHotkey: pasteLastTranscription fired")
        guard !SettingsManager.shared.isPaused else {
            debugLog("GlobalHotkey: paused, ignoring paste-last-transcription")
            return
        }

        guard let transcription = PersistenceManager.shared.transcriptions.first else {
            debugLog("GlobalHotkey: no transcriptions to paste")
            ToastManager.shared.show("No transcriptions yet")
            return
        }

        let pasteboard = NSPasteboard.general
        let savedItems = deepCopyPasteboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(transcription.text + " ", forType: .string)

        simulatePaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [savedItems] in
            pasteboard.clearContents()
            for item in savedItems {
                pasteboard.writeObjects([item])
            }
            debugLog("GlobalHotkey: clipboard restored after paste-last-transcription")
        }
    }

    /// Simulate Cmd+V keystroke after a brief delay for the clipboard to settle.
    private func simulatePaste() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            debugLog("GlobalHotkey: Cmd+V simulated")
        }
    }

    /// Deep-copies all pasteboard items so we can restore after paste.
    private func deepCopyPasteboard(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        var copies: [NSPasteboardItem] = []
        for item in items {
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            copies.append(copy)
        }
        return copies
    }
}
