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
    private typealias Completion = (Bool) -> Void

    private struct Segment {
        var samples: ArraySlice<Float>
        let completion: Completion
    }

    private static let framesPerBuffer = 512
    private static let bufferCount = 3
    private var pending: [Segment] = []
    private var completions: [UInt: [Completion]] = [:]

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
        guard selected == noErr, matchesPinnedUID, prime(queue),
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
        guard !samples.isEmpty, actualRouteIsPinned else { return false }
        pending.append(Segment(samples: Array(samples)[...], completion: completion))
        return true
    }

    func close() {
        guard let queue = audioQueue else { return }
        audioQueue = nil
        pending.removeAll()
        completions.removeAll()
        AudioQueueDispose(queue, true)
    }

    private func prime(_ queue: AudioQueueRef) -> Bool {
        for _ in 0..<Self.bufferCount {
            let bytes = UInt32(Self.framesPerBuffer * MemoryLayout<Float>.size)
            var buffer: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(queue, bytes, &buffer) == noErr, let buffer,
                  refill(buffer, queue: queue) else { return false }
        }
        return true
    }

    /// The queue runs continuously at the device clock. Fill any gap with
    /// silence so irregular Bluetooth frame arrival cannot starve the queue.
    private func refill(_ buffer: AudioQueueBufferRef, queue: AudioQueueRef) -> Bool {
        let bytes = Self.framesPerBuffer * MemoryLayout<Float>.size
        let destination = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        var written = 0
        var finished: [Completion] = []
        while written < Self.framesPerBuffer, !pending.isEmpty {
            let count = min(Self.framesPerBuffer - written, pending[0].samples.count)
            pending[0].samples.withUnsafeBufferPointer { source in
                destination.advanced(by: written).update(from: source.baseAddress!, count: count)
            }
            written += count
            pending[0].samples.removeFirst(count)
            if pending[0].samples.isEmpty {
                finished.append(pending.removeFirst().completion)
            }
        }
        for index in written..<Self.framesPerBuffer { destination[index] = 0 }
        buffer.pointee.mAudioDataByteSize = UInt32(bytes)
        completions[UInt(bitPattern: buffer)] = finished
        return AudioQueueEnqueueBuffer(queue, buffer, 0, nil) == noErr
    }

    private func bufferConsumed(queueToken: UInt, bufferToken: UInt) {
        ownerQueue.async { [weak self] in
            guard let self, let audioQueue = self.audioQueue,
                  UInt(bitPattern: audioQueue) == queueToken,
                  let buffer = AudioQueueBufferRef(bitPattern: bufferToken),
                  let played = self.completions.removeValue(forKey: bufferToken) else { return }

            if !self.actualRouteIsPinned || !self.refill(buffer, queue: audioQueue) {
                let failed = played.first
                    ?? self.completions.values.lazy.compactMap { $0.first }.first
                    ?? self.pending.first?.completion
                self.close()
                failed?(false)
                return
            }

            guard !played.isEmpty else { return }
            self.ownerQueue.asyncAfter(deadline: .now() + self.tailDelay) { [weak self] in
                guard let self, self.audioQueue != nil else { return }
                let valid = self.actualRouteIsPinned
                played.forEach { $0(valid) }
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
