import AVFoundation
import Accelerate
import CoreAudio
import Speech

/// Resamples any incoming PCM buffer into the format the speech model wants, keeping
/// resampler state between buffers so streaming audio stays seamless.
final class StreamConverter {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?

    init(output: AVAudioFormat) { self.output = output }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == output { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: output)
            converter?.primeMethod = .none
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { Log.write("convert error: \(error.localizedDescription)"); return nil }
        return out.frameLength > 0 ? out : nil
    }
}

/// Microphone capture. The engine is prepared at launch so pressing the hotkey starts
/// streaming in a few milliseconds. Audio goes straight into the speech analyzer as it arrives.
final class Mic {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: StreamConverter?
    private(set) var isRunning = false
    var onLevel: ((Float) -> Void)?

    /// Warms up the audio engine. Touching `inputNode` before the user has answered the
    /// microphone prompt blocks the calling thread, so only do it once access is granted.
    func prepare() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        _ = engine.inputNode
        engine.prepare()
    }

    private var deviceUID = ""

    /// Picks the microphone. Empty means the system default.
    func select(deviceUID uid: String) {
        guard uid != deviceUID, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        deviceUID = uid
        let id = uid.isEmpty ? Self.systemDefaultInput() : AudioDevices.deviceID(forUID: uid)
        guard let id else { return }
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(id)
        } catch {
            Log.write("mic select failed: \(error.localizedDescription)")
        }
        engine.prepare()
    }

    private static func systemDefaultInput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    func start(format: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "Lipi", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone available"])
        }
        if converter?.output != format { converter = StreamConverter(output: format) }
        let converter = self.converter!
        input.removeTap(onBus: 0)
        // ~43 ms buffers at 48 kHz keep the live transcript responsive.
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.reportLevel(buffer)
            if let converted = converter.convert(buffer) {
                self.continuation?.yield(AnalyzerInput(buffer: converted))
            }
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        return stream
    }

    func stop() {
        guard isRunning || continuation != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        continuation?.finish()
        continuation = nil
        isRunning = false
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let onLevel, let data = buffer.floatChannelData else { return }
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(buffer.frameLength))
        let db = 20 * log10(max(rms, 1e-6))
        let level = min(max((db + 55) / 45, 0), 1)
        DispatchQueue.main.async { onLevel(level) }
    }
}
