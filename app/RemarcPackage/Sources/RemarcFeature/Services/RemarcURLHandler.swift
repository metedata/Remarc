import AppKit

/// Handles incoming `remarc://` URLs.
///
/// Registered as a `kAEGetURL` Apple Event handler rather than through
/// `application(_:open:)`: this app's only SwiftUI scene is `Settings`, and the
/// delegate method is unreliable under the SwiftUI lifecycle for scene shapes
/// other than `WindowGroup`.
@MainActor
public final class RemarcURLHandler: NSObject {
    public static let shared = RemarcURLHandler()

    private var queue = PendingURLQueue()

    private override init() {
        super.init()
    }

    /// Call from `applicationWillFinishLaunching`, before any URL can arrive.
    public func register() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        debugLog("RemarcURLHandler: registered for kAEGetURL")
    }

    /// Call once app setup is complete, to release anything queued during launch.
    ///
    /// A URL that arrives while onboarding is still in progress stays queued
    /// and is replayed here whenever the user completes onboarding, no matter
    /// how much later that is - there is no timeout on the wait, only on the
    /// queue's capacity.
    ///
    /// If the user never finishes onboarding, `completeSetup` never runs and this
    /// is never called, so URLs stay queued until the queue's cap and are then
    /// dropped. That is the correct outcome: there is no session to file a
    /// comment into before setup completes.
    public func markReady() {
        let released = queue.markReady()
        debugLog("RemarcURLHandler: ready, releasing \(released.count) queued URL(s)")
        for url in released {
            handle(url)
        }
    }

    /// Call when this process is terminating as a duplicate copy, so a URL that
    /// arrived here is not acted on by a process that is about to exit.
    public func discardQueued() {
        queue.discardAll()
    }

    @objc private nonisolated func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent: NSAppleEventDescriptor
    ) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else {
            debugLog("RemarcURLHandler: event carried no usable URL")
            return
        }
        // Task rather than MainActor.assumeIsolated: Apple Events are believed to
        // arrive on the main thread, but assumeIsolated traps if that is ever
        // untrue, and trapping on input from another process is a bad trade for
        // saving one run-loop turn.
        Task { @MainActor in
            RemarcURLHandler.shared.receive(url)
        }
    }

    private func receive(_ url: URL) {
        // Which bundle received this matters: several Remarc copies can be
        // installed (worktree Debug builds, an AppMover source copy), and
        // LaunchServices picks one. Log it so a misroute is visible.
        debugLog("RemarcURLHandler: received \(url.absoluteString) in \(Bundle.main.bundleURL.path)")

        guard queue.isReady else {
            debugLog("RemarcURLHandler: not ready, queueing")
            queue.enqueue(url)
            return
        }
        handle(url)
    }

    private func handle(_ url: URL) {
        guard let request = RemarcURLRequest.parse(url) else {
            debugLog("RemarcURLHandler: ignoring unrecognised URL")
            return
        }
        guard !SettingsManager.shared.isPaused else {
            debugLog("RemarcURLHandler: paused, dropping URL")
            return
        }
        guard let selection = SelectionMonitor.shared.readRecentSelection() else {
            // No feedback surface exists outside the popover, so this is silent
            // to the user. Tracked in the design spec as a known gap.
            debugLog("RemarcURLHandler: no selection could be resolved, dropping URL")
            return
        }

        debugLog("RemarcURLHandler: opening composer for \"\(selection.text.prefix(40))\"")
        CommentInputController.shared.showForSelection(selection)

        // Set pendingExternalPageContext only AFTER showForSelection, not before.
        // showForSelection starts a new draft via beginDraft, which unconditionally
        // resets pendingExternalPageContext to nil on every call
        // (CommentInputWindowController.swift:167), specifically so a stale value
        // from a previous draft can never leak into a new one. Setting it first
        // would have that reset wipe what we just set, one call later, every time.
        // Do not "tidy" this back above the showForSelection call.
        //
        // PopClip's page metadata is only a fallback for browsers without the
        // Chrome extension - saveComment prefers live Chrome context and Chrome
        // element context over this field, via WebContextAttachmentPolicy.resolve
        // (CommentInputWindowController.swift:630-635). This field is
        // deliberately separate from WebSocketService.shared.pendingWebContext:
        // that field is written asynchronously by the extension's WebSocket
        // listener at any time, independent of which draft is open, so it
        // cannot safely double as "context adopted for this draft".
        if let pageUrl = request.pageUrl {
            CommentInputController.shared.pendingExternalPageContext = WebContext(pageUrl: pageUrl)
        }
    }
}
