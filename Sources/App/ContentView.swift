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

                Button(action: {}) {
                    HStack(spacing: 8) {
                        Image(systemName: buttonIcon)
                            .font(.system(size: 13, weight: .bold))
                        Text(statusLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.65))
                            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !isHoldingButton && (orbState == .idle || orbState == .success) {
                                isHoldingButton = true
                                startListening()
                            }
                        }
                        .onEnded { _ in
                            if isHoldingButton {
                                isHoldingButton = false
                                stopListeningAndExecute()
                            }
                        }
                )
                .padding(.bottom, 8)
            }
        }
        .frame(width: 250, height: 250)
    }

    private var buttonIcon: String {
        switch orbState {
        case .idle: return "mic.fill"
        case .listening: return "waveform"
        case .thinking: return "gearshape.2.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusLabel: String {
        switch orbState {
        case .idle: return "Hold to Speak"
        case .listening: return "Listening..."
        case .thinking: return "Jev Driving..."
        case .success: return "Done"
        case .error(let msg): return msg
        }
    }

    private func startListening() {
        orbState = .listening
        transcribedText = ""
        do {
            try recorder.startRecording()
        } catch {
            orbState = .error("Mic Error")
        }
    }

    private func stopListeningAndExecute() {
        guard let wavData = recorder.stopRecording() else {
            orbState = .idle
            return
        }

        orbState = .thinking

        Task {
            do {
                // Transcribe with local Metal Whisper
                let goal = try await whisper.transcribe(wavData: wavData)
                if goal.isEmpty {
                    await MainActor.run {
                        orbState = .idle
                    }
                    return
                }

                await MainActor.run {
                    self.transcribedText = goal
                }

                // Dispatch to Jev Ultrafast
                let success = try await dispatcher.dispatch(goal: goal)
                await MainActor.run {
                    if success {
                        orbState = .success
                        // Silent completion: quick pause then reset to idle
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
