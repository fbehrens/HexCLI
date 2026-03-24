//
//  HexCLITests.swift
//  HexCLI
//
//  End-to-end tests for the hex-cli binary using Swift Testing.
//

import Foundation
import Testing

// MARK: - Helpers

/// Locates the built `hex-cli` binary in the SPM build directory.
private func binaryURL() throws -> URL {
    // Walk up from the Package.swift directory to find .build/debug/hex-cli
    // or use the build artifacts path that `swift test` places products in.
    let fm = FileManager.default

    // Strategy 1: Look relative to the test bundle's #file location
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // HexCLITests/
        .deletingLastPathComponent() // Tests/
        .deletingLastPathComponent() // package root

    let debugCandidate = packageRoot
        .appendingPathComponent(".build/debug/hex-cli")
    if fm.fileExists(atPath: debugCandidate.path) {
        return debugCandidate
    }

    // Strategy 2: Check arm64 path
    let archCandidate = packageRoot
        .appendingPathComponent(".build/arm64-apple-macosx/debug/hex-cli")
    if fm.fileExists(atPath: archCandidate.path) {
        return archCandidate
    }

    // Strategy 3: Fall back to process arguments
    let testBinary = URL(fileURLWithPath: ProcessInfo.processInfo.arguments.first!)
    let buildDir = testBinary.deletingLastPathComponent()
    let candidate = buildDir.appendingPathComponent("hex-cli")
    if fm.fileExists(atPath: candidate.path) {
        return candidate
    }

    throw RunError(
        "hex-cli binary not found. Searched:\n  \(debugCandidate.path)\n  \(archCandidate.path)\n  \(candidate.path)\nRun `swift build` first."
    )
}

private struct RunError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

private struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Runs `hex-cli` with the given arguments and returns stdout, stderr, and exit code.
private func run(_ arguments: [String] = [], timeout: TimeInterval = 30) throws -> CLIResult {
    let binary = try binaryURL()
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()

    // Read output before waiting to avoid deadlocks on large output
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    process.waitUntilExit()

    return CLIResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? ""
    )
}

private func fixtureURL(_ name: String) -> URL {
    Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        ?? URL(fileURLWithPath: "Tests/HexCLITests/Fixtures/\(name)")
}

// MARK: - Tests

@Suite("CLI argument handling")
struct CLIArgumentTests {

    @Test("--help prints usage and exits 0")
    func help() throws {
        let result = try run(["--help"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("USAGE"))
        #expect(result.stdout.contains("hex-cli"))
    }

    @Test("--version prints semver and exits 0")
    func version() throws {
        let result = try run(["--version"])
        #expect(result.exitCode == 0)
        // Should match semver pattern like 0.1.0
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
                "Expected semver, got: \(trimmed)")
    }

    @Test("No arguments prints error about missing audio file")
    func noArguments() throws {
        let result = try run([])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("audio") || result.stderr.contains("Missing"))
    }

    @Test("Non-existent file prints error")
    func missingFile() throws {
        let result = try run(["/tmp/hex-cli-does-not-exist.wav"])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("not found") || result.stderr.contains("Error"))
    }

    @Test("Invalid model name fails gracefully")
    func invalidModel() throws {
        let fixture = fixtureURL("audio.wav")
        let result = try run(["--model", "totally-fake-model", fixture.path])
        #expect(result.exitCode != 0)
    }

    @Test("--json flag is accepted alongside --help")
    func jsonFlagHelp() throws {
        let result = try run(["--json", "--help"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("USAGE"))
    }

    @Test("--diarize flag is accepted alongside --help")
    func diarizeFlagHelp() throws {
        let result = try run(["--diarize", "--help"])
        #expect(result.exitCode == 0)
    }
}

@Suite("Model listing")
struct ModelListTests {

    @Test("--list-models prints Parakeet and WhisperKit sections")
    func listModels() throws {
        let result = try run(["--list-models"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("Parakeet"))
        #expect(result.stdout.contains("WhisperKit"))
        #expect(result.stdout.contains("parakeet-tdt-0.6b-v3-coreml"))
    }

    @Test("--list-models includes default marker")
    func listModelsDefault() throws {
        let result = try run(["--list-models"])
        #expect(result.stdout.contains("(default)"))
    }
}

@Suite("Transcription smoke tests", .enabled(if: ProcessInfo.processInfo.environment["HEX_SMOKE"] != nil))
struct TranscriptionSmokeTests {

    @Test("Plain text transcription produces output")
    func plainText() throws {
        let fixture = fixtureURL("audio.wav")
        let result = try run([fixture.path])
        #expect(result.exitCode == 0)
        #expect(!result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("JSON transcription produces valid JSON with expected keys")
    func jsonOutput() throws {
        let fixture = fixtureURL("audio.wav")
        let result = try run(["--json", fixture.path])
        #expect(result.exitCode == 0)

        let data = Data(result.stdout.utf8)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        #expect(json?["text"] is String)
        #expect(json?["words"] is [[String: Any]])
        #expect(json?["duration"] is Double)
        #expect(json?["model"] is String)
        #expect(json?["timestamp"] is String)
    }
}
