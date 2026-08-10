import Foundation
import SwiftUI

public enum CommentStatus: String, Codable, Sendable, CaseIterable {
    case open
    case handedOff
    case inProgress
    case resolved

    public var label: String {
        switch self {
        case .open: return "Open"
        case .handedOff: return "Handed Off"
        case .inProgress: return "In-Progress"
        case .resolved: return "Resolved"
        }
    }

    public static func color(for status: CommentStatus, colorScheme: ColorScheme) -> Color {
        switch status {
        case .open:       return Color.remarcSecondary(for: colorScheme)
        case .handedOff:  return Color.remarcInfo(for: colorScheme)
        case .inProgress: return Color.remarcWarning(for: colorScheme)
        case .resolved:   return Color.remarcSuccess(for: colorScheme)
        }
    }
}
