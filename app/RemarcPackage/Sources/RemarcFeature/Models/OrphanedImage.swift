import Foundation

public struct OrphanedImage: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let path: String
    public let deletedAt: Date

    public init(id: UUID = UUID(), path: String, deletedAt: Date) {
        self.id = id
        self.path = path
        self.deletedAt = deletedAt
    }
}
