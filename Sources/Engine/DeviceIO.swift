import AVFoundation
import CoreAudio
import Foundation

/// Feeds audio into a chosen device. Also serves as the mixer's output stage.
///
/// AVAudioEngine connects to the default output device unless told otherwise,
/// so the destination is pinned by setting the AUHAL's
/// kAudioOutputUnitProperty_CurrentDevice.
final class DeviceOutput {

    /// Callback that fills one cycle of audio. Non-interleaved Float32.
    typealias RenderBlock = (_ channels: [UnsafeMutablePointer<Float>],
                             _ frameCount: Int) -> Void

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let format: AVAudioFormat

    init(device: AudioDevice, sampleRate: Double? = nil, channels: Int = 2) throws {
        guard let unit = engine.outputNode.audioUnit else {
            throw CoreAudioError.missing("the output node's AudioUnit")
        }
        var deviceID = device.deviceID
        try ca("selecting the output device") {
            AudioUnitSetProperty(unit,
                                 kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &deviceID,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let rate = sampleRate ?? device.sampleRate
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: rate,
                                      channels: AVAudioChannelCount(channels),
                                      interleaved: false) else {
            throw CoreAudioError.missing("the output format")
        }
        format = fmt
    }

    var outputFormat: AVAudioFormat { format }

    func start(render: @escaping RenderBlock) throws {
        let channelCount = Int(format.channelCount)

        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var channels: [UnsafeMutablePointer<Float>] = []
            channels.reserveCapacity(channelCount)
            for index in 0..<min(channelCount, buffers.count) {
                guard let data = buffers[index].mData else { continue }
                channels.append(data.assumingMemoryBound(to: Float.self))
            }
            guard channels.count == channelCount else { return noErr }
            render(channels, Int(frameCount))
            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
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
        let channels = max(1, min(device.inputChannels, 2))
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: rate,
                                      channels: AVAudioChannelCount(channels),
                                      interleaved: false) else {
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
}
