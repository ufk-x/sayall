import AudioToolbox
import CoreAudio
import Foundation

/// An explicitly selected AudioQueue for the local G9N9N build. AVAudioEngine
/// may silently resume on the default speaker after changing the default input.
final class PinnedLoopbackOutput {
    private let deviceID: AudioDeviceID
    private let deviceUID: String
    private let ownerQueue: DispatchQueue
    private let callbackQueue = DispatchQueue(label: "RemoteMic.loopback.callbacks")
    private let tailDelay: TimeInterval
    private var audioQueue: AudioQueueRef?
    private var completions: [UInt: (Bool) -> Void] = [:]

    init?(deviceID: AudioDeviceID, deviceUID: String, sampleRate: Double, ownerQueue: DispatchQueue) {
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.ownerQueue = ownerQueue
        self.tailDelay = Self.outputTailDelay(deviceID)
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var queue: AudioQueueRef?
        guard AudioQueueNewOutputWithDispatchQueue(&queue, &format, 0, callbackQueue, { [weak self] aq, buffer in
            self?.bufferConsumed(queueToken: UInt(bitPattern: aq), bufferToken: UInt(bitPattern: buffer))
        }) == noErr, let queue else { return nil }
        audioQueue = queue
        let uid = deviceUID as CFString
        var uidReference = Unmanaged.passUnretained(uid)
        let selected = withExtendedLifetime(uid) {
            AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uidReference,
                                  UInt32(MemoryLayout<Unmanaged<CFString>>.size))
        }
        guard selected == noErr, matchesPinnedUID,
              AudioQueueStart(queue, nil) == noErr,
              matchesPinnedUID else {
            close()
            return nil
        }
    }

    deinit { close() }

    var matchesPinnedUID: Bool {
        guard let audioQueue else { return false }
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioQueueGetProperty(audioQueue, kAudioQueueProperty_CurrentDevice, &uid, &size) == noErr,
              let uid else { return false }
        return uid.takeRetainedValue() as String == deviceUID
    }

    /// The queue's property alone was not sufficient evidence with AVAudioEngine.
    /// Check the current process's actual hardware output before handing it speech.
    var actualRouteIsPinned: Bool {
        guard matchesPinnedUID else { return false }
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var translate = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translate, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process) == noErr,
              process != kAudioObjectUnknown else { return false }
        var outputs = Self.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput)
        var outputID = AudioDeviceID(kAudioObjectUnknown)
        // A larger property value means the process is driving multiple devices.
        // Refuse that configuration rather than treating the first item as proof.
        guard AudioObjectGetPropertyDataSize(process, &outputs, 0, nil, &size) == noErr,
              size == MemoryLayout<AudioDeviceID>.size else { return false }
        return AudioObjectGetPropertyData(process, &outputs, 0, nil, &size, &outputID) == noErr
            && size == MemoryLayout<AudioDeviceID>.size && outputID == deviceID
    }

    func enqueue(_ samples: UnsafeBufferPointer<Float>, completion: @escaping (Bool) -> Void) -> Bool {
        dispatchPrecondition(condition: .onQueue(ownerQueue))
        guard let audioQueue, let base = samples.baseAddress, !samples.isEmpty,
              actualRouteIsPinned else { return false }
        let byteCount = UInt32(samples.count * MemoryLayout<Float>.size)
        var buffer: AudioQueueBufferRef?
        guard AudioQueueAllocateBuffer(audioQueue, byteCount, &buffer) == noErr, let buffer else { return false }
        memcpy(buffer.pointee.mAudioData, base, Int(byteCount))
        buffer.pointee.mAudioDataByteSize = byteCount
        let token = UInt(bitPattern: buffer)
        completions[token] = completion
        guard AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil) == noErr else {
            completions.removeValue(forKey: token)
            AudioQueueFreeBuffer(audioQueue, buffer)
            return false
        }
        return true
    }

    func close() {
        guard let queue = audioQueue else { return }
        audioQueue = nil
        completions.removeAll()
        AudioQueueDispose(queue, true)
    }

    private func bufferConsumed(queueToken: UInt, bufferToken: UInt) {
        ownerQueue.async { [weak self] in
            guard let self, let audioQueue = self.audioQueue,
                  UInt(bitPattern: audioQueue) == queueToken,
                  let buffer = AudioQueueBufferRef(bitPattern: bufferToken),
                  let completion = self.completions.removeValue(forKey: bufferToken) else { return }
            AudioQueueFreeBuffer(audioQueue, buffer)
            // AudioQueue has consumed the buffer. Give the device enough time
            // to deliver the tail before allowing the host to release Fn.
            self.ownerQueue.asyncAfter(deadline: .now() + self.tailDelay) { [weak self] in
                guard let self, self.audioQueue != nil else { return }
                completion(self.actualRouteIsPinned)
            }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func outputTailDelay(_ device: AudioDeviceID) -> TimeInterval {
        var rate: Float64 = 48_000
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateProperty = address(kAudioDevicePropertyNominalSampleRate)
        _ = AudioObjectGetPropertyData(device, &rateProperty, 0, nil, &rateSize, &rate)
        guard rate.isFinite, rate > 0 else { return 0.1 }
        let frames = [
            address(kAudioDevicePropertyBufferFrameSize),
            address(kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput),
            address(kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput),
        ].reduce(0.0) { sum, property in
            var property = property
            var frames: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &frames) == noErr else { return sum }
            return sum + Double(frames)
        }
        return max(0.08, frames / rate + 0.02)
    }
}
