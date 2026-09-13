import AVFoundation
import CoreAudio
import Foundation

/// Feeds audio into a chosen device. Also serves as the mixer's output stage.
///
/// This drives an AUHAL directly. AVAudioEngine routes through a mixer node that
/// applies its own channel mixing, so a six-channel source can arrive folded
/// down or reordered — which defeats the point of channel mapping. The render
/// callback here writes straight into the device's channels.
final class DeviceOutput: @unchecked Sendable {

    /// Callback that fills one cycle of audio: one pointer per device channel,
    /// non-interleaved Float32.
    typealias RenderBlock = (_ channels: [UnsafeMutablePointer<Float>],
                             _ frameCount: Int) -> Void

    let sampleRate: Double
    let channelCount: Int

    private var unit: AudioUnit?
    private var render: RenderBlock?
    private var started = false

    /// Diagnostics: the buffer layout the AUHAL actually hands the render
    /// callback, as "buffers x channelsPerBuffer". Recorded on the first cycle.
    private(set) var observedLayout = "—"
    private var hasObservedLayout = false

    /// - Parameter channels: how many device channels to drive. Defaults to all
    ///   of the device's output channels.
    init(device: AudioDevice, channels: Int? = nil) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioError.missing("the AUHAL component")
        }

        var instance: AudioUnit?
        try ca("creating the output AUHAL") { AudioComponentInstanceNew(component, &instance) }
        guard let au = instance else { throw CoreAudioError.missing("the output AUHAL") }
        unit = au

        var deviceID = device.deviceID
        try ca("selecting the output device") {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        sampleRate = device.sampleRate > 0 ? device.sampleRate : 48000
        channelCount = max(1, channels ?? max(device.outputChannels, 2))

        // Built by hand rather than through AVAudioFormat, which refuses more
        // than two channels without a layout. For non-interleaved audio the
        // byte counts describe a single channel.
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                        | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0)
        try ca("setting the output format") {
            AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input, 0,
                                 &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        }
    }

    deinit { stop() }

    func start(render: @escaping RenderBlock) throws {
        guard let au = unit, !started else { return }
        self.render = render

        var callback = AURenderCallbackStruct(
            inputProc: { inRefCon, _, _, _, inNumberFrames, ioData in
                let output = Unmanaged<DeviceOutput>.fromOpaque(inRefCon).takeUnretainedValue()
                return output.fill(ioData, frames: Int(inNumberFrames))
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())

        try ca("installing the render callback") {
            AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback,
                                 kAudioUnitScope_Input, 0,
                                 &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        }
        try ca("initialising the output AUHAL") { AudioUnitInitialize(au) }
        try ca("starting the output AUHAL")    { AudioOutputUnitStart(au) }
        started = true
    }

    /// Diagnostics: the client and device-side formats the AUHAL is using.
    func describeFormats() -> String {
        guard let au = unit else { return "—" }
        func read(_ scope: AudioUnitScope, _ element: AudioUnitElement) -> String {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                              scope, element, &asbd, &size)
            guard status == noErr else { return "error \(status)" }
            let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            return "\(asbd.mChannelsPerFrame)ch \(Int(asbd.mSampleRate))Hz "
                 + (interleaved ? "interleaved" : "non-interleaved")
        }
        return "client(input scope)=\(read(kAudioUnitScope_Input, 0))  "
             + "device(output scope)=\(read(kAudioUnitScope_Output, 0))"
    }

    private func fill(_ ioData: UnsafeMutablePointer<AudioBufferList>?, frames: Int) -> OSStatus {
        guard let ioData else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        if !hasObservedLayout {
            hasObservedLayout = true
            let widths = buffers.map { "\($0.mNumberChannels)" }.joined(separator: ",")
            observedLayout = "\(buffers.count) buffer(s), channels per buffer [\(widths)]"
        }

        var channels: [UnsafeMutablePointer<Float>] = []
        channels.reserveCapacity(buffers.count)
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let pointer = data.assumingMemoryBound(to: Float.self)
            pointer.initialize(repeating: 0, count: frames)
            channels.append(pointer)
        }
        render?(channels, frames)
        return noErr
    }

    func stop() {
        guard let au = unit else { return }
        if started {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            started = false
        }
        AudioComponentInstanceDispose(au)
        unit = nil
        render = nil
    }
}

/// Captures audio from a chosen device's input. That covers microphones and
/// audio interfaces, and Tapdeck's own virtual devices.
///
/// This drives an AUHAL directly rather than using AVAudioEngine. Merely
/// touching AVAudioEngine's `inputNode` binds it to the default input device,
/// so it grabs an unintended microphone before the device can be chosen — and
/// if that triggers a TCC prompt, it blocks indefinitely.
final class DeviceInput {

    private var unit: AudioUnit?
    private var handler: ((AVAudioPCMBuffer, AudioTimeStamp) -> Void)?
    private var bufferList: UnsafeMutableAudioBufferListPointer?
    private(set) var format: AVAudioFormat
    private var started = false

    init(device: AudioDevice, sampleRate: Double? = nil) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioError.missing("the AUHAL component")
        }
        var instance: AudioUnit?
        try ca("creating the AUHAL") { AudioComponentInstanceNew(component, &instance) }
        guard let au = instance else { throw CoreAudioError.missing("the AUHAL instance") }
        unit = au

        // Bus 1 is input and bus 0 is output. Only input is wanted.
        var enable: UInt32 = 1
        try ca("enabling the input bus") {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input, 1,
                                 &enable, UInt32(MemoryLayout<UInt32>.size))
        }
        var disable: UInt32 = 0
        try ca("disabling the output bus") {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output, 0,
                                 &disable, UInt32(MemoryLayout<UInt32>.size))
        }

        // Pin the device before initialising. This is what AVAudioEngine
        // does not let us do.
        var deviceID = device.deviceID
        try ca("selecting the input device") {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        // Ask for non-interleaved Float32 on the output side of the input bus.
        let rate = sampleRate ?? device.sampleRate
        // Take every input channel. A multichannel virtual device carries
        // separate sources on separate channels, and folding it to stereo here
        // would throw that separation away.
        let channels = max(1, min(device.inputChannels, 64))
        guard let fmt = AVAudioFormat.discrete(sampleRate: rate, channels: channels) else {
            throw CoreAudioError.missing("the input format")
        }
        format = fmt

        var asbd = fmt.streamDescription.pointee
        try ca("setting the input format") {
            AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, 1,
                                 &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        }
    }

    deinit { stop() }

    /// - Parameter onAudio: the buffer and the time it was captured.
    ///   The timestamp is needed when muxing audio with video.
    func start(onAudio: @escaping (AVAudioPCMBuffer, AudioTimeStamp) -> Void) throws {
        guard let au = unit, !started else { return }
        handler = onAudio

        var callback = AURenderCallbackStruct(
            inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
                let input = Unmanaged<DeviceInput>.fromOpaque(inRefCon).takeUnretainedValue()
                return input.render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())

        try ca("installing the input callback") {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                 kAudioUnitScope_Global, 0,
                                 &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        }

        try ca("initialising the AUHAL") { AudioUnitInitialize(au) }
        try ca("starting the AUHAL")    { AudioOutputUnitStart(au) }
        started = true
    }

    /// Called by the AUHAL. AudioUnitRender pulls the actual audio out.
    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        _ timeStamp: UnsafePointer<AudioTimeStamp>,
                        _ bus: UInt32,
                        _ frames: UInt32) -> OSStatus {
        guard let au = unit, let handler else { return noErr }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return noErr
        }
        buffer.frameLength = frames

        let status = AudioUnitRender(au, flags, timeStamp, bus, frames, buffer.mutableAudioBufferList)
        guard status == noErr else { return status }

        handler(buffer, timeStamp.pointee)
        return noErr
    }

    func stop() {
        guard let au = unit else { return }
        if started {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            started = false
        }
        AudioComponentInstanceDispose(au)
        unit = nil
        handler = nil
    }

    /// Diagnostics: the device-side and client formats of the input bus.
    func describeFormats() -> String {
        guard let au = unit else { return "—" }
        func read(_ scope: AudioUnitScope) -> String {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat,
                                              scope, 1, &asbd, &size)
            guard status == noErr else { return "error \(status)" }
            let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            return "\(asbd.mChannelsPerFrame)ch \(Int(asbd.mSampleRate))Hz "
                 + (interleaved ? "interleaved" : "non-interleaved")
        }
        return "device(input scope)=\(read(kAudioUnitScope_Input))  "
             + "client(output scope)=\(read(kAudioUnitScope_Output))"
    }
}
