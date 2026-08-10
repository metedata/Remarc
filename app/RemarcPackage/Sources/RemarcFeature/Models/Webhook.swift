import Foundation

/// Events a webhook can subscribe to. Raw values are the `event` field in payloads.
public enum WebhookEventType: String, Codable, CaseIterable, Sendable, Hashable {
    case commentCreated = "comment.created"
    case commentUpdated = "comment.updated"
    case commentStatusChanged = "comment.status_changed"
    case commentResolved = "comment.resolved"
    case commentDeleted = "comment.deleted"
    case commentSent = "comment.sent"
    case webhookTest = "webhook.test"

    /// Events a user can subscribe to. `comment.sent` (per-card manual send) and
    /// `webhook.test` bypass subscriptions, so they are not listed.
    public static var subscribable: [WebhookEventType] {
        [.commentCreated, .commentUpdated, .commentStatusChanged, .commentResolved, .commentDeleted]
    }

    public var label: String {
        switch self {
        case .commentCreated: return "Comment created"
        case .commentUpdated: return "Comment edited or moved"
        case .commentStatusChanged: return "Status changed"
        case .commentResolved: return "Comment resolved"
        case .commentDeleted: return "Comment deleted"
        case .commentSent: return "Sent manually"
        case .webhookTest: return "Test"
        }
    }
}

/// A user-configured outbound webhook endpoint.
public struct Webhook: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var url: String
    public var isEnabled: Bool
    public var events: Set<WebhookEventType>
    /// Optional HMAC signing secret (Standard Webhooks convention). Empty/nil = unsigned.
    public var secret: String?
    /// Optional custom payload template with {{placeholder}} substitution.
    /// Empty/nil = default JSON payload.
    public var customTemplate: String?

    public init(
        id: UUID = UUID(),
        name: String = "",
        url: String = "",
        isEnabled: Bool = true,
        events: Set<WebhookEventType> = Set(WebhookEventType.subscribable),
        secret: String? = nil,
        customTemplate: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.events = events
        self.secret = secret
        self.customTemplate = customTemplate
    }

    /// True when the URL parses as http(s) with a host.
    public var hasValidURL: Bool {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              parsed.host != nil else { return false }
        return true
    }
}
