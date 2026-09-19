# JevOrb 🔮

A lightweight, native macOS push-to-talk floating voice orb that interprets arbitrary spoken commands at runtime and operates applications through **macOS Accessibility (AX)**, using **Jev** and local **Metal Whisper** speech-to-text.

Built with **pure SwiftUI** and **AppKit**, isolating all OS-level permissions into a standalone application (`JevOrb.app`).

---

## Features

- **Push-to-Talk Siri Orb:** Powered by a pure SwiftUI port of [`metasidd/Orb`](https://github.com/metasidd/Orb). Fluid wavy blobs, rotating depth glows, and floating particles.
- **Audio-Reactive Metering:** The orb expands and intensifies in real-time based on your microphone's live RMS volume.
- **Local Metal Whisper STT:** Transcribes speech in ~300ms using local GPU-accelerated Metal Whisper (`whispercpp-metal`).
- **Generic Semantic Navigation:** Works with native applications and browser content exposed through the same semantic accessibility trees used by VoiceOver. Applications, websites, labels, and workflows are not hard-coded.
- **Silent Dismissal:** No voice speech or TTS chatter on completion—pulses emerald green upon finishing and quietly resets.
- **Permission Isolation:** macOS Accessibility and Microphone permissions belong to `JevOrb.app`, not the invoking terminal. Screen Recording permission is not required.
- **AX-Only Control:** Observes accessible roles, labels, values, relationships, and supported actions—not screenshots, OCR, YOLO, or screen coordinates. No CDP, browser extensions, or browser automation harness is used.

---

## Architecture & Acai ACID Spec

The execution contract is defined in `features/jev-orb.feature.yaml`. The runtime retains the SwiftUI orb, local audio capture, Whisper transcription, and asynchronous `JevDispatcher` boundary:

| Component | Responsibility |
|---|---|
| **Overlay and orb** | A transparent, nonactivating `NSPanel` with listening, thinking, success, and error feedback that does not steal the user's application focus while recording. |
| **AudioRecorder** | Local microphone capture, live RMS metering, and 16 kHz WAV encoding. |
| **WhisperClient** | Local speech transcription through the configured Whisper endpoint. |
| **Application catalog** | Running and installed application discovery through public macOS APIs; application and window selection rather than browser-only targeting. |
| **AX session** | Semantic tree observation, generation-scoped element references, and validation of application, window, element identity, and supported actions. |
| **JevDispatcher** | Interprets the goal, selects a semantic operation, executes it, and re-observes the resulting AX state before continuing or reporting completion. |

Accessibility observation and execution stay inside `JevOrb.app`; they are not delegated to a separately permissioned shell or Python process. Application launching and switching use AppKit/Workspace APIs. Keyboard input is permitted only after AX-based target selection and immediate focus validation; it is not a coordinate or visual fallback.

### Supported scope and boundaries

Arbitrary commands can span one or more applications, provided the required controls, content, and completion state are exposed through macOS Accessibility. Browser support depends on the browser exposing page content as AX nodes; it does not rely on DOM access through a debugging protocol. VoiceOver does not need to be enabled.

- Missing Accessibility permission, unavailable windows, inaccessible content, ambiguous or stale targets, and unsupported actions are blockers—not reasons to guess a target.
- Pixel-only canvases, unlabeled controls without sufficient semantic context, and content absent from the AX tree cannot be reliably operated. There is no screenshot, OCR, image-matching, or coordinate fallback.
- Login, MFA, consent, permission, and anti-automation barriers are not bypassed. Resolve the blocker yourself before issuing a new command.
- A research request does not authorize a purchase, booking, message, or other unrelated external side effect.
- Completion requires observable semantic evidence. Unverified effects must not be presented as success, and potentially non-idempotent actions must not be automatically replayed after uncertain delivery.

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

When opened for the first time, grant **Microphone** permission to `JevOrb.app` for speech capture and **Accessibility** permission in **System Settings → Privacy & Security → Accessibility** for semantic navigation. Do not grant these permissions to your terminal on JevOrb's behalf. **Screen Recording is not required.** If access is missing or denied, navigation is blocked rather than falling back to visual control.

### 3. Usage

1. Hold the **Hold to Speak** pill on the floating orb.
2. Speak your command naturally. Name an application when you want to switch targets; otherwise the current application supplies the initial context.
3. Release the button.
4. The orb enters its thinking state while Whisper transcribes locally and Jev navigates using accessible controls and semantic state.
5. The orb turns green on successful completion and returns to idle. If execution is blocked or fails, it shows error feedback instead; inspect `/tmp/jevorb.log` for the reported reason before trying again.

---

## License

MIT
