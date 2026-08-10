import Foundation

public struct Transcription: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var appBundleID: String?
    public var appName: String?
    public let createdAt: Date
    public var isDeleted: Bool
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        text: String,
        appBundleID: String? = nil,
        appName: String? = nil,
        createdAt: Date = Date(),
        isDeleted: Bool = false,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.appBundleID = appBundleID
        self.appName = appName
        self.createdAt = createdAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }
}
