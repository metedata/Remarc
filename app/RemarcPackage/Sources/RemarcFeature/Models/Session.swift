import Foundation

public enum SessionOrigin: String, Codable, Sendable {
    case manual
    case claudeCode
    case codex
}

public struct Session: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var isDeleted: Bool
    public var deletedAt: Date?
    public var isAutoDismissed: Bool
    public var autoDismissedAt: Date?
    public var origin: SessionOrigin
    public var claudeCodeSessionId: String?
    /// Session keys written by a newer build, carried through untouched.
    public var unknownFields: [String: JSONValue]
    /// The `origin` string exactly as it was read, kept when this build does
    /// not recognise it. Without this, an older app reading a session created
    /// by a harness it has never heard of would decode `manual` and then write
    /// `manual` back, quietly relabelling someone else's session.
    private var rawOrigin: String?

    public var isInbox: Bool {
        name == AppConstants.inboxSessionName
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, isDeleted, deletedAt
        case isAutoDismissed, autoDismissedAt
        case origin, claudeCodeSessionId
    }

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        isAutoDismissed: Bool = false,
        autoDismissedAt: Date? = nil,
        origin: SessionOrigin = .manual,
        claudeCodeSessionId: String? = nil,
        unknownFields: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.isAutoDismissed = isAutoDismissed
        self.autoDismissedAt = autoDismissedAt
        self.origin = origin
        self.claudeCodeSessionId = claudeCodeSessionId
        self.unknownFields = unknownFields
        self.rawOrigin = origin.rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isDeleted = try container.decode(Bool.self, forKey: .isDeleted)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        isAutoDismissed = try container.decode(Bool.self, forKey: .isAutoDismissed)
        autoDismissedAt = try container.decodeIfPresent(Date.self, forKey: .autoDismissedAt)
        // Decoded through the raw string, never as the enum directly.
        // `decodeIfPresent` returns nil only for an absent key - a *present*
        // value the enum does not know throws, which would fail the whole
        // session and take the file's decode down with it. Harnesses are added
        // on the plugin's release schedule, not the app's, so an older app is
        // routinely the one reading a newer harness's sessions.
        rawOrigin = try container.decodeIfPresent(String.self, forKey: .origin)
        origin = rawOrigin.flatMap(SessionOrigin.init(rawValue:)) ?? .manual
        claudeCodeSessionId = try container.decodeIfPresent(String.self, forKey: .claudeCodeSessionId)

        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        unknownFields = dynamic.unknownFields(besides: Self.modelledKeys)
    }

    private static let modelledKeys: Set<String> = [
        "id", "name", "createdAt", "isDeleted", "deletedAt",
        "isAutoDismissed", "autoDismissedAt", "origin", "claudeCodeSessionId",
    ]

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isDeleted, forKey: .isDeleted)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encode(isAutoDismissed, forKey: .isAutoDismissed)
        try container.encodeIfPresent(autoDismissedAt, forKey: .autoDismissedAt)
        // An unrecognised origin round-trips as its original string.
        if let rawOrigin, SessionOrigin(rawValue: rawOrigin) == nil {
            try container.encode(rawOrigin, forKey: .origin)
        } else {
            try container.encode(origin, forKey: .origin)
        }
        try container.encodeIfPresent(claudeCodeSessionId, forKey: .claudeCodeSessionId)

        var dynamic = encoder.container(keyedBy: DynamicCodingKey.self)
        try dynamic.encodeUnknownFields(unknownFields, skipping: Self.modelledKeys)
    }
}
