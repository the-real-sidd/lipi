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

/// Opens exactly one input device through Core Audio's HAL unit, never the system default.
/// (Creating an AVAudioEngine touches the default input, which flips Bluetooth headphones
/// into low-quality call mode even if you then switch to another mic.)
final class HALInput {
    private var unit: AudioUnit?
    private(set) var format: AVAudioFormat
    let device: AudioDeviceID
    private var buffer: AVAudioPCMBuffer
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var isRunning = false

    init(device: AudioDeviceID) throws {
        self.device = device
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw Self.error("no HAL unit") }
        var instance: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &instance), "create")
        guard let unit = instance else { throw Self.error("create") }
        self.unit = unit
        var on: UInt32 = 1, off: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32), "enable input")
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32), "disable output")
        var dev = device
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                            UInt32(MemoryLayout<AudioDeviceID>.size)), "select device")
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "read format")
        // Mono float at the device's own rate; the speech converter resamples afterwards.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, channels: 1, interleaved: false) else {
            throw Self.error("format")
        }
        format = mono
        var client = mono.streamDescription.pointee
        try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client,
                                            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set format")
        buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 8192)!
        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, timestamp, bus, frames, _ in
            let me = Unmanaged<HALInput>.fromOpaque(refCon).takeUnretainedValue()
            return me.render(flags, timestamp, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                                            UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "callback")
        try Self.check(AudioUnitInitialize(unit), "initialize")
    }

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timestamp: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, buffer.mutableAudioBufferList)
        if status == noErr { onBuffer?(buffer) }
        return status
    }

    func start() throws {
        guard let unit, !isRunning else { return }
        try Self.check(AudioOutputUnitStart(unit), "start")
        isRunning = true
    }

    func stop() {
        guard let unit, isRunning else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    deinit {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw error("\(step) failed (\(status))") }
    }
    private static func error(_ what: String) -> NSError {
        NSError(domain: "Lipi.Mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone: \(what)"])
    }
}

/// Microphone capture.
/// * The mic only runs while you dictate; the orange indicator turns off the moment you let go.
/// * By default Lipi records from the Mac's built-in mic, so Bluetooth headphones stay in
///   high-quality music mode. The built-in mic is kept initialised (not running) for a
///   near-instant start. Any other mic is opened per dictation and fully closed after.
final class Mic {
    private var input: HALInput?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private(set) var isRunning = false
    var onLevel: ((Float) -> Void)?
    private(set) var lastStartMs = 0
    private(set) var debugTiming = ""

    /// "" = built-in mic when there is one (recommended), "system" = macOS default, else a device UID.
    private var deviceUID = ""
    func select(deviceUID uid: String) {
        guard uid != deviceUID else { return }
        deviceUID = uid
        if !isRunning { input = nil }
    }

    /// Readies the built-in mic so the first word isn't lost. Does nothing for other mics.
    func prepare() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, !isRunning,
              let device = resolvedDevice(), device == AudioDevices.builtInInput() else { return }
        if input?.device != device { input = try? HALInput(device: device) }
    }

    private func resolvedDevice() -> AudioDeviceID? {
        switch deviceUID {
        case "": return AudioDevices.builtInInput() ?? Self.systemDefaultInput()
        case "system": return Self.systemDefaultInput()
        default: return AudioDevices.deviceID(forUID: deviceUID) ?? AudioDevices.builtInInput() ?? Self.systemDefaultInput()
        }
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

    /// Test harness only: plays this file at speaking speed instead of using the microphone.
    var fakeFile: URL?
    private var fakeTask: Task<Void, Never>?

    func start(format: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        stop()
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        if let fakeFile {
            let file = try AVAudioFile(forReading: fakeFile)
            let converter = StreamConverter(output: format)
            isRunning = true
            fakeTask = Task.detached { [weak self] in
                let chunk: AVAudioFrameCount = 2048
                while file.framePosition < file.length, !Task.isCancelled {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                          (try? file.read(into: buffer, frameCount: chunk)) != nil else { break }
                    self?.reportLevel(buffer)
                    if let converted = converter.convert(buffer) { continuation.yield(AnalyzerInput(buffer: converted)) }
                    try? await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate))
                }
            }
            return stream
        }
        let clock = Clock()
        guard let device = resolvedDevice() else {
            throw NSError(domain: "Lipi", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone available"])
        }
        let wasReady = input?.device == device
        let hal = wasReady ? input! : try HALInput(device: device)
        input = hal
        let tSetup = clock.ms
        let converter = StreamConverter(output: format)
        hal.onBuffer = { [weak self] buffer in
            self?.reportLevel(buffer)
            if let converted = converter.convert(buffer) { continuation.yield(AnalyzerInput(buffer: converted)) }
        }
        try hal.start()
        isRunning = true
        lastStartMs = clock.ms
        debugTiming = "\(wasReady ? "ready" : "opened") \(tSetup) ms, start total \(lastStartMs) ms, \(Int(hal.format.sampleRate)) Hz"
        return stream
    }

    func stop() {
        guard isRunning || continuation != nil else { return }
        if let fakeTask {
            fakeTask.cancel()
            self.fakeTask = nil
        }
        if let input {
            input.stop()
            input.onBuffer = nil
            // Only the built-in mic stays initialised; anything else is closed completely.
            if input.device != AudioDevices.builtInInput() { self.input = nil }
        }
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
