import AppKit
import Combine
import Foundation
import Network

/// Lightweight WebSocket server on localhost for receiving web context from the Chrome extension.
@MainActor
public final class WebSocketService: ObservableObject {
    public static let shared = WebSocketService()

    public enum RegionContextPurpose: String {
        case screenshot
        case textSelection
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var isClientConnected = false
    @Published public private(set) var serverError: String?
    @Published public private(set) var boundPort: UInt16?

    /// Most recent web context received from the extension (consumed on next comment creation).
    @Published public var pendingWebContext: WebContext?
    /// All region elements from the most recent region query (multiple elements for region-based captures).
    @Published public var pendingRegionElements: [WebContext]?
    private var pendingWebContextReceivedAt: Date?
    private var pendingRegionElementsReceivedAt: Date?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Connection that most recently sent a message. Region queries try this
    /// connection first so the active tab can answer before a fallback broadcast.
    private var lastInteractedConnection: NWConnection?
    private var retryCount = 0
    private static let maxRetries = 5
    private var shortcutCancellables = Set<AnyCancellable>()
    /// Timer to open the comment panel if elementGrab doesn't arrive after regionRect.
    private var regionRectFallbackTask: DispatchWorkItem?
    private var activeRegionQueryID: String?
    private var activeRegionQueryPurpose: RegionContextPurpose?
    private var activeRegionQueryResolved = false
    private var activeRegionQueryFallbackTask: DispatchWorkItem?

    private init() {}

    // MARK: - Lifecycle

    /// Start the server if not already running. Called lazily when the user opens the Extension tab.
    public func ensureStarted() {
        if listener == nil && serverError == nil {
            start()
        }
    }

    /// Reset retry state and restart the server. Used by the manual "Retry" button.
    public func retryServer() {
        retryCount = 0
        serverError = nil
        listener?.cancel()
        listener = nil
        start()
    }

    public func start(port: UInt16 = AppConstants.webSocketPort) {
        guard listener == nil else { return }

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        // Bind to loopback only. The extension always dials 127.0.0.1, and the
        // protocol has no auth handshake, so the port must not be reachable
        // from the local network.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )

        do {
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.handleListenerState(state)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleNewConnection(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            debugLog("WebSocketService: Starting on port \(port)")
        } catch {
            debugLog("WebSocketService: Failed to start - \(error)")
        }
        observeShortcutSettings()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        lastInteractedConnection = nil
        regionRectFallbackTask?.cancel()
        regionRectFallbackTask = nil
        activeRegionQueryFallbackTask?.cancel()
        activeRegionQueryFallbackTask = nil
        activeRegionQueryID = nil
        activeRegionQueryPurpose = nil
        activeRegionQueryResolved = false
        isRunning = false
        isClientConnected = false
        boundPort = nil
        debugLog("WebSocketService: Stopped")
    }

    // MARK: - Pending Context

    /// Consume and return the pending web context (filtered by user prefs), clearing it.
    public func consumePendingWebContext(maxAge: TimeInterval? = nil) -> WebContext? {
        if let maxAge, isPendingWebContextOlderThan(maxAge) {
            clearPendingContext()
            return nil
        }
        let context = pendingWebContext?.filtered()
        pendingWebContext = nil
        pendingWebContextReceivedAt = nil
        return context
    }

    /// Consume and return the pending region elements (filtered by user prefs), clearing them.
    public func consumePendingRegionElements(maxAge: TimeInterval? = nil) -> [WebContext]? {
        if let maxAge, isPendingRegionElementsOlderThan(maxAge) {
            pendingRegionElements = nil
            pendingRegionElementsReceivedAt = nil
            return nil
        }
        let elements = pendingRegionElements?.compactMap { $0.filtered() }
        pendingRegionElements = nil
        pendingRegionElementsReceivedAt = nil
        return elements?.isEmpty == true ? nil : elements
    }

    public func clearPendingContext() {
        pendingWebContext = nil
        pendingRegionElements = nil
        pendingWebContextReceivedAt = nil
        pendingRegionElementsReceivedAt = nil
    }

    public func clearPendingRegionElements() {
        pendingRegionElements = nil
        pendingRegionElementsReceivedAt = nil
    }

    public func clearPendingContextIfStale(olderThan maxAge: TimeInterval) {
        if isPendingWebContextOlderThan(maxAge) {
            pendingWebContext = nil
            pendingWebContextReceivedAt = nil
        }
        if isPendingRegionElementsOlderThan(maxAge) {
            pendingRegionElements = nil
            pendingRegionElementsReceivedAt = nil
        }
    }

    private func isPendingWebContextOlderThan(_ maxAge: TimeInterval) -> Bool {
        guard pendingWebContext != nil, let pendingWebContextReceivedAt else { return false }
        return Date().timeIntervalSince(pendingWebContextReceivedAt) > maxAge
    }

    private func isPendingRegionElementsOlderThan(_ maxAge: TimeInterval) -> Bool {
        guard pendingRegionElements != nil, let pendingRegionElementsReceivedAt else { return false }
        return Date().timeIntervalSince(pendingRegionElementsReceivedAt) > maxAge
    }

    // MARK: - Connection Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            retryCount = 0
            serverError = nil
            boundPort = listener?.port?.rawValue
            debugLog("WebSocketService: Listening on port \(boundPort ?? 0)")
        case .failed(let error):
            isRunning = false
            debugLog("WebSocketService: Listener failed — \(error)")
            listener = nil
            retryCount += 1
            if retryCount <= Self.maxRetries {
                let delay = min(30.0, pow(2.0, Double(retryCount - 1)))
                debugLog("WebSocketService: Retry \(retryCount)/\(Self.maxRetries) in \(delay)s")
                Task {
                    try? await Task.sleep(for: .seconds(delay))
                    start()
                }
            } else {
                serverError = "Port \(AppConstants.webSocketPort) unavailable"
                debugLog("WebSocketService: Max retries reached - \(serverError!)")
            }
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection else { return }
                let id = ObjectIdentifier(connection)
                switch state {
                case .ready:
                    self.isClientConnected = self.connections.values.contains { $0.state == .ready }
                    SettingsManager.shared.hasExtensionEverConnected = true
                    let readyCount = self.connections.values.filter { $0.state == .ready }.count
                    debugLog("WebSocketService: Client connected (\(readyCount) ready, \(self.connections.count) tracked)")
                    self.sendShortcutConfig(to: connection)
                case .failed(let error):
                    self.removeConnection(id: id, connection: connection)
                    debugLog("WebSocketService: Connection failed - \(error)")
                case .cancelled:
                    self.removeConnection(id: id, connection: connection)
                    debugLog("WebSocketService: Client disconnected (\(self.connections.count) total)")
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
        receiveMessage(on: connection)
    }

    private func removeConnection(id: ObjectIdentifier, connection: NWConnection) {
        connections.removeValue(forKey: id)
        if lastInteractedConnection === connection {
            lastInteractedConnection = nil
        }
        isClientConnected = connections.values.contains { $0.state == .ready }
    }

    // MARK: - Message Handling

    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            Task { @MainActor in
                guard let self, let connection else { return }
                if let error {
                    debugLog("WebSocketService: Receive error - \(error)")
                    let id = ObjectIdentifier(connection)
                    self.removeConnection(id: id, connection: connection)
                    connection.cancel()
                    return
                }
                if let data = content {
                    self.lastInteractedConnection = connection
                    self.processMessage(data)
                }
                if connection.state == .ready {
                    self.receiveMessage(on: connection)
                }
            }
        }
    }

    /// Typed message wrappers — decode the `data` field directly without AnyCodable round-trip.
    private struct TypeHeader: Decodable {
        let type: String
    }

    private struct ContextMessage: Decodable {
        let type: String
        let data: WebContext
    }

    private struct RegionMessage: Decodable {
        let type: String
        let data: RegionPayload
    }

    private struct RegionPayload: Decodable {
        let queryId: String?
        let purpose: String?
        let elements: [WebContext]
    }

    private struct RegionRectMessage: Decodable {
        let type: String
        let data: RegionRectData
    }

    private struct RegionRectData: Decodable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    /// Sent by the extension on Alt+Shift+N when a HyperFrames bridge is present
    /// on the active tab. Carries only the HF context string — no DOM target.
    private struct HFQuickNoteMessage: Decodable {
        let type: String
        let data: HFQuickNoteData
    }

    private struct HFQuickNoteData: Decodable {
        /// Composition context string produced by the page's `window.__remarcHFContext`.
        let hyperframesContext: String
        /// Optional page URL for context (which composition).
        let pageUrl: String?
    }

    private func processMessage(_ data: Data) {
        let decoder = JSONDecoder()

        guard let header = try? decoder.decode(TypeHeader.self, from: data) else {
            debugLog("WebSocketService: Invalid message")
            return
        }

        switch header.type {
        case "selectionContext", "elementGrab":
            guard let msg = try? decoder.decode(ContextMessage.self, from: data) else {
                debugLog("WebSocketService: Failed to decode WebContext from \(header.type)")
                return
            }
            pendingWebContext = msg.data
            pendingRegionElements = nil
            pendingWebContextReceivedAt = Date()
            pendingRegionElementsReceivedAt = nil
            debugLog("WebSocketService: Received \(header.type) — \(msg.data.displaySummary ?? "no summary")")

            if header.type == "elementGrab" {
                regionRectFallbackTask?.cancel()
                regionRectFallbackTask = nil
                CommentInputController.shared.showForWebElement(msg.data)
            }

        case "regionContext":
            guard let msg = try? decoder.decode(RegionMessage.self, from: data) else {
                debugLog("WebSocketService: Failed to decode regionContext")
                return
            }
            let purpose = msg.data.purpose.flatMap(RegionContextPurpose.init(rawValue:))
            if let queryID = msg.data.queryId {
                guard queryID == activeRegionQueryID else {
                    debugLog("WebSocketService: Ignored stale regionContext query=\(queryID)")
                    return
                }
                guard !activeRegionQueryResolved else {
                    debugLog("WebSocketService: Ignored duplicate regionContext query=\(queryID)")
                    return
                }
                activeRegionQueryResolved = true
                activeRegionQueryFallbackTask?.cancel()
                activeRegionQueryFallbackTask = nil
                applyRegionContext(
                    msg.data.elements,
                    purpose: activeRegionQueryPurpose ?? purpose ?? .screenshot,
                    queryID: queryID
                )
                activeRegionQueryID = nil
                activeRegionQueryPurpose = nil
            } else {
                applyRegionContext(msg.data.elements, purpose: purpose ?? .screenshot, queryID: nil)
            }

        case "regionRect":
            guard let msg = try? decoder.decode(RegionRectMessage.self, from: data) else {
                debugLog("WebSocketService: Failed to decode regionRect")
                return
            }
            // Extension sends global Quartz coordinates (origin at top-left of
            // primary screen, Y down). Convert to AppKit (bottom-left origin, Y up)
            // using the primary screen height.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let appKitY = primaryHeight - msg.data.y - msg.data.height
            CommentInputController.shared.pendingRegionScreenRect = CGRect(
                x: msg.data.x, y: appKitY,
                width: msg.data.width, height: msg.data.height
            )
            debugLog("WebSocketService: Received regionRect quartz=(\(msg.data.x), \(msg.data.y), \(msg.data.width)x\(msg.data.height)) -> appKit=(\(msg.data.x), \(appKitY))")

            // If elementGrab doesn't arrive within 0.8s, open the panel
            // with just the page URL. This handles empty regions and
            // tabs where the content script hasn't been re-injected.
            regionRectFallbackTask?.cancel()
            let fallback = DispatchWorkItem {
                guard !CommentInputController.shared.isVisible else { return }
                CommentInputController.shared.showForWebElement(WebContext(pageUrl: nil))
                debugLog("WebSocketService: regionRect fallback - opened panel without elementGrab")
            }
            regionRectFallbackTask = fallback
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: fallback)

        case "regionHighlightDismissed":
            debugLog("WebSocketService: Region highlight dismissed by user in Chrome")
            if CommentInputController.shared.isVisible,
               CommentInputController.shared.pendingElementWebContext != nil {
                CommentInputController.shared.dismiss()
            }

        case "openExtensionSettings":
            debugLog("WebSocketService: Opening Extension preferences")
            Task { @MainActor in
                PreferencesWindowController.shared.show(tab: "Chrome Extension")
            }

        case "tabActivity":
            break

        case "hfQuickNote":
            // Debug-only / experimental — gate by the same toggle as persistence.
            // In release builds this flag defaults false and is not user-toggleable,
            // so this branch becomes a silent no-op for end users.
            guard SettingsManager.shared.webContextHyperframesEnabled else {
                debugLog("WebSocketService: hfQuickNote ignored — webContextHyperframesEnabled=false")
                return
            }
            guard let msg = try? decoder.decode(HFQuickNoteMessage.self, from: data) else {
                debugLog("WebSocketService: Failed to decode hfQuickNote")
                return
            }
            let trimmed = msg.data.hyperframesContext.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                debugLog("WebSocketService: hfQuickNote with empty hyperframesContext — ignoring")
                return
            }
            let webContext = WebContext(
                pageUrl: msg.data.pageUrl,
                hyperframesContext: trimmed
            )
            pendingWebContext = webContext
            pendingRegionElements = nil
            pendingWebContextReceivedAt = Date()
            pendingRegionElementsReceivedAt = nil
            regionRectFallbackTask?.cancel()
            regionRectFallbackTask = nil
            CommentInputController.shared.showForWebElement(webContext)
            debugLog("WebSocketService: Received hfQuickNote (\(trimmed.count) chars HF context)")

        default:
            debugLog("WebSocketService: Unknown message type '\(header.type)'")
        }
    }

    private func applyRegionContext(_ elements: [WebContext], purpose: RegionContextPurpose, queryID: String?) {
        let uniqueElements = deduplicatedWebContexts(elements)
        guard let first = uniqueElements.first else { return }
        if purpose == .textSelection,
           pendingWebContext?.hasSelectedText == true,
           !first.hasSelectedText {
            pendingRegionElements = nil
            pendingRegionElementsReceivedAt = nil
            let querySuffix = queryID.map { " query=\($0)" } ?? ""
            debugLog("WebSocketService: Kept precise selectionContext over regionContext\(querySuffix)")
            return
        }
        pendingWebContext = first
        let now = Date()
        pendingWebContextReceivedAt = now

        switch purpose {
        case .textSelection:
            pendingRegionElements = nil
            pendingRegionElementsReceivedAt = nil
        case .screenshot:
            pendingRegionElements = uniqueElements
            pendingRegionElementsReceivedAt = now
        }

        let querySuffix = queryID.map { " query=\($0)" } ?? ""
        debugLog("WebSocketService: Received regionContext\(querySuffix) purpose=\(purpose.rawValue) with \(uniqueElements.count) element(s)")
    }

    private func deduplicatedWebContexts(_ elements: [WebContext]) -> [WebContext] {
        var seen = Set<String>()
        return elements.filter { context in
            let bbox: String
            if let box = context.boundingBox {
                let x = box.x.map(String.init) ?? "?"
                let y = box.y.map(String.init) ?? "?"
                let width = box.width.map(String.init) ?? "?"
                let height = box.height.map(String.init) ?? "?"
                bbox = [x, y, width, height].joined(separator: ",")
            } else {
                bbox = ""
            }
            let pageURL = context.pageUrl ?? ""
            let selector = context.selector ?? ""
            let elementName = context.elementName ?? ""
            let key = [pageURL, selector, elementName, bbox].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    // MARK: - Send Messages to Extension

    private func send(_ payload: [String: Any], identifier: String, on connection: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: identifier, metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    public func requestRegionContext(
        screenX: CGFloat,
        screenY: CGFloat,
        width: CGFloat,
        height: CGFloat,
        purpose: RegionContextPurpose = .screenshot
    ) {
        let readyConnections = connections.values.filter { $0.state == .ready }
        guard !readyConnections.isEmpty else {
            debugLog("WebSocketService: Region context request skipped - no connected clients")
            return
        }

        // Native selection/capture rects are AppKit global coordinates (origin
        // bottom-left, Y up). The extension compares against browser screen
        // coordinates (origin top-left, Y down), so flip the Y axis here.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let quartzY = primaryHeight - screenY - height
        let queryID = UUID().uuidString
        activeRegionQueryFallbackTask?.cancel()
        activeRegionQueryID = queryID
        activeRegionQueryPurpose = purpose
        activeRegionQueryResolved = false
        let payload: [String: Any] = [
            "type": "regionQuery",
            "data": [
                "queryId": queryID,
                "purpose": purpose.rawValue,
                "screenX": screenX,
                "screenY": quartzY,
                "width": width,
                "height": height,
                "maxElements": purpose == .textSelection ? 1 : 20
            ]
        ]

        let primaryConnection = lastInteractedConnection.flatMap { connection in
            connection.state == .ready ? connection : nil
        }
        let primaryID = primaryConnection.map(ObjectIdentifier.init)

        if let primaryConnection {
            send(payload, identifier: "regionQuery", on: primaryConnection)
        }

        let fallback = DispatchWorkItem { [weak self] in
            guard let self,
                  self.activeRegionQueryID == queryID,
                  !self.activeRegionQueryResolved
            else { return }

            let targets = self.connections.values.filter { connection in
                guard connection.state == .ready else { return false }
                if let primaryID {
                    return ObjectIdentifier(connection) != primaryID
                }
                return true
            }
            for connection in targets {
                self.send(payload, identifier: "regionQuery", on: connection)
            }
            debugLog("WebSocketService: Broadcast region context fallback query=\(queryID) to \(targets.count) client(s)")
        }
        activeRegionQueryFallbackTask = fallback

        if primaryConnection == nil {
            fallback.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: fallback)
        }
        debugLog("WebSocketService: Requested region context query=\(queryID) purpose=\(purpose.rawValue) primary=\(primaryConnection != nil)")
    }

    public func dismissRegionHighlight() {
        let readyConnections = connections.values.filter { $0.state == .ready }
        guard !readyConnections.isEmpty else { return }
        let payload: [String: Any] = [
            "type": "dismissRegionHighlight",
            "data": [String: Any]()
        ]
        for connection in readyConnections {
            send(payload, identifier: "dismissRegionHighlight", on: connection)
        }
    }

    public func sendShortcutConfig(to specificConnection: NWConnection? = nil) {
        let settings = SettingsManager.shared
        let payload: [String: Any] = [
            "type": "shortcutConfig",
            "data": [
                "grab-element": [
                    "key": settings.extensionGrabElementShortcut.key,
                    "modifiers": settings.extensionGrabElementShortcut.modifiers,
                ],
                "region-select": [
                    "key": settings.extensionRegionSelectShortcut.key,
                    "modifiers": settings.extensionRegionSelectShortcut.modifiers,
                ],
            ]
        ]

        let targets = specificConnection.map { [$0] } ?? Array(connections.values)
        guard !targets.isEmpty else { return }

        for connection in targets {
            send(payload, identifier: "shortcutConfig", on: connection)
        }
        debugLog("WebSocketService: Sent shortcut config to \(targets.count) client(s)")
    }

    private func observeShortcutSettings() {
        shortcutCancellables.removeAll()
        let settings = SettingsManager.shared
        settings.$extensionGrabElementShortcut
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.sendShortcutConfig()
                }
            }
            .store(in: &shortcutCancellables)
        settings.$extensionRegionSelectShortcut
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.sendShortcutConfig()
                }
            }
            .store(in: &shortcutCancellables)
    }
}
