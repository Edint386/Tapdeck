import AVFoundation
import CoreAudio
import Foundation

/// 指定したオーディオデバイスへ音を流し込む。ミキサーの出力段でもある。
///
/// AVAudioEngine は既定では既定の出力デバイスへ繋がるので、
/// AUHAL の kAudioOutputUnitProperty_CurrentDevice を差し替えて出力先を固定する。
final class DeviceOutput {

    /// 1周期ぶんの音を書き込むコールバック。非インターリーブ Float32。
    typealias RenderBlock = (_ channels: [UnsafeMutablePointer<Float>],
                             _ frameCount: Int) -> Void

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let format: AVAudioFormat

    init(device: AudioDevice, sampleRate: Double? = nil, channels: Int = 2) throws {
        guard let unit = engine.outputNode.audioUnit else {
            throw CoreAudioError.missing("出力ノードの AudioUnit")
        }
        var deviceID = device.deviceID
        try ca("出力デバイスの指定") {
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
            throw CoreAudioError.missing("出力フォーマット")
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

/// 指定したオーディオデバイスの入力から音を取り込む。
/// マイクや外部インターフェースに加え、Tapdeck 自身の仮想デバイスも読める。
///
/// AVAudioEngine を使わず AUHAL を直接扱う。AVAudioEngine は `inputNode` に
/// 触れた時点で既定の入力デバイスへバインドしてしまい、デバイスを指定する前に
/// 意図しないマイクを掴む（そこで TCC 待ちになると無期限にブロックする）。
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
            throw CoreAudioError.missing("AUHAL コンポーネント")
        }
        var instance: AudioUnit?
        try ca("AUHAL の生成") { AudioComponentInstanceNew(component, &instance) }
        guard let au = instance else { throw CoreAudioError.missing("AUHAL インスタンス") }
        unit = au

        // バス1が入力、バス0が出力。入力だけを有効にする。
        var enable: UInt32 = 1
        try ca("入力バスの有効化") {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Input, 1,
                                 &enable, UInt32(MemoryLayout<UInt32>.size))
        }
        var disable: UInt32 = 0
        try ca("出力バスの無効化") {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
                                 kAudioUnitScope_Output, 0,
                                 &disable, UInt32(MemoryLayout<UInt32>.size))
        }

        // 初期化より前にデバイスを固定する。ここが AVAudioEngine との違い。
        var deviceID = device.deviceID
        try ca("入力デバイスの指定") {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0,
                                 &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        // 受け取りたい形式（非インターリーブ Float32）を入力バスの出力側に設定する。
        let rate = sampleRate ?? device.sampleRate
        let channels = max(1, min(device.inputChannels, 2))
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: rate,
                                      channels: AVAudioChannelCount(channels),
                                      interleaved: false) else {
            throw CoreAudioError.missing("入力フォーマット")
        }
        format = fmt

        var asbd = fmt.streamDescription.pointee
        try ca("入力フォーマットの設定") {
            AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, 1,
                                 &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        }
    }

    deinit { stop() }

    /// - Parameter onAudio: バッファと、それが取り込まれた時刻。
    ///   時刻は映像と音声を多重化するときに必要になる。
    func start(onAudio: @escaping (AVAudioPCMBuffer, AudioTimeStamp) -> Void) throws {
        guard let au = unit, !started else { return }
        handler = onAudio

        var callback = AURenderCallbackStruct(
            inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
                let input = Unmanaged<DeviceInput>.fromOpaque(inRefCon).takeUnretainedValue()
                return input.render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())

        try ca("入力コールバックの設定") {
            AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
                                 kAudioUnitScope_Global, 0,
                                 &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        }

        try ca("AUHAL の初期化") { AudioUnitInitialize(au) }
        try ca("AUHAL の開始")   { AudioOutputUnitStart(au) }
        started = true
    }

    /// AUHAL から呼ばれる。AudioUnitRender で実際の音を引き出す。
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
