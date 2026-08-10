@preconcurrency import AVFAudio
import Foundation
@preconcurrency import WhisperKit

// MARK: - Model Manager (MainActor, for Settings UI)

/// Manages WhisperKit model downloads, caching, and lifecycle.
/// Lives on MainActor so PreferencesView can call methods synchronously.
@MainActor
final class WhisperKitModelManager: ObservableObject {
    static let shared = WhisperKitModelManager()

    private init() {}

    @Published var downloadState: ModelDownloadState = .notDownloaded

    var activeDownloadModelID: String?

    private var cache: [String: WhisperKit] = [:]
    private var unloadTasks: [String: Task<Void, Never>] = [:]

    private static let unloadDelay: TimeInterval = 120

    private static let defaultRepo = "argmaxinc/whisperkit-coreml"

    static var downloadBaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("Remarc/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return modelsDir
    }

    /// Hub stores models at: downloadBase/models/<repo>/variant/
    static func modelPath(for model: WhisperKitModelSize) -> URL {
        downloadBaseURL
            .appendingPathComponent("models")
            .appendingPathComponent(defaultRepo)
            .appendingPathComponent(model.modelIdentifier)
    }

    func hasAnyModelDownloaded() -> Bool {
        WhisperKitModelSize.allCases.contains { isModelDownloaded($0) }
    }

    func isModelDownloaded(_ model: WhisperKitModelSize) -> Bool {
        let path = Self.modelPath(for: model)
        // Check for a known model file to confirm download completed
        let marker = path.appendingPathComponent("MelSpectrogram.mlmodelc")
        return FileManager.default.fileExists(atPath: marker.path)
    }

    func deleteModel(_ model: WhisperKitModelSize) {
        let path = Self.modelPath(for: model)
        if FileManager.default.fileExists(atPath: path.path) {
            let kit = cache.removeValue(forKey: model.modelIdentifier)
            unloadTasks[model.modelIdentifier]?.cancel()
            unloadTasks.removeValue(forKey: model.modelIdentifier)
            // Release CoreML model weights before deleting backing files.
            // File deletion must wait — mlmodelc bundles may be memory-mapped.
            Task {
                await kit?.unloadModels()
                try? FileManager.default.removeItem(at: path)
            }
            downloadState = .notDownloaded
            debugLog("WhisperKitModelManager: Deleted model \(model.modelIdentifier)")
        }
    }

    func refreshDownloadState(for model: WhisperKitModelSize) {
        // If the model files exist on disk, always show downloaded
        // (handles stale preparing/downloading state after task completion or cancellation)
        if isModelDownloaded(model) {
            if activeDownloadModelID == model.modelIdentifier {
                activeDownloadModelID = nil
            }
            downloadState = .downloaded
            return
        }
        if activeDownloadModelID == model.modelIdentifier {
            objectWillChange.send()
            return
        }
        downloadState = .notDownloaded
    }

    func cancelDownload() {
        activeDownloadModelID = nil
        downloadState = .notDownloaded
        debugLog("WhisperKitModelManager: Download cancelled")
    }

    /// Ensures the model is loaded and cached. Returns true if model is ready.
    func prepareModel(_ model: WhisperKitModelSize) async -> Bool {
        return await getOrLoadModel(model) != nil
    }

    /// Prewarm: load the model to trigger CoreML compilation/caching on disk,
    /// then discard from RAM. Subsequent loads will be fast cached loads.
    /// Call this at app launch in the background.
    func prewarmModel(_ model: WhisperKitModelSize) async {
        guard isModelDownloaded(model) else { return }
        let modelID = model.modelIdentifier

        // Already cached in RAM — no need to prewarm
        if cache[modelID] != nil { return }

        debugLog("WhisperKitModelManager: Prewarming model \(modelID) (CoreML cache)")
        let modelFolder = Self.modelPath(for: model)
        do {
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                verbose: false,
                prewarm: true,
                load: false,
                download: false
            )
            _ = try await WhisperKit(config)
            debugLog("WhisperKitModelManager: Prewarm complete for \(modelID)")
        } catch {
            debugLog("WhisperKitModelManager: Prewarm failed for \(modelID): \(error)")
        }
    }

    /// Transcribes audio using the specified model. Falls back to any cached model
    /// if the requested one isn't available. Returns nil only if no model is usable.
    /// Minimum audio length for reliable transcription (~2s at 16kHz).
    /// Clips shorter than this get zero-padded so Whisper's mel spectrogram
    /// has enough frames to recognize speech.
    private static let minSampleCount = 32_000
    /// WhisperKit clips the end of each decode window by default to reduce
    /// hallucinations. Add silence so that clipping lands after real speech.
    private static let finalizationPaddingSampleCount = 32_000

    func transcribeAudio(
        _ model: WhisperKitModelSize,
        audioArray: [Float]
    ) async throws -> [TranscriptionResult]? {
        guard let kit = await getOrLoadModel(model) ?? anyCachedModel() else { return nil }

        var samples = audioArray
        let isShort = samples.count < Self.minSampleCount
        let targetSampleCount = max(
            Self.minSampleCount,
            samples.count + Self.finalizationPaddingSampleCount
        )

        // Pad short clips with silence so the mel spectrogram has enough
        // frames for Whisper to recognize speech (single-word dictations).
        // Longer clips still get a silence tail so the decoder can close
        // out the final utterance before WhisperKit's end-window clipping.
        if samples.count < targetSampleCount {
            samples.append(contentsOf: [Float](repeating: 0, count: targetSampleCount - samples.count))
        }

        // Build prompt tokens from vocabulary hints to bias the decoder
        // toward domain-specific words (e.g. "Remarc" instead of "Remark").
        let promptTokens: [Int]? = kit.tokenizer.map {
            VocabularyHints.whisperPromptTokens(using: $0)
        }

        // Also disable the no-speech threshold for short clips - the high
        // silence-to-speech ratio from padding would otherwise cause Whisper
        // to classify the entire segment as blank.
        let options = DecodingOptions(
            wordTimestamps: true,
            promptTokens: promptTokens,
            noSpeechThreshold: isShort ? nil : 0.6
        )

        let results: [TranscriptionResult] = try await kit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        scheduleUnload(for: model)
        return results
    }

    /// Schedules unload for all cached models. Called when keepModelInMemory is toggled off.
    func scheduleUnloadIfIdle() {
        for modelID in cache.keys {
            if let model = WhisperKitModelSize.allCases.first(where: { $0.modelIdentifier == modelID }) {
                scheduleUnload(for: model)
            }
        }
    }

    /// Cancels all pending unload timers. Called when keepModelInMemory is toggled on
    /// to prevent a stale timer from evicting a model the user wants kept in memory.
    func cancelPendingUnloads() {
        for (modelID, task) in unloadTasks {
            task.cancel()
            debugLog("WhisperKitModelManager: Cancelled pending unload for \(modelID)")
        }
        unloadTasks.removeAll()
    }

    // MARK: - Private

    /// Returns any cached WhisperKit instance as a fallback when the requested model
    /// isn't available (e.g., user switched models and the new one is still downloading).
    private func anyCachedModel() -> WhisperKit? {
        if let (id, kit) = cache.first {
            debugLog("WhisperKitModelManager: Falling back to cached model \(id)")
            return kit
        }
        return nil
    }

    private func getOrLoadModel(_ model: WhisperKitModelSize) async -> WhisperKit? {
        let modelID = model.modelIdentifier

        // Cancel pending unload
        unloadTasks[modelID]?.cancel()
        unloadTasks.removeValue(forKey: modelID)

        // Return cached
        if let cached = cache[modelID] {
            debugLog("WhisperKitModelManager: Using cached model \(modelID)")
            return cached
        }

        // Cancel any existing download for a different model
        if let activeID = activeDownloadModelID, activeID != modelID {
            cancelDownload()
        }

        // Download then load (two-step for progress reporting)
        debugLog("WhisperKitModelManager: Loading model \(modelID)")
        activeDownloadModelID = modelID
        downloadState = .downloading(progress: 0)
        do {
            // Step 1: Download with progress callback
            let modelFolder = try await WhisperKit.download(
                variant: model.modelIdentifier,
                downloadBase: Self.downloadBaseURL,
                progressCallback: { @Sendable progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        guard WhisperKitModelManager.shared.activeDownloadModelID == modelID else { return }
                        WhisperKitModelManager.shared.downloadState = .downloading(progress: fraction)
                    }
                }
            )

            guard activeDownloadModelID == modelID else {
                debugLog("WhisperKitModelManager: Download completed but model was switched")
                return nil
            }

            // Step 2: Init from local path (no download)
            downloadState = .preparing
            debugLog("WhisperKitModelManager: Download complete, preparing model")
            let config = WhisperKitConfig(
                modelFolder: modelFolder.path,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            )
            let kit = try await WhisperKit(config)

            cache[modelID] = kit
            activeDownloadModelID = nil
            downloadState = .downloaded
            debugLog("WhisperKitModelManager: Model \(modelID) loaded")
            return kit
        } catch {
            activeDownloadModelID = nil
            if Task.isCancelled {
                downloadState = .notDownloaded
            } else {
                downloadState = .failed(message: error.localizedDescription)
            }
            debugLog("WhisperKitModelManager: Failed to load model \(modelID): \(error)")
            return nil
        }
    }

    private func scheduleUnload(for model: WhisperKitModelSize) {
        if SettingsManager.shared.keepModelInMemory {
            debugLog("WhisperKitModelManager: Keeping model in memory (user preference)")
            return
        }
        let modelID = model.modelIdentifier
        unloadTasks[modelID]?.cancel()
        unloadTasks[modelID] = Task {
            try? await Task.sleep(for: .seconds(Self.unloadDelay))
            guard !Task.isCancelled else { return }
            // Explicitly release CoreML model weights before dropping the WhisperKit instance.
            // ARC will deallocate the object graph, but nilling the MLModel references first
            // ensures GPU/ANE resources are freed even if CoreML retains internal references.
            await cache[modelID]?.unloadModels()
            cache.removeValue(forKey: modelID)
            unloadTasks.removeValue(forKey: modelID)
            debugLog("WhisperKitModelManager: Unloaded model \(modelID) after \(Self.unloadDelay)s idle")
        }
    }
}

// MARK: - WhisperKitEngine (TranscriptionEngine conformance)

@available(macOS 26, *)
struct WhisperKitEngine: TranscriptionEngine, Sendable {
    let modelSize: WhisperKitModelSize

    init(model: WhisperKitModelSize) {
        self.modelSize = model
    }

    func prepare() async throws {
        let ready = await WhisperKitModelManager.shared.prepareModel(modelSize)
        if !ready {
            debugLog("WhisperKitEngine: Model failed to prepare")
        }
    }

    func transcribe(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> String {
        let audioArray = AudioBufferConverter.convertToFloatArray(buffers: buffers, inputFormat: inputFormat)
        guard !audioArray.isEmpty else { return "" }

        guard let results = try await WhisperKitModelManager.shared.transcribeAudio(
            modelSize, audioArray: audioArray
        ) else {
            debugLog("WhisperKitEngine: Model unavailable, falling back to Apple Speech")
            let fallback = SpeechAnalyzerEngine()
            try await fallback.prepare()
            return try await fallback.transcribe(buffers: buffers, inputFormat: inputFormat)
        }

        let segments = results.flatMap(\.segments).map(\.remarcTranscriptSegment)
        if !segments.isEmpty {
            return WhisperKitTranscriptFormatter.transcript(
                from: segments,
                audioSamples: audioArray
            )
        }

        return results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
            .cleanedWhisperTranscriptText()
    }

    // MARK: - CritModeService Integration

    func transcribeSegments(
        buffers: [AVAudioPCMBuffer],
        inputFormat: AVAudioFormat
    ) async throws -> [String] {
        let audioArray = AudioBufferConverter.convertToFloatArray(buffers: buffers, inputFormat: inputFormat)
        guard !audioArray.isEmpty else { return [] }

        guard let results = try await WhisperKitModelManager.shared.transcribeAudio(
            modelSize, audioArray: audioArray
        ) else {
            debugLog("WhisperKitEngine: Model unavailable for segments")
            return []
        }

        let transcriptSegments = results.flatMap(\.segments).map(\.remarcTranscriptSegment)
        var segments = WhisperKitTranscriptFormatter.segmentTexts(
            from: transcriptSegments,
            audioSamples: audioArray
        )

        if segments.isEmpty && transcriptSegments.isEmpty {
            let fullText = results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
                .cleanedWhisperTranscriptText()
            if !fullText.isEmpty {
                segments.append(fullText)
            }
        }

        return segments
    }

}

// MARK: - WhisperKit Conversion

private extension TranscriptionSegment {
    var remarcTranscriptSegment: WhisperTranscriptSegment {
        WhisperTranscriptSegment(
            text: text,
            start: start,
            end: end,
            words: words?.map {
                WhisperTranscriptWord(
                    word: $0.word,
                    start: $0.start,
                    end: $0.end
                )
            } ?? []
        )
    }
}
