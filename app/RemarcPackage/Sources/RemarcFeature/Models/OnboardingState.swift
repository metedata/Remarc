import Foundation

public enum PermissionRowState: Equatable, Sendable {
    case needsPermission
    case waitingForGrant
    case granted
}
