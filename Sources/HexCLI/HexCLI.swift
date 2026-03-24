//
//  HexCLI.swift
//  HexCLI
//
//  Command-line tool for audio file transcription using WhisperKit and Parakeet backends.
//

import ArgumentParser
import Foundation

@main
struct HexCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hex-cli",
        abstract: "Transcribe audio files using on-device ML models",
        discussion: """
            Hex CLI transcribes audio files using the same WhisperKit and Parakeet backends
            as the Hex macOS app. Models are downloaded automatically on first use and
            cached for subsequent transcriptions.

            Examples:
              hex-cli recording.wav
              hex-cli --model openai_whisper-large-v3 interview.mp3
              hex-cli --progress long-meeting.m4a
              hex-cli --json recording.wav
            """,
        version: hexCLIVersion
    )

    @Argument(help: "Path to the audio file to transcribe")
    var audioFile: String?

    @Option(name: .shortAndLong, help: "Model to use for transcription (default: parakeet-tdt-0.6b-v3-coreml)")
    var model: String = ParakeetModel.multilingualV3.identifier

    @Option(name: .shortAndLong, help: "Target language code (e.g., 'en', 'es'). Auto-detect if not specified.")
    var language: String?

    @Flag(name: .shortAndLong, help: "Show download and transcription progress on stderr")
    var progress: Bool = false

    @Flag(name: .shortAndLong, help: "Output JSON with metadata instead of plain text")
    var json: Bool = false

    @Flag(name: .shortAndLong, help: "Run speaker diarization and include speaker IDs in output")
    var diarize: Bool = false

    @Flag(name: .long, help: "List available models and exit")
    var listModels: Bool = false

    mutating func run() async throws {
        if listModels {
            try await printAvailableModels()
            return
        }

        guard let audioFile else {
            throw ValidationError("Missing required argument '<audio-file>'")
        }

        let fileURL = URL(fileURLWithPath: audioFile)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("Audio file not found: \(audioFile)")
        }

        let engine = TranscriptionEngine()
        let startTime = Date()

        let progressHandler: (@Sendable (Progress) -> Void)?
        if progress {
            progressHandler = { p in
                let percent = Int(p.fractionCompleted * 100)
                FileHandle.standardError.write(Data("\rProgress: \(percent)%".utf8))
            }
        } else {
            progressHandler = nil
        }

        let result = try await engine.transcribe(
            url: fileURL,
            model: model,
            language: language,
            progressCallback: progressHandler
        )

        // Run diarization if requested
        var diarSegments: [DiarSpeakerSegment] = []
        if diarize {
            diarSegments = try await engine.diarize(url: fileURL)
        }

        if progress {
            // Clear progress line
            FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
        }

        let duration = Date().timeIntervalSince(startTime)

        // Assign speakers to words if diarization was run
        let words: [DetailedWord]
        if diarSegments.isEmpty {
            words = result.words
        } else {
            words = assignSpeakers(diarSegments: diarSegments, words: result.words)
        }

        if json {
            let output = TranscriptionOutput(
                text: result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                words: words,
                duration: duration,
                model: model,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(output)
            print(String(data: jsonData, encoding: .utf8)!)
        } else {
            print(result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
        }
    }

    private func printAvailableModels() async throws {
        let engine = TranscriptionEngine()
        let models = try await engine.getAvailableModels()

        print("Available models:\n")
        print("Parakeet (FluidAudio):")
        for parakeetModel in ParakeetModel.allCases {
            let downloaded = await engine.isModelDownloaded(parakeetModel.identifier)
            let status = downloaded ? "[downloaded]" : ""
            let label = parakeetModel == .multilingualV3 ? " (default)" : ""
            print("  - \(parakeetModel.identifier)\(label) \(status)")
        }

        print("\nWhisperKit:")
        for model in models where !model.hasPrefix("parakeet") {
            let downloaded = await engine.isModelDownloaded(model)
            let status = downloaded ? "[downloaded]" : ""
            print("  - \(model) \(status)")
        }
    }
}

// MARK: - Result Types

struct DetailedWord: Encodable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double
    let speaker: Int?
}

struct DetailedTranscription {
    let text: String
    let words: [DetailedWord]
}

struct DiarSpeakerSegment {
    let speaker: String
    let start: Float
    let end: Float
}

struct TranscriptionOutput: Encodable {
    let text: String
    let words: [DetailedWord]
    let duration: Double
    let model: String
    let timestamp: String
}

// MARK: - Speaker Assignment (sweep-line)

/// Assigns speaker IDs to words using binary search + scan over sorted diarization segments.
private func assignSpeakers(diarSegments: [DiarSpeakerSegment], words: [DetailedWord]) -> [DetailedWord] {
    guard !diarSegments.isEmpty else { return words }

    let sorted = diarSegments.sorted { $0.start < $1.start }
    let starts = sorted.map { $0.start }
    let ends = sorted.map { $0.end }
    let speakers = sorted.map { $0.speaker }

    func bisectLeft(_ arr: [Float], _ val: Float) -> Int {
        var lo = 0, hi = arr.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if arr[mid] < val { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func bestSpeaker(start: Float, end: Float) -> String? {
        let right = bisectLeft(starts, end)
        guard right > 0 else { return nil }
        var best: String?
        var bestOverlap: Float = 0
        for i in stride(from: right - 1, through: 0, by: -1) {
            if ends[i] <= start { continue }
            let overlap = min(ends[i], end) - max(starts[i], start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                best = speakers[i]
            }
        }
        return best
    }

    func parseSpeakerId(_ s: String) -> Int {
        // Extract trailing digits from e.g. "1" or "SPEAKER_01"
        if let n = Int(s) { return n }
        guard let match = s.range(of: #"\d+$"#, options: .regularExpression) else { return 0 }
        return Int(s[match]) ?? 0
    }

    return words.map { w in
        let sp = bestSpeaker(start: Float(w.start), end: Float(w.end))
        return DetailedWord(
            text: w.text,
            start: w.start,
            end: w.end,
            confidence: w.confidence,
            speaker: sp.map { parseSpeakerId($0) }
        )
    }
}
