# hex-cli

On-device audio transcription and speaker diarization for macOS. Uses Apple Neural Engine via CoreML for fast inference.

## Backends

- **Parakeet** (FluidAudio) — TDT 0.6B, multilingual, default
- **WhisperKit** — OpenAI Whisper models via CoreML

## Install

```bash
brew tap fbehrens/tap
brew install hex-cli
```

Or build from source:

```bash
swift build -c release
# or
make install          # builds release + copies to /usr/local/bin
```

Requires Swift 6.0+, macOS 15+.

## Usage

```bash
# Plain text transcription
hex-cli recording.wav

# JSON output with word-level timestamps
hex-cli --json recording.wav

# JSON + speaker diarization
hex-cli --json --diarize recording.wav

# Specify model and language
hex-cli --model openai_whisper-large-v3 --language de interview.wav

# Show progress on stderr
hex-cli --progress long-meeting.m4a

# List available models
hex-cli --list-models
```

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--json` | `-j` | JSON output with word timestamps, confidence, metadata |
| `--diarize` | `-d` | Run speaker diarization (FluidAudio offline pipeline) |
| `--model <name>` | `-m` | Model selection (default: `parakeet-tdt-0.6b-v3-coreml`) |
| `--language <code>` | `-l` | Language code (`en`, `de`, `es`, ...). Auto-detect if omitted |
| `--progress` | `-p` | Print progress to stderr |
| `--list-models` | | List available models and download status |

## JSON output

```jsonc
{
  "text": "Hello world.",
  "words": [
    { "text": "Hello", "start": 0.48, "end": 0.80, "confidence": 0.98, "speaker": 0 },
    { "text": "world.", "start": 0.80, "end": 1.20, "confidence": 0.95, "speaker": 0 }
  ],
  "duration": 1.23,       // processing time in seconds
  "model": "parakeet-tdt-0.6b-v3-coreml",
  "timestamp": "2026-03-24T09:00:00Z"
}
```

`speaker` is `null` when `--diarize` is not used.

## Models

All models auto-download from HuggingFace on first use and cache to `~/Library/Application Support/`. CoreML compilation happens once on first load.

### Transcription — Parakeet TDT (default)

| Model ID | Params | Languages | Source |
|----------|--------|-----------|--------|
| `parakeet-tdt-0.6b-v3-coreml` (default) | 600M | 25 European | [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) |
| `parakeet-tdt-0.6b-v2-coreml` | 600M | English | [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) |

**Architecture:** Token Duration Transducer (TDT) — an extension of RNN-T that jointly predicts tokens and their durations, enabling accurate word-level timestamps without a separate alignment step. Originally from NVIDIA NeMo, converted to CoreML by FluidInference.

Four CoreML bundles per model:
- **Preprocessor** — Mel-spectrogram (16kHz mono → 128-bin mel features, 10ms hop)
- **Encoder** — 1024 hidden units, 8x subsampling from mel frames to encoder frames
- **Decoder** — 640 hidden units, predicts next token given previous
- **JointDecision** — Fuses encoder + decoder outputs, emits token + duration

Input: 16kHz mono Float32 WAV. Output: text + per-token timestamps + confidence.

~120-190x realtime on M-series (1 minute audio in ~0.5s).

### Transcription — WhisperKit (alternative)

| Model ID | Size | Languages | Source |
|----------|------|-----------|--------|
| `openai_whisper-large-v3` | ~3GB | 99 | [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) |
| `openai_whisper-large-v3-turbo` | ~1.6GB | 99 | same |

OpenAI Whisper models converted to CoreML by Argmax. Encoder-decoder transformer with cross-attention. Word-level timestamps via `--json` (DTW alignment on attention weights). Run `hex-cli --list-models` for the full list.

### Diarization — FluidAudio Offline Pipeline

Used when `--diarize` is passed. All models from [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml).

The pipeline runs four stages:

**1. Segmentation** — `Segmentation.mlmodelc`
- Pyannote powerset segmentation model (converted to CoreML)
- Processes 10-second sliding windows
- Outputs 589 frame-level log probabilities across 7 local speaker classes
- Detects speech activity and speaker change points

**2. Feature extraction** — `FBank.mlmodelc`
- Mel-filterbank frontend (128-bin)
- Feeds the embedding model

**3. Speaker embedding** — `Embedding.mlmodelc`
- WeSpeaker v2 architecture (converted to CoreML)
- Extracts 256-dimensional L2-normalized speaker embeddings per speech segment
- Batch size: 32 segments

**4. Clustering** — `PldaRho.mlmodelc` + `plda-parameters.json`
- PLDA (Probabilistic Linear Discriminant Analysis) projects 256-dim embeddings → 128-dim
- VBx clustering (Variational Bayes, from BUT Speech@FIT / Brno University of Technology)
- EM-based iterative refinement, warm-started from Agglomerative Hierarchical Clustering
- Automatically determines number of speakers

**Performance:** 17.7% DER on AMI dataset. ~141x realtime on M1.

## Testing

Uses [Swift Testing](https://developer.apple.com/documentation/testing) with E2E tests that exercise the real binary via `Process`.

```bash
swift test                    # run all non-smoke tests
HEX_SMOKE=1 swift test       # include transcription smoke tests (needs models downloaded)
```

### Test suites

**CLI argument handling** — validates the binary's interface without downloading models:

| Test | Verifies |
|------|----------|
| `--help` | Prints `USAGE` banner, exits 0 |
| `--version` | Prints semver (`x.y.z`), exits 0 |
| No arguments | Exits non-zero, stderr mentions missing audio file |
| Non-existent file | Exits non-zero, stderr says "not found" |
| Invalid model name | Exits non-zero on unknown model |
| `--json --help` | `--json` flag accepted by the parser |
| `--diarize --help` | `--diarize` flag accepted by the parser |

**Model listing** — requires network on first run to fetch the WhisperKit model catalog:

| Test | Verifies |
|------|----------|
| `--list-models` sections | Output contains "Parakeet" and "WhisperKit" headings + default model ID |
| `--list-models` default | Output contains "(default)" marker |

**Transcription smoke tests** — gated behind `HEX_SMOKE=1` (needs models cached locally):

| Test | Verifies |
|------|----------|
| Plain text | Transcribing `audio.wav` produces non-empty stdout |
| JSON output | `--json` output parses as JSON with `text`, `words`, `duration`, `model`, `timestamp` keys |

## Versioning

Single source of truth: `Sources/HexCLI/Version.swift`. Exposed via `hex-cli --version`.

To cut a release:

```bash
make tag VERSION=0.2.0        # bumps Version.swift, commits, creates git tag
git push origin main --tags   # triggers GitHub Actions release workflow
```

The release workflow builds an arm64 binary, creates a GitHub Release with the tarball + sha256, and auto-updates the Homebrew tap formula.

## Performance

On Apple Silicon (M-series), for 60s of audio:

| Mode | Time | Notes |
|------|------|-------|
| Transcribe only | ~2s | Parakeet on ANE |
| Transcribe + diarize | ~4s | + segmentation, embedding, VBx clustering |
| First run | ~20s | Includes model download + CoreML compilation |

Models cached after first download.
