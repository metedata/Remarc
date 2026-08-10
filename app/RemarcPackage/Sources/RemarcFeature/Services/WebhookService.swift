import Foundation
import CryptoKit

/// Dispatches comment events to user-configured webhook endpoints as HTTP POST
/// requests. Generic by design: any service that accepts JSON (Zapier, Make,
/// n8n, IFTTT, Slack/Discord incoming webhooks) can consume these without
/// Remarc integrating with it directly.
@MainActor
public final class WebhookService: ObservableObject {
    public static let shared = WebhookService()

    public enum DeliveryOutcome: Equatable {
        case success(Date)
        case failure(Date, String)
    }

    /// Last delivery outcome per webhook id, in-memory only. Drives the status
    /// icon in Preferences.
    @Published public private(set) var lastDeliveries: [UUID: DeliveryOutcome] = [:]

    private let urlSession: URLSession

    /// Retry schedule: initial attempt plus two retries.
    private static let retryDelays: [Duration] = [.zero, .seconds(2), .seconds(10)]
    private static let requestTimeout: TimeInterval = 10

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.requestTimeout
        // Hard ceiling per attempt. timeoutIntervalForRequest is an idle timer
        // that resets on every byte, so a trickling endpoint could otherwise
        // pin a delivery for the 7-day default.
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: config)
    }

    // MARK: - Dispatch

    /// Fire an event to every enabled webhook subscribed to it.
    /// Called from PersistenceManager mutators and the reload diff.
    public func dispatch(_ event: WebhookEventType, comment: Comment) {
        let hooks = SettingsManager.shared.webhooks.filter { $0.isEnabled && $0.events.contains(event) }
        guard !hooks.isEmpty else { return }
        let session = PersistenceManager.shared.appState.sessions.first { $0.id == comment.sessionID }
        for hook in hooks {
            deliver(hook, event: event, comment: comment, session: session, toastOnSuccess: false)
        }
    }

    /// Per-card manual send. Ignores event subscriptions and the enabled flag is
    /// checked by the caller (the card only lists enabled webhooks).
    public func sendManually(_ webhook: Webhook, comment: Comment) {
        let session = PersistenceManager.shared.appState.sessions.first { $0.id == comment.sessionID }
        deliver(webhook, event: .commentSent, comment: comment, session: session, toastOnSuccess: true)
    }

    /// Test button in Preferences. Sends a sample payload; returns on completion.
    public func sendTest(_ webhook: Webhook) async {
        let sample = Comment(
            type: .comment(text: "This is a sample selection from a test event."),
            commentText: "Test comment from Remarc webhook settings.",
            source: "Remarc",
            appBundleID: "com.metepolat.Remarc",
            sessionID: PersistenceManager.shared.appState.activeSessionID ?? UUID()
        )
        let session = PersistenceManager.shared.activeSession
        await performDelivery(webhook, event: .webhookTest, comment: sample, session: session, toastOnSuccess: false)
    }

    private func deliver(
        _ webhook: Webhook,
        event: WebhookEventType,
        comment: Comment,
        session: Session?,
        toastOnSuccess: Bool
    ) {
        Task { @MainActor in
            await performDelivery(webhook, event: event, comment: comment, session: session, toastOnSuccess: toastOnSuccess)
        }
    }

    private func performDelivery(
        _ webhook: Webhook,
        event: WebhookEventType,
        comment: Comment,
        session: Session?,
        toastOnSuccess: Bool
    ) async {
        guard webhook.hasValidURL, let url = URL(string: webhook.url) else {
            recordFailure(webhook, message: "Invalid URL")
            return
        }

        let now = Date()
        let body: Data
        if let template = webhook.customTemplate,
           !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = Self.renderTemplate(
                template,
                event: event,
                comment: comment,
                sessionName: session?.name,
                sessionID: session?.id,
                timestamp: now
            )
        } else {
            body = Self.buildDefaultBody(
                event: event,
                comment: comment,
                sessionName: session?.name,
                sessionID: session?.id,
                timestamp: now,
                appVersion: Self.appVersion
            )
        }

        // Stable across retries so receivers can dedup.
        let deliveryID = UUID().uuidString.lowercased()
        var lastError = "Unknown error"

        for (attempt, delay) in Self.retryDelays.enumerated() {
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }

            let timestamp = String(Int(Date().timeIntervalSince1970))
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = Self.requestTimeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(deliveryID, forHTTPHeaderField: "webhook-id")
            request.setValue(timestamp, forHTTPHeaderField: "webhook-timestamp")
            if let secret = webhook.secret, !secret.isEmpty {
                let signature = Self.signature(secret: secret, id: deliveryID, timestamp: timestamp, body: body)
                request.setValue(signature, forHTTPHeaderField: "webhook-signature")
            }
            request.httpBody = body

            do {
                let (_, response) = try await urlSession.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if (200...299).contains(http.statusCode) {
                        lastDeliveries[webhook.id] = .success(Date())
                        debugLog("WebhookService: Delivered \(event.rawValue) to '\(webhook.name)' (attempt \(attempt + 1))")
                        if toastOnSuccess {
                            ToastManager.shared.show("Sent to \(webhook.name)")
                        }
                        return
                    }
                    lastError = "HTTP \(http.statusCode)"
                } else {
                    lastError = "No HTTP response"
                }
            } catch {
                lastError = error.localizedDescription
            }
            debugLog("WebhookService: Attempt \(attempt + 1) failed for '\(webhook.name)' - \(lastError)")
        }

        recordFailure(webhook, message: lastError)
        ToastManager.shared.show("Webhook '\(webhook.name)' failed")
    }

    private func recordFailure(_ webhook: Webhook, message: String) {
        lastDeliveries[webhook.id] = .failure(Date(), message)
        debugLog("WebhookService: Delivery to '\(webhook.name)' failed - \(message)")
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    // MARK: - Payload

    private struct AppInfo: Encodable {
        let name: String
        let version: String
    }

    private struct SessionInfo: Encodable {
        let id: UUID
        let name: String
    }

    /// Encodes the comment's own fields plus the computed shortID into one object.
    private struct CommentBody: Encodable {
        let comment: Comment

        private enum ExtraKeys: String, CodingKey {
            case shortID
        }

        func encode(to encoder: Encoder) throws {
            try comment.encode(to: encoder)
            var container = encoder.container(keyedBy: ExtraKeys.self)
            try container.encode(comment.shortID, forKey: .shortID)
        }
    }

    private struct Payload: Encodable {
        let event: String
        let timestamp: Date
        let app: AppInfo
        let session: SessionInfo?
        let comment: CommentBody
    }

    nonisolated static func buildDefaultBody(
        event: WebhookEventType,
        comment: Comment,
        sessionName: String?,
        sessionID: UUID?,
        timestamp: Date,
        appVersion: String
    ) -> Data {
        let payload = Payload(
            event: event.rawValue,
            timestamp: timestamp,
            app: AppInfo(name: "Remarc", version: appVersion),
            session: sessionID.map { SessionInfo(id: $0, name: sessionName ?? "") },
            comment: CommentBody(comment: comment)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // Payload is fully Encodable-safe; a failure here would be a programmer error.
        return (try? encoder.encode(payload)) ?? Data("{}".utf8)
    }

    // MARK: - Templating

    /// Substitutes {{placeholder}} tokens with JSON-string-escaped values so
    /// templates like {"text": "{{comment.text}}"} stay valid JSON. Unknown
    /// placeholders are left intact. Single-pass over the original template:
    /// tokens that appear inside substituted VALUES are never re-substituted,
    /// so comment content can safely contain literal {{...}} text.
    nonisolated static func renderTemplate(
        _ template: String,
        event: WebhookEventType,
        comment: Comment,
        sessionName: String?,
        sessionID: UUID?,
        timestamp: Date
    ) -> Data {
        let formatter = ISO8601DateFormatter()
        let values: [String: String] = [
            "event": event.rawValue,
            "timestamp": formatter.string(from: timestamp),
            "comment.id": comment.id.uuidString,
            "comment.shortID": comment.shortID,
            "comment.text": comment.commentText,
            "comment.selectedText": comment.selectedText ?? "",
            "comment.status": comment.status.rawValue,
            "comment.source": comment.source,
            "comment.resolutionSummary": comment.resolutionSummary ?? "",
            "comment.resolvedBy": comment.resolvedBy ?? "",
            "session.id": sessionID?.uuidString ?? "",
            "session.name": sessionName ?? "",
        ]

        var rendered = ""
        rendered.reserveCapacity(template.count)
        var index = template.startIndex
        while index < template.endIndex {
            guard let open = template.range(of: "{{", range: index..<template.endIndex) else {
                rendered += template[index...]
                break
            }
            rendered += template[index..<open.lowerBound]
            guard let close = template.range(of: "}}", range: open.upperBound..<template.endIndex) else {
                rendered += template[open.lowerBound...]
                break
            }
            let key = String(template[open.upperBound..<close.lowerBound])
            if let value = values[key] {
                rendered += jsonEscape(value)
                index = close.upperBound
            } else if key.contains("{{") {
                // Stray "{{" before a real token: emit it and rescan from just after.
                rendered += "{{"
                index = open.upperBound
            } else {
                rendered += template[open.lowerBound..<close.upperBound]
                index = close.upperBound
            }
        }
        return Data(rendered.utf8)
    }

    /// Escapes a string for safe embedding inside a JSON string literal.
    nonisolated static func jsonEscape(_ string: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }

    // MARK: - Signing (Standard Webhooks convention)

    /// HMAC-SHA256 over "{id}.{timestamp}.{body}", base64-encoded with a "v1,"
    /// prefix. Secrets are trimmed (copy-paste whitespace must not change the
    /// key). whsec_ secrets are base64-decoded after stripping the prefix,
    /// accepting base64url and missing padding; if decoding still fails, the
    /// raw remainder (never the transport prefix) is used as key bytes.
    nonisolated static func signature(secret: String, id: String, timestamp: String, body: Data) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: SymmetricKey
        if trimmed.hasPrefix("whsec_") {
            let remainder = String(trimmed.dropFirst("whsec_".count))
            if let decoded = decodeBase64Flexible(remainder) {
                key = SymmetricKey(data: decoded)
            } else {
                key = SymmetricKey(data: Data(remainder.utf8))
            }
        } else {
            key = SymmetricKey(data: Data(trimmed.utf8))
        }
        var message = Data("\(id).\(timestamp).".utf8)
        message.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return "v1," + Data(mac).base64EncodedString()
    }

    /// Accepts standard base64, base64url, and unpadded forms.
    nonisolated private static func decodeBase64Flexible(_ string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let overhang = normalized.count % 4
        if overhang > 0 {
            normalized += String(repeating: "=", count: 4 - overhang)
        }
        return Data(base64Encoded: normalized)
    }
}

// MARK: - Reload Diff

/// Pure diff between two comment arrays, used by PersistenceManager.reloadFromDisk
/// to emit webhook events for changes made by out-of-process writers (MCP server,
/// CLI). Restores (undo) and pruned records fire nothing. Comment deletions that
/// are part of a session-delete cascade in the same reload (e.g. Claude Code
/// wind-down) are suppressed, matching the in-app deleteSession cascade which
/// fires nothing.
public enum WebhookEventDiff {
    public static func events(
        old: [Comment],
        new: [Comment],
        oldSessions: [Session] = [],
        newSessions: [Session] = []
    ) -> [(WebhookEventType, Comment)] {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let previouslyLiveSessions = Set(
            oldSessions.filter { !$0.isDeleted && !$0.isAutoDismissed }.map(\.id)
        )
        let nowDeadSessions = Set(
            newSessions.filter { $0.isDeleted || $0.isAutoDismissed }.map(\.id)
        )
        let cascadedSessions = previouslyLiveSessions.intersection(nowDeadSessions)

        var result: [(WebhookEventType, Comment)] = []

        for comment in new {
            guard let previous = oldByID[comment.id] else {
                if !comment.isDeleted {
                    result.append((.commentCreated, comment))
                }
                continue
            }
            if previous.isDeleted {
                // Still deleted, or restored via undo - both silent.
                continue
            }
            if comment.isDeleted {
                if !cascadedSessions.contains(comment.sessionID) {
                    result.append((.commentDeleted, comment))
                }
                continue
            }
            if previous.status != comment.status {
                result.append((comment.status == .resolved ? .commentResolved : .commentStatusChanged, comment))
            }
            if previous.commentText != comment.commentText
                || previous.attachments != comment.attachments
                || previous.sessionID != comment.sessionID {
                result.append((.commentUpdated, comment))
            }
        }
        return result
    }
}
