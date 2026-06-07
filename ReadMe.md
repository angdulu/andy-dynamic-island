<p align="center">
  <img src=".github/assets/atoll-logo.png" alt="Andy logo" width="120">
</p>
<h1 align="center">Andy — AI Dictation Companion & DynamicIsland Workspace 🐶🤖</h1>

<p align="center">
  <a href="https://github.com/angdulu/andy-dynamic-island/stargazers">
    <img src="https://img.shields.io/github/stars/angdulu/andy-dynamic-island?style=social" alt="GitHub stars"/>
  </a>
  <a href="https://github.com/angdulu/andy-dynamic-island/releases">
    <img src="https://img.shields.io/github/downloads/angdulu/andy-dynamic-island/total?label=Downloads" alt="GitHub downloads"/>
  </a>
</p>

**Andy** (formerly Atoll-Andy) is an advanced, customized macOS desktop pet and productivity assistant that lives directly in your MacBook notch or Dynamic Island. 

While preserving native system insight telemetry and media widgets, this fork integrates an **on-device Speech-to-Text (STT) Whisper transcriber** and a **Metal-GPU accelerated local Llama-3/Qwen cleanup pipeline** to turn voice dictations into copy-ready text with zero cloud dependency.

---

## 🧠 Custom Architecture: Local AI Dictation Workspace

This fork introduces a **Dictation-Only Mode** and custom local daemon bindings designed to run private LLMs locally on macOS:

```mermaid
graph TD
    User(["User Voice"]) -->|"HotKey / Dictation Mode"| DM[Dictation Manager]
    DM -->|"Record Audio (.wav)"| WS[Local whisper-server Subprocess]
    WS -->|"Raw Transcript"| LM[Llama Manager]
    LM -->|"Start Process (--n-gpu-layers 99)"| LS[Local llama-server Subprocess]
    LS -->|"GPU Metal-Accelerated Inference"| Llama[Llama GGUF Model]
    Llama -->|"Formatted & Cleaned Text"| Clipboard[macOS System Clipboard]
```

### 1. The Speech-to-Text Daemon (`DictationManager.swift`)
- Integrates a precompiled **Whisper C/C++ server binary** (`whisper-server`) directly into the macOS application bundle.
- Manages recording state, playing custom sound cues (`whisper_begin.wav`, `whisper_end.wav`) to signify recording intervals.
- Handles audio capture and streams `.wav` buffers to the local Whisper daemon, returning a raw text transcript in real-time.

### 2. Apple Silicon Metal-Accelerated Post-Processing (`LlamaManager.swift`)
- Bundles a custom **llama-server** executable with matching dynamic libraries (`libllama`, `libggml-metal`, etc.) to run GGUF models locally.
- **Metal GPU Acceleration:** Starts the server subprocess with `--n-gpu-layers 99` and `--threads 4`, offloading model evaluation entirely to Apple Silicon Unified Memory for immediate, sub-second inference.
- **Prompt Injection Defense:** Wraps the transcription in XML tags (`<transcription>...</transcription>`) within the structured system prompt, preventing the AI from executing commands spoken in the dictation text.
- **Dynamic Model Fetching:** Features an asynchronous model downloader (`URLSessionDownloadTask`) that installs GGUF models directly to the macOS Application Support folder with SHA-256 integrity verification.
- **Output:** Automatically cleans up grammatical errors, false starts, and stuttering before copying the polished, publication-ready text directly to the system clipboard.

---

## 🌟 Highlights & Original Features

- **Local AI Transcription Cleanup:** Bundles a local `llama-server` process manager and HTTP completion client. Supports runtime model selections (Llama-3.2-1B, Qwen-2.5-0.5B/1.5B) to fix grammar, remove filler words, and clean transcription stutters completely offline.
- **Dictation-Only Mode:** A toggle that disables lock screen widgets, Dynamic Island panel hover behaviors, and sound effects, converting the app into a focused, background dictation daemon.
- **Notch Pet Emotions ("Grumpy Return"):** Features an opinionated, state-aware notch pet (`^._.^`) that reacts dynamically to macOS system events. When displaced from the notch by macOS media or microphone notifications, Andy returns with an annoyed/grumpy reaction animation.
- **Media Controls:** Dynamic widgets for Apple Music, Spotify, and system volume with inline previews.
- **System Insight:** Real-time displays for CPU, GPU, memory, network, and disk health metrics.
- **Productivity Panel:** Built-in timers, calendar widgets, clipboard history managers, and color pickers.

---

## 💻 Tech Stack

- **UI Framework:** SwiftUI 5 / AppKit
- **Core AI Runtimes:** Custom C++ wrappers for `llama.cpp` and `whisper.cpp`
- **Build Tooling:** Xcode 15+ / Swift Package Manager (SPM)

---

## 🔧 Subprocess Configuration Detail

To load the bundled `.dylib` library dependencies in macOS sandbox-compliant environments, `LlamaManager` modifies its subprocess launch environment:
```swift
var env = ProcessInfo.processInfo.environment
let binDir = serverBinary.deletingLastPathComponent().path
env["DYLD_LIBRARY_PATH"] = binDir
process.environment = env
```
This forces the macOS dynamic loader to locate `libggml-metal.dylib` and other key dependencies packaged inside the App bundle, allowing portable local inference without system-wide library installations.

---

## 📦 Requirements & Installation

- **OS:** macOS 14.0 or later (Optimized for Apple Silicon M1/M2/M3/M4 Macs).
- **Hardware:** MacBook with a notch (14/16-inch MBP).
- **Development Tooling:** Xcode 15+ (if compiling from source).

To run locally:
1. Clone the repository:
   ```bash
   git clone https://github.com/angdulu/andy-dynamic-island.git
   ```
2. Open `DynamicIsland.xcodeproj` in Xcode.
3. Build and run (requires granting Accessibility and Audio Recording permissions).

---

## 📜 Acknowledgments & License

This project is released under the **GPL v3 License**.

It builds upon the work of several exceptional open-source projects:
- [**Boring.Notch**](https://github.com/TheBoredTeam/boring.notch) - Foundation for media integration and notches.
- [**Alcove**](https://tryalcove.com) - Inspiration for widget layout.
- [**Stats**](https://github.com/exelban/stats) - SMC CPU reading architecture.
- [**llama.cpp**](https://github.com/ggerganov/llama.cpp) & [**whisper.cpp**](https://github.com/ggerganov/whisper.cpp) - Core AI engines.
