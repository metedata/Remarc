import Foundation

private func formattedSize(_ mb: Int) -> String {
    if mb >= 1000 {
        let gb = Double(mb) / 1000.0
        return String(format: "%.1f GB", gb)
    }
    return "\(mb) MB"
}

public enum TranscriptionEngineType: String, CaseIterable, Identifiable, Sendable {
    case appleSpeech = "Apple Speech"
    case whisperKit = "WhisperKit"
    case parakeet = "Parakeet"

    public var id: String { rawValue }
}

public enum WhisperKitModelSize: String, CaseIterable, Identifiable, Sendable {
    case fast = "Fast"
    case balanced = "Balanced"
    case max = "Max"

    public var id: String { rawValue }

    public var modelIdentifier: String {
        switch self {
        case .fast: return "openai_whisper-tiny.en"
        case .balanced: return "openai_whisper-small.en"
        case .max: return "openai_whisper-large-v3_turbo_954MB"
        }
    }

    public var downloadSizeMB: Int {
        switch self {
        case .fast: return 75
        case .balanced: return 217
        case .max: return 954
        }
    }

    public var label: String {
        "\(rawValue) (\(formattedSize(downloadSizeMB)))"
    }
}

public enum ModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case preparing
    case downloaded
    case failed(message: String)
}

public enum ParakeetModelVersion: String, CaseIterable, Identifiable, Sendable {
    case v2 = "English"
    case v3 = "Multilingual"

    public var id: String { rawValue }

    public var downloadSizeMB: Int {
        switch self {
        case .v2: return 1200
        case .v3: return 1200
        }
    }

    public var label: String {
        "\(rawValue) (~\(formattedSize(downloadSizeMB)))"
    }
}
