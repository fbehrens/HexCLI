//
//  TranscriptionEngine.swift
//  HexCLI
//
//  Handles model download, loading, and transcription for both WhisperKit and Parakeet backends.
//

import AVFoundation
@preconcurrency import FluidAudio
import Foundation
@preconcurrency import WhisperKit

/// Actor-based transcription engine supporting both WhisperKit and Parakeet backends.
actor TranscriptionEngine {
    // MARK: - Stored Properties

    private var whisperKit: WhisperKit?
    private var currentModelName: String?
    // AsrManager is internally thread-safe
    private nonisolated(unsafe) var asrManager: AsrManager?
    private var asrModels: AsrModels?
    private var currentParakeetVariant: ParakeetModel?

    private lazy var modelsBaseFolder: URL = {
        do {
            let appSupportURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let ourAppFolder = appSupportURL.appendingPathComponent("com.kitlangton.Hex", isDirectory: true)
            let baseURL = ourAppFolder.appendingPathComponent("models", isDirectory: true)
            try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
            return baseURL
        } catch {
            fatalError("Could not create Application Support folder: \(error)")
        }
    }()

    // MARK: - Public Methods

    /// Transcribes an audio file using the specified model.
    func transcribe(
        url: URL,
        model: String,
        language: String?,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> DetailedTranscription {
        if isParakeet(model) {
            return try await transcribeWithParakeet(url: url, model: model, progressCallback: progressCallback)
        } else {
            return try await transcribeWithWhisperKit(
                url: url,
                model: model,
                language: language,
                progressCallback: progressCallback
            )
        }
    }

    /// Returns a list of all available models (Parakeet + WhisperKit).
    func getAvailableModels() async throws -> [String] {
        var names = try await WhisperKit.fetchAvailableModels()
        for model in ParakeetModel.allCases.reversed() {
            if !names.contains(model.identifier) {
                names.insert(model.identifier, at: 0)
            }
        }
        return names
    }

    /// Checks if a model is already downloaded.
    func isModelDownloaded(_ modelName: String) async -> Bool {
        if isParakeet(modelName) {
            return isParakeetModelDownloaded(modelName)
        }
        return isWhisperKitModelDownloaded(modelName)
    }

    // MARK: - Diarization (FluidAudio offline)

    /// Runs speaker diarization on an audio file using FluidAudio's OfflineDiarizerManager.
    func diarize(url: URL) async throws -> [DiarSpeakerSegment] {
        let config = OfflineDiarizerConfig()
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()

        let result = try await manager.process(url)
        return result.segments.map { seg in
            DiarSpeakerSegment(
                speaker: seg.speakerId,
                start: seg.startTimeSeconds,
                end: seg.endTimeSeconds
            )
        }
    }

    // MARK: - Parakeet Transcription

    private func transcribeWithParakeet(
        url: URL,
        model: String,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> DetailedTranscription {
        guard let variant = ParakeetModel(rawValue: model) else {
            throw TranscriptionError.unsupportedModel(model)
        }

        // Load model if needed
        try await ensureParakeetLoaded(variant: variant, progressCallback: progressCallback)

        // Prepare audio (pad short clips)
        let prepared = try AudioPreparer.ensureMinimumDuration(url: url)
        defer { prepared.cleanup() }

        // Transcribe
        guard let asr = asrManager else {
            throw TranscriptionError.modelNotLoaded
        }

        let result = try await asr.transcribe(prepared.url)

        // Merge BPE sub-tokens into whole words.
        // Parakeet prefixes word-initial tokens with a space; continuation tokens have none.
        var words: [DetailedWord] = []
        if let timings = result.tokenTimings {
            var buf = ""
            var wStart: TimeInterval = 0
            var wEnd: TimeInterval = 0
            var confSum: Double = 0
            var confCount = 0

            for timing in timings {
                let isWordStart = timing.token.hasPrefix(" ") || buf.isEmpty
                if isWordStart && !buf.isEmpty {
                    words.append(DetailedWord(
                        text: buf.trimmingCharacters(in: .whitespaces),
                        start: wStart,
                        end: wEnd,
                        confidence: confSum / Double(confCount),
                        speaker: nil
                    ))
                    buf = ""
                    confSum = 0
                    confCount = 0
                }
                if buf.isEmpty {
                    wStart = timing.startTime
                }
                buf += timing.token
                wEnd = timing.endTime
                confSum += Double(timing.confidence)
                confCount += 1
            }
            if !buf.isEmpty {
                words.append(DetailedWord(
                    text: buf.trimmingCharacters(in: .whitespaces),
                    start: wStart,
                    end: wEnd,
                    confidence: confSum / Double(confCount),
                    speaker: nil
                ))
            }
        }

        return DetailedTranscription(text: result.text, words: words)
    }

    private func ensureParakeetLoaded(
        variant: ParakeetModel,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws {
        if currentParakeetVariant == variant, asrManager != nil {
            return
        }

        // Reset if switching variants
        if currentParakeetVariant != variant {
            asrManager = nil
            asrModels = nil
        }

        let progress = Progress(totalUnitCount: 100)
        progress.completedUnitCount = 1
        progressCallback?(progress)

        // Best-effort progress polling while FluidAudio downloads
        let fm = FileManager.default
        let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let faDir = support?.appendingPathComponent("FluidAudio/Models/\(variant.identifier)", isDirectory: true)

        let pollTask = Task {
            while progress.completedUnitCount < 95 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let dir = faDir, let size = self.directorySize(dir) {
                    let target: Double = 650 * 1024 * 1024 // ~650MB
                    let frac = max(0.0, min(1.0, Double(size) / target))
                    progress.completedUnitCount = Int64(5 + frac * 90)
                    progressCallback?(progress)
                }
                if Task.isCancelled { break }
            }
        }
        defer { pollTask.cancel() }

        // Download and load
        let asrVersion: AsrModelVersion = variant == .englishV2 ? .v2 : .v3
        let models = try await AsrModels.downloadAndLoad(version: asrVersion)
        self.asrModels = models

        let manager = AsrManager(config: .init())
        try await manager.initialize(models: models)
        self.asrManager = manager
        self.currentParakeetVariant = variant

        progress.completedUnitCount = 100
        progressCallback?(progress)
    }

    private func isParakeetModelDownloaded(_ modelName: String) -> Bool {
        guard let variant = ParakeetModel(rawValue: modelName) else {
            return false
        }

        let vendorDirs = ["FluidAudio/Models", "fluidaudio/Models"]

        for root in candidateRoots() {
            for vendor in vendorDirs {
                let modelDir = root
                    .appendingPathComponent(vendor, isDirectory: true)
                    .appendingPathComponent(variant.identifier, isDirectory: true)
                if directoryContainsMLModelC(modelDir) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - WhisperKit Transcription

    private func transcribeWithWhisperKit(
        url: URL,
        model: String,
        language: String?,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws -> DetailedTranscription {
        // Load model if needed
        if whisperKit == nil || model != currentModelName {
            unloadCurrentModel()
            try await downloadAndLoadWhisperKit(variant: model, progressCallback: progressCallback)
        }

        guard let whisperKit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        // Configure decoding options
        var options = DecodingOptions()
        options.wordTimestamps = true
        if let language = language {
            options.language = language
        }

        // Transcribe
        let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")

        var words: [DetailedWord] = []
        for result in results {
            for segment in result.segments {
                guard let timings = segment.words else { continue }
                for w in timings {
                    words.append(DetailedWord(
                        text: w.word,
                        start: Double(w.start),
                        end: Double(w.end),
                        confidence: Double(w.probability),
                        speaker: nil
                    ))
                }
            }
        }

        return DetailedTranscription(text: text, words: words)
    }

    private func downloadAndLoadWhisperKit(
        variant: String,
        progressCallback: (@Sendable (Progress) -> Void)?
    ) async throws {
        let overallProgress = Progress(totalUnitCount: 100)
        overallProgress.completedUnitCount = 0
        progressCallback?(overallProgress)

        // Download phase (0-50%)
        if !(await isModelDownloaded(variant)) {
            try await downloadModelIfNeeded(variant: variant) { downloadProgress in
                let fraction = downloadProgress.fractionCompleted * 0.5
                overallProgress.completedUnitCount = Int64(fraction * 100)
                progressCallback?(overallProgress)
            }
        } else {
            overallProgress.completedUnitCount = 50
            progressCallback?(overallProgress)
        }

        // Loading phase (50-100%)
        try await loadWhisperKitModel(variant) { loadingProgress in
            let fraction = 0.5 + (loadingProgress.fractionCompleted * 0.5)
            overallProgress.completedUnitCount = Int64(fraction * 100)
            progressCallback?(overallProgress)
        }

        overallProgress.completedUnitCount = 100
        progressCallback?(overallProgress)
    }

    private func downloadModelIfNeeded(
        variant: String,
        progressCallback: @Sendable @escaping (Progress) -> Void
    ) async throws {
        let modelFolder = modelPath(for: variant)
        let isDownloaded = isWhisperKitModelDownloaded(variant)

        if FileManager.default.fileExists(atPath: modelFolder.path), !isDownloaded {
            try FileManager.default.removeItem(at: modelFolder)
        }

        if isDownloaded { return }

        let parentDir = modelFolder.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let tempFolder = try await WhisperKit.download(
            variant: variant,
            downloadBase: nil,
            useBackgroundSession: false,
            progressCallback: progressCallback
        )

        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        try moveContents(of: tempFolder, to: modelFolder)
    }

    private func loadWhisperKitModel(
        _ modelName: String,
        progressCallback: @Sendable @escaping (Progress) -> Void
    ) async throws {
        let loadingProgress = Progress(totalUnitCount: 100)
        loadingProgress.completedUnitCount = 0
        progressCallback(loadingProgress)

        let modelFolder = modelPath(for: modelName)
        let tokenizerFolder = tokenizerPath(for: modelName)

        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerFolder,
            prewarm: false,
            load: true
        )

        whisperKit = try await WhisperKit(config)
        currentModelName = modelName

        loadingProgress.completedUnitCount = 100
        progressCallback(loadingProgress)
    }

    private func isWhisperKitModelDownloaded(_ modelName: String) -> Bool {
        let modelFolderPath = modelPath(for: modelName).path
        let fm = FileManager.default

        guard fm.fileExists(atPath: modelFolderPath) else { return false }

        do {
            let contents = try fm.contentsOfDirectory(atPath: modelFolderPath)
            guard !contents.isEmpty else { return false }

            let hasModelFiles = contents.contains { $0.hasSuffix(".mlmodelc") || $0.contains("model") }
            let tokenizerFolderPath = tokenizerPath(for: modelName).path
            let hasTokenizer = fm.fileExists(atPath: tokenizerFolderPath)

            return hasModelFiles && hasTokenizer
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private func isParakeet(_ name: String) -> Bool {
        ParakeetModel(rawValue: name) != nil
    }

    private func unloadCurrentModel() {
        whisperKit = nil
        currentModelName = nil
    }

    private func modelPath(for variant: String) -> URL {
        let sanitizedVariant = variant
            .components(separatedBy: CharacterSet(charactersIn: "./\\"))
            .joined(separator: "_")

        return modelsBaseFolder
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent(sanitizedVariant, isDirectory: true)
    }

    private func tokenizerPath(for variant: String) -> URL {
        modelPath(for: variant).appendingPathComponent("tokenizer", isDirectory: true)
    }

    private func moveContents(of sourceFolder: URL, to destFolder: URL) throws {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(atPath: sourceFolder.path)
        for item in items {
            let src = sourceFolder.appendingPathComponent(item)
            let dst = destFolder.appendingPathComponent(item)
            try fm.moveItem(at: src, to: dst)
        }
    }

    private func candidateRoots() -> [URL] {
        let fm = FileManager.default
        let xdg = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"]
            .flatMap { URL(fileURLWithPath: $0, isDirectory: true) }
        let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let appCache = appSupport?.appendingPathComponent("com.kitlangton.Hex/cache", isDirectory: true)
        let userCache = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cache", isDirectory: true)
        return [xdg, appCache, appSupport, userCache].compactMap { $0 }
    }

    private func directoryContainsMLModelC(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return false }
        if let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in en {
                if url.pathExtension == "mlmodelc" || url.lastPathComponent.hasSuffix(".mlmodelc") {
                    return true
                }
            }
        }
        return false
    }

    private func directorySize(_ dir: URL) -> UInt64? {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        var total: UInt64 = 0
        for case let url as URL in en {
            if let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               vals.isRegularFile == true
            {
                total &+= UInt64(vals.fileSize ?? 0)
            }
        }
        return total
    }
}

// MARK: - Error Types

enum TranscriptionError: LocalizedError {
    case unsupportedModel(String)
    case modelNotLoaded
    case audioFileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedModel(let name):
            return "Unsupported model: \(name)"
        case .modelNotLoaded:
            return "Model failed to load"
        case .audioFileNotFound(let path):
            return "Audio file not found: \(path)"
        }
    }
}
