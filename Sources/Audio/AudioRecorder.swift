// @acid: AUDIO-1, AUDIO-2, AUDIO-3, AUDIO-4
import Foundation
import AVFoundation

public final class AudioRecorder: ObservableObject {
    @Published public var audioLevel: Float = 0.0
    @Published public var isRecording: Bool = false

    private let engine = AVAudioEngine()
    private var recordedData = Data()
    private var inputFormat: AVAudioFormat?
    private let targetSampleRate: Double = 16000.0

    public init() {}

    public func startRecording() throws {
        recordedData.removeAll()
        audioLevel = 0.0

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        self.inputFormat = nativeFormat

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.processAudioBuffer(buffer)
        }

        try engine.start()
        DispatchQueue.main.async {
            self.isRecording = true
        }
    }

    public func stopRecording() -> Data? {
        guard isRecording else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
        }

        guard let format = inputFormat, !recordedData.isEmpty else { return nil }
        return convertTo16kHzWav(rawData: recordedData, sourceFormat: format)
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)

        // Calculate RMS power for visual level metering
        var sum: Float = 0.0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(max(frameLength, 1)))
        let normalizedLevel = min(max((rms - 0.01) * 6.0, 0.0), 1.0)

        DispatchQueue.main.async {
            self.audioLevel = normalizedLevel
        }

        // Append raw float bytes
        let bytes = Data(bytes: channelData, count: frameLength * MemoryLayout<Float>.size)
        recordedData.append(bytes)
    }

    private func convertTo16kHzWav(rawData: Data, sourceFormat: AVAudioFormat) -> Data? {
        let frameCount = rawData.count / MemoryLayout<Float>.size
        let floatSamples = rawData.withUnsafeBytes { ptr in
            Array(ptr.bindMemory(to: Float.self))
        }

        // Downsample / resample to 16000 Hz mono PCM16
        let sourceRate = sourceFormat.sampleRate
        let ratio = sourceRate / targetSampleRate
        let targetFrameCount = Int(Double(frameCount) / ratio)
        var pcm16Samples = [Int16]()
        pcm16Samples.reserveCapacity(targetFrameCount)

        for i in 0..<targetFrameCount {
            let srcIndex = Int(Double(i) * ratio)
            if srcIndex < floatSamples.count {
                let clamped = max(-1.0, min(1.0, floatSamples[srcIndex]))
                let int16Val = Int16(clamped * 32767.0)
                pcm16Samples.append(int16Val)
            }
        }

        return createWavHeaderAndData(samples: pcm16Samples, sampleRate: 16000)
    }

    private func createWavHeaderAndData(samples: [Int16], sampleRate: Int32) -> Data {
        var data = Data()
        let numSamples = Int32(samples.count)
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = sampleRate * Int32(numChannels * bitsPerSample / 8)
        let blockAlign = Int16(numChannels * bitsPerSample / 8)
        let subchunk2Size = numSamples * Int32(numChannels * bitsPerSample / 8)
        let chunkSize = 36 + subchunk2Size

        // RIFF Header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        data.append(contentsOf: "fmt ".utf8)
        let subchunk1Size: Int32 = 16
        let audioFormat: Int16 = 1 // PCM
        data.append(contentsOf: withUnsafeBytes(of: subchunk1Size.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // data subchunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: subchunk2Size.littleEndian) { Data($0) })
        
        // Samples
        samples.withUnsafeBytes { ptr in
            data.append(contentsOf: ptr)
        }

        return data
    }
}
