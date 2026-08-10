@preconcurrency import AVFAudio
import FluidAudio
import Foundation

// MARK: - Model Manager (MainActor, for Settings UI)

@MainActor
final class ParakeetModelManager: ObservableObject {
    static let shared = ParakeetModelManager()

    private init() {}

    @Published var downloadState: ModelDownloadState = .notDownloaded

    var activeDownloadVersion: ParakeetModelVersion?

    private var loadedModels: AsrModels?
    private var loadedVersion: ParakeetModelVersion?
    private var unloadTask: Task<Void, Never>?

    private static let unloadDelay: TimeInterval = 120

    private static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Remarc/parakeet-models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func modelPath(for version: ParakeetModelVersion) -> URL {
        // FluidAudio's downloadAndLoad expects a directory and creates
        // repo-named subdirs inside its parent. We pass a version-named
        // child so the parent is modelsDirectory and the repo folder
        // lands as a sibling. modelsExist checks the repo-based path.
        modelsDirectory.appendingPathComponent(version.rawValue, isDirectory: true)
    }

    func isModelDownloaded(_ version: ParakeetModelVersion) -> Bool {
        let fluidVersion: AsrModelVersion = version == .v2 ? .v2 : .v3
        return AsrModels.modelsExist(at: Self.modelPath(for: version), version: fluidVersion)
    }

    func hasAnyModelDownloaded() -> Bool {
        ParakeetModelVersion.allCases.contains { isModelDownloaded($0) }
    }

    /// The actual on-disk folder where FluidAudio stores model files.
    /// ModelHub puts them at `parentDir/<repo-folder-name>/`.
    private static func repoFolder(for version: ParakeetModelVersion) -> URL {
        let repoName = version == .v2
            ? "parakeet-tdt-0.6b-v2-coreml"
            : "parakeet-tdt-0.6b-v3-coreml"
        return modelsDirectory.appendingPathComponent(repoName, isDirectory: true)
    }

    func deleteModel(_ version: ParakeetModelVersion) {
        let repoPath = Self.repoFolder(for: version)
        guard FileManager.default.fileExists(atPath: repoPath.path) else {
            debugLog("ParakeetModelManager: No model to delete at \(repoPath.path)")
            downloadState = .notDownloaded
            return
        }

        if loadedVersion == version {
            loadedModels = nil
            loadedVersion = nil
        }
        unloadTask?.cancel()
        unloadTask = nil
        try? FileManager.default.removeItem(at: repoPath)
        downloadState = .notDownloaded
        debugLog("ParakeetModelManager: Deleted model \(version.rawValue)")
    }

    func refreshDownloadState(for version: ParakeetModelVersion) {
        // If the model files exist on disk, always show downloaded
        // (handles stale preparing/downloading state after task completion or cancellation)
        if isModelDownloaded(version) {
            if activeDownloadVersion == version {
                activeDownloadVersion = nil
            }
            downloadState = .downloaded
            return
        }
        if activeDownloadVersion == version {
            objectWillChange.send()
            return
        }
        downloadState = .notDownloaded
    }

    func cancelDownload() {
        activeDownloadVersion = nil
        downloadState = .notDownloaded
        debugLog("ParakeetModelManager: Download cancelled")
    }

    func prepareModel(_ version: ParakeetModelVersion) async -> Bool {
        return await getOrLoadModels(version) != nil
    }

    func transcribeAudio(
        _ version: ParakeetModelVersion,
        audioArray: [Float]
    ) async throws -> String? {
        guard let models = await getOrLoadModels(version) else { return nil }

        let manager = AsrManager(config: .default, models: models)
        var decoderState = try TdtDecoderState()
        let result: ASRResult
        // cleanup() is actor-isolated and defer can't await, so call it on both paths.
        do {
            result = try await manager.transcribe(audioArray, decoderState: &decoderState)
            await manager.cleanup()
        } catch {
            await manager.cleanup()
            throw error
        }

        scheduleUnload()
        return result.text
    }

    /// Schedules unload if a model is currently loaded. Called when keepModelInMemory is toggled off.
    func scheduleUnloadIfIdle() {
        guard loadedModels != nil else { return }
        scheduleUnload()
    }

    /// Cancels any pending unload timer. Called when keepModelInMemory is toggled on
    /// to prevent a stale timer from evicting a model the user wants kept in memory.
    func cancelPendingUnloads() {
        guard unloadTask != nil else { return }
        unloadTask?.cancel()
        unloadTask = nil
        debugLog("ParakeetModelManager: Cancelled pending unload")
    }

    // MARK: - Private

    private func fluidVersion(for version: ParakeetModelVersion) -> AsrModelVersion {
        switch version {
        case .v2: return .v2
        case .v3: return .v3
        }
    }

    private func getOrLoadModels(_ version: ParakeetModelVersion) async -> AsrModels? {
        unloadTask?.cancel()
        unloadTask = nil

        if let loaded = loadedModels, loadedVersion == version {
            debugLog("ParakeetModelManager: Using cached models (\(version.rawValue))")
            return loaded
        }

        if let activeVersion = activeDownloadVersion, activeVersion != version {
            cancelDownload()
        }

        debugLog("ParakeetModelManager: Loading models (\(version.rawValue))")
        activeDownloadVersion = version
        downloadState = .downloading(progress: 0)

        do {
            let modelDir = Self.modelPath(for: version)
            let versionID = version
            let models = try await AsrModels.downloadAndLoad(
                to: modelDir,
                version: fluidVersion(for: version)
            ) { @Sendable progress in
                let fraction = progress.fractionCompleted
                Task { @MainActor in
                    guard ParakeetModelManager.shared.activeDownloadVersion == versionID else { return }
                    ParakeetModelManager.shared.downloadState = .downloading(progress: fraction)
                }
            }

            guard activeDownloadVersion == version else {
                debugLog("ParakeetModelManager: Download completed but version was switched")
                return nil
            }

            loadedModels = models
            loadedVersion = version
            activeDownloadVersion = nil
            downloadState = .downloaded
            debugLog("ParakeetModelManager: Models loaded (\(version.rawValue))")
            return models
        } catch {
            activeDownloadVersion = nil
            if Task.isCancelled {
                downloadState = .notDownloaded
            } else {
                downloadState = .failed(message: error.localizedDescription)
            }
            debugLog("ParakeetModelManager: Failed to load models: \(error)")
            return nil
        }
    }

    private func scheduleUnload() {
        if SettingsManager.shared.keepModelInMemory {
            debugLog("ParakeetModelManager: Keeping model in memory (user preference)")
            return
        }
        unloadTask?.cancel()
        unloadTask = Task {
            try? await Task.sleep(for: .seconds(Self.unloadDelay))
            guard !Task.isCancelled else { return }
            loadedModels = nil
            loadedVersion = nil
            debugLog("ParakeetModelManager: Unloaded models after \(Self.unloadDelay)s idle")
        }
    }
}

// MARK: - ParakeetEngine (TranscriptionEngine conformance)

@available(macOS 26, *)
struct ParakeetEngine: TranscriptionEngine, Sendable {
    let modelVersion: ParakeetModelVersion

    init(version: ParakeetModelVersion) {
        self.modelVersion = version
    }

    func prepare() async throws {
        let ready = await ParakeetModelManager.shared.prepareModel(modelVersion)
        if !ready {
            debugLog("ParakeetEngine: Model failed to prepare")
        }
    }

    func transcribe(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> String {
        let audioArray = AudioBufferConverter.convertToFloatArray(buffers: buffers, inputFormat: inputFormat)
        guard !audioArray.isEmpty else { return "" }

        guard let text = try await ParakeetModelManager.shared.transcribeAudio(
            modelVersion, audioArray: audioArray
        ) else {
            debugLog("ParakeetEngine: Model unavailable, falling back to Apple Speech")
            let fallback = SpeechAnalyzerEngine()
            try await fallback.prepare()
            return try await fallback.transcribe(buffers: buffers, inputFormat: inputFormat)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribeSegments(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> [String] {
        let text = try await transcribe(buffers: buffers, inputFormat: inputFormat)
        guard !text.isEmpty else { return [] }

        // Parakeet returns punctuated text. Split on sentence boundaries
        // to give Foundation Models better starting points for segmentation.
        var segments: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { substring, _, _, _ in
            if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                segments.append(sentence)
            }
        }
        return segments.isEmpty ? [text] : segments
    }
}
