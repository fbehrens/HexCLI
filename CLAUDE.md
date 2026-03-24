# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

HexCLI (`hex-cli`) is a macOS CLI tool for audio transcription using two backends: **Parakeet** (FluidAudio) and **WhisperKit** (OpenAI Whisper). Swift 6.0+, macOS 15+, Swift Package Manager.

## Build & Run

```bash
cd cmd/HexCLI && swift build                          # debug build
swift build -c release               # release build
swift run hex-cli <audio-file>       # run with default model
swift run hex-cli --model <name> <audio-file>
swift run hex-cli --list-models      # show available models
swift run hex-cli --json <file>      # JSON output


cmd/HexCLI/.build/arm64-apple-macosx/release/hex-cli --list-models
cmd/HexCLI/.build/arm64-apple-macosx/release/hex-cli --help
cmd/HexCLI/.build/arm64-apple-macosx/release/hex-cli data/fixtures/audio.wav # text
cmd/HexCLI/.build/arm64-apple-macosx/release/hex-cli --json data/fixtures/audio.wav # 1.5s
cmd/HexCLI/.build/arm64-apple-macosx/release/hex-cli --json data/cache/de3ce4c4a576a3b8/audio.wav # 27s
cmd/HexCLI/.build/arm64-apple-macosx/release/hex-cli --json --diarize data/cache/de3ce4c4a576a3b8/audio.wav # 27s
cmd/HexCLI/.build/arm64-apple-macosx/release/hex-cli --model openai_whisper-large-v3_turbo_954MB --json data/fixtures/audio.wav



```

No test target exists yet.

## Architecture

Four source files in `Sources/HexCLI/`:

- **HexCLI.swift** — Entry point. `AsyncParsableCommand` handling CLI args, user interaction, orchestration.
- **TranscriptionEngine.swift** — `actor` managing model loading, caching, and transcription dispatch to Parakeet or WhisperKit backends.
- **AudioPreparer.swift** — `enum` with static methods for audio preprocessing (PCM conversion, padding short clips <1.5s for Parakeet).
- **ParakeetModel.swift** — `enum` registry of Parakeet model variants.

### Key patterns

- Swift concurrency throughout (async/await, actor isolation, `@Sendable` closures)
- Models cached in `~/Library/Application Support/com.kitlangton.Hex/models/` (respects `XDG_CACHE_HOME`)
- Parakeet models use FluidAudio; WhisperKit models use WhisperKit framework
- Audio padding creates temp files cleaned up via `defer`

### Dependencies

- `swift-argument-parser` — CLI parsing
- `WhisperKit` (main branch) — Whisper transcription backend
- `FluidAudio` (main branch) — Parakeet ASR backend
- `swift-transformers` — ML tokenizers
