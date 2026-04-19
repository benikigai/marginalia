import Foundation
import AVFoundation

/// Captures iPhone mic audio as 16kHz 16-bit mono PCM.
/// Feeds chunks to a callback for streaming STT.
@MainActor
class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var audioLevel: Float = 0

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    /// Called on a background thread with PCM data chunks (~100ms each)
    var onAudioChunk: ((Data) -> Void)?

    /// Accumulated PCM buffer for the current utterance
    private var accumulatedPCM = Data()
    private let lock = NSLock()

    func startRecording() {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("[AudioRecorder] Session setup failed: \(error)")
            return
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)

        // Target format: 16kHz mono Float32 (we'll convert to Int16 PCM)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 16000,
                                                channels: 1,
                                                interleaved: false) else {
            print("[AudioRecorder] Cannot create target format")
            return
        }

        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            print("[AudioRecorder] Cannot create converter from \(hwFormat) to \(targetFormat)")
            return
        }

        // Install tap — get hardware-rate audio, convert to 16kHz
        let bufferSize: AVAudioFrameCount = 4096
        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Convert to 16kHz mono
            let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / hwFormat.sampleRate)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil else { return }

            // Convert Float32 → Int16 PCM
            guard let floatData = convertedBuffer.floatChannelData?[0] else { return }
            let count = Int(convertedBuffer.frameLength)
            var pcmData = Data(count: count * 2)
            pcmData.withUnsafeMutableBytes { ptr in
                let int16Ptr = ptr.bindMemory(to: Int16.self)
                for i in 0..<count {
                    let sample = max(-1.0, min(1.0, floatData[i]))
                    int16Ptr[i] = Int16(sample * 32767)
                }
            }

            // Update audio level for UI
            let rms = sqrt(pcmData.withUnsafeBytes { ptr -> Float in
                let samples = ptr.bindMemory(to: Int16.self)
                var sum: Float = 0
                for i in 0..<min(count, 160) {
                    let f = Float(samples[i]) / 32767.0
                    sum += f * f
                }
                return sum / Float(min(count, 160))
            })

            self.lock.lock()
            self.accumulatedPCM.append(pcmData)
            self.lock.unlock()

            // Send chunk callback
            self.onAudioChunk?(pcmData)

            Task { @MainActor in
                self.audioLevel = rms
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            inputNode = input
            isRecording = true
            accumulatedPCM = Data()
            print("[AudioRecorder] Started recording at \(hwFormat.sampleRate)Hz → 16kHz")
        } catch {
            print("[AudioRecorder] Engine start failed: \(error)")
        }
    }

    func stopRecording() {
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        isRecording = false
        audioLevel = 0
        print("[AudioRecorder] Stopped")
    }

    /// Get all accumulated PCM data since recording started (or last drain).
    func drainAccumulatedPCM() -> Data {
        lock.lock()
        let data = accumulatedPCM
        accumulatedPCM = Data()
        lock.unlock()
        return data
    }

    /// Get accumulated PCM without clearing it.
    func peekAccumulatedPCM() -> Data {
        lock.lock()
        let data = accumulatedPCM
        lock.unlock()
        return data
    }
}
