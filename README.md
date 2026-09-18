# JevOrb 🔮

A lightweight, native macOS push-to-talk floating voice orb that drives your web browser autonomously using **Jev Ultrafast** and local **Metal Whisper** speech-to-text.

Built with **pure SwiftUI** and **AppKit**, isolating all OS-level permissions into a standalone application (`JevOrb.app`).

---

## Features

- **Push-to-Talk Siri Orb:** Powered by a pure SwiftUI port of [`metasidd/Orb`](https://github.com/metasidd/Orb). Fluid wavy blobs, rotating depth glows, and floating particles.
- **Audio-Reactive Metering:** The orb expands and intensifies in real-time based on your microphone's live RMS volume.
- **Local Metal Whisper STT:** Transcribes speech in ~300ms using local GPU-accelerated Metal Whisper (`whispercpp-metal`).
- **Autonomous Browser Automation:** Dispatches your goal to `jev-ultrafast` (`typesafe/jev-1.13` + `openai/gpt-oss-120b:nitro` via OpenRouter).
- **Silent Dismissal:** No voice speech or TTS chatter on completion—pulses emerald green upon finishing and quietly resets.
- **Permission Isolation:** Solves the terminal privilege issue. macOS Accessibility, Screen Recording, and Microphone permissions belong strictly to `JevOrb.app`, leaving Ghostty and your shell completely unprivileged.

---

## Architecture & Acai ACID Spec

This project is built following the **Acai.sh ACID Specification** in `features/jev-orb.feature.yaml`. All components are tagged with `@acid:` references for full auditability:

| Component | ACIDs | Description |
|---|---|---|
| **OVERLAY** | `OVERLAY-1..5` | Floating, transparent, non-activating `NSPanel` that never steals browser focus. |
| **ORB** | `ORB-1..6` | Multi-layer animated orb with `IDLE`, `LISTENING`, `THINKING`, and `SUCCESS` states. |
| **HOTKEY** | `HOTKEY-1..4` | Push-to-talk press-and-hold trigger. |
| **AUDIO** | `AUDIO-1..4` | Real-time `AVAudioEngine` tap with RMS power calculation and 16kHz WAV encoding. |
| **WHISPER** | `WHISPER-1..4` | Local Metal Whisper integration (`http://127.0.0.1:49868/inference`). |
| **DISPATCH** | `DISPATCH-1..4` | Autonomous execution pipeline targeting your active browser. |
| **UX** | `UX-1..3` | Silent completion, sub-50ms visual transition, permission isolation. |

---

## Quick Start

### 1. Build and Install

```bash
cd ~/Developer/jev-orb
./scripts/build_app.sh
```

The application is installed to `~/Applications/JevOrb.app`.

### 2. Launch

```bash
open ~/Applications/JevOrb.app
```

When opened for the first time, grant the requested **Microphone** and **Accessibility** permissions to `JevOrb.app`.

### 3. Usage

1. Hold the **Hold to Speak** pill on the floating orb.
2. Speak your command naturally (e.g., *"Search Google for Wikipedia and find the article on Quantum Computing"*).
3. Release the button.
4. The orb enters a cosmic swirl while Jev drives your browser.
5. The orb turns green when done and silently dismisses.

---

## License

MIT
