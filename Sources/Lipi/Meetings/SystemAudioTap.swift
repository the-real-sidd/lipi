import AVFoundation
import CoreAudio
import Speech

/// Captures what the other people in a call say: everything your Mac plays, through a
/// Core Audio process tap (macOS 14.2+). No virtual audio driver, no screen recording.
/// macOS asks once for "System Audio Recording" permission.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private let queue = DispatchQueue(label: "lipi.systemaudio", qos: .userInitiated)

    enum TapError: LocalizedError {
        case failed(String, OSStatus)
        var errorDescription: String? {
            if case .failed(let step, let status) = self { return "System audio \(step) failed (\(status))" }
            return nil
        }
    }

    func start(output: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        stop()
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Lipi Notes"

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.failed("tap", status) }
        tapID = tap

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd)
        guard status == noErr, let tapFormat = AVAudioFormat(streamDescription: &asbd) else { stop(); throw TapError.failed("format", status) }

        guard let outputUID = AudioDevices.defaultOutputUID() else { stop(); throw TapError.failed("output device", -1) }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Lipi Notes",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { stop(); throw TapError.failed("device", status) }
        aggregateID = device

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        let converter = StreamConverter(output: output)
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: input, deallocator: nil),
                  buffer.frameLength > 0,
                  let converted = converter.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        guard status == noErr, let procID else { stop(); throw TapError.failed("io", status) }
        status = AudioDeviceStart(device, procID)
        guard status == noErr else { stop(); throw TapError.failed("start", status) }
        return stream
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        continuation?.finish()
        continuation = nil
    }

    deinit { stop() }
}
