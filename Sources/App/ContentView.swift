// @acid: ORB-2, ORB-3, ORB-4, ORB-5, ORB-6, HOTKEY-2, HOTKEY-3, HOTKEY-4, UX-1, UX-2
import SwiftUI

public enum OrbState: Equatable {
    case idle
    case listening
    case thinking
    case success
    case error(String)
}

public struct ContentView: View {
    @StateObject private var recorder = AudioRecorder()
    @State private var orbState: OrbState = .idle
    @State private var transcribedText: String = ""
    @State private var isHoldingButton: Bool = false

    private let whisper = WhisperClient()
    private let dispatcher = JevDispatcher.shared

    public init() {}

    private var activeConfig: OrbConfiguration {
        switch orbState {
        case .idle:
            return .idle
        case .listening:
            var config = OrbConfiguration.listening
            // Dynamically scale core glow and speed from live microphone RMS audio level
            let level = Double(recorder.audioLevel)
            config.coreGlowIntensity = 1.0 + (level * 2.2)
            config.speed = 45.0 + (level * 90.0)
            return config
        case .thinking:
            return .thinking
        case .success:
            return .success
        case .error:
            return OrbConfiguration(
                backgroundColors: [.red, .orange, .pink],
                glowColor: .red,
                coreGlowIntensity: 1.5,
                speed: 40
            )
        }
    }

    public var body: some View {
        ZStack {
            // Animated Glowing Siri Orb
            OrbView(configuration: activeConfig)
                .frame(width: 170, height: 170)
                .scaleEffect(orbState == .listening ? 1.08 : (orbState == .thinking ? 1.0 : 0.95))
                .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.65), value: recorder.audioLevel)
                .animation(.easeInOut(duration: 0.4), value: orbState)

            // Hold-to-Talk Interactive Trigger Overlay
            VStack {
                Spacer()

                Button(action: {
                    toggleListening()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: buttonIcon)
                            .font(.system(size: 13, weight: .bold))
                        Text(statusLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.75))
                            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 250, height: 250)
    }

    private var buttonIcon: String {
        switch orbState {
        case .idle: return "mic.fill"
        case .listening: return "waveform.circle.fill"
        case .thinking: return "gearshape.2.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusLabel: String {
        switch orbState {
        case .idle:
            return "Click or Hold to Speak"
        case .listening:
            return "Listening... (Click to Stop)"
        case .thinking:
            if transcribedText.isEmpty {
                return "Transcribing voice..."
            } else {
                return "Jev: \(transcribedText)"
            }
        case .success:
            return "Done!"
        case .error(let msg):
            return msg
        }
    }

    private func toggleListening() {
        if orbState == .listening {
            stopListeningAndExecute()
        } else if orbState == .idle || orbState == .success {
            startListening()
        }
    }

    private func startListening() {
        orbState = .listening
        transcribedText = ""
        logMessage("Started listening on microphone...")
        do {
            try recorder.startRecording()
        } catch {
            logMessage("Microphone recording error: \(error)")
            orbState = .error("Mic Error")
        }
    }
    private func logMessage(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        let logPath = "/tmp/jevorb.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        }
    }

    private func stopListeningAndExecute() {
        logMessage("Stop listening called. Finalizing audio...")
        guard let wavData = recorder.stopRecording() else {
            logMessage("No audio data captured.")
            orbState = .idle
            return
        }

        logMessage("Captured WAV audio: \(wavData.count) bytes. Sending to Whisper...")
        orbState = .thinking

        Task {
            do {
                try? wavData.write(to: URL(fileURLWithPath: "/tmp/last_recorded.wav"))
                let goal = try await whisper.transcribe(wavData: wavData)
                logMessage("Whisper transcribed goal: \"\(goal)\"")
                if goal.isEmpty {
                    logMessage("Goal is empty, reporting No speech heard.")
                    await MainActor.run {
                        orbState = .error("No speech heard")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            orbState = .idle
                        }
                    }
                    return
                }

                await MainActor.run {
                    self.transcribedText = goal
                }

                logMessage("Dispatching goal through macOS Accessibility: \"\(goal)\"...")
                let success = try await dispatcher.dispatch(goal: goal)
                logMessage("Jev execution returned success=\(success)")
                await MainActor.run {
                    if success {
                        orbState = .success
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            orbState = .idle
                        }
                    } else {
                        orbState = .error("Jev Stopped")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            orbState = .idle
                        }
                    }
                }
            } catch {
                logMessage("Error in whisper or dispatch: \(error.localizedDescription)")
                await MainActor.run {
                    orbState = .error("Error")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        orbState = .idle
                    }
                }
            }
        }
    }
}
