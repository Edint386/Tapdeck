import AVFoundation
import CoreAudio
import Foundation

/// Core Audio の Process Tap (macOS 14.2+) のラッパ。
///
/// これが Loopback 相当を実現する上での中核。仮想オーディオドライバも
/// カーネル拡張も使わずに、指定したアプリの音声だけを取り出せる。
///
/// 仕組み:
///   1. CATapDescription で「どのプロセスの音が欲しいか」を宣言し Tap を作る
///   2. Tap は単体では読めないので、Tap をサブデバイスとして含む
///      「private な集約デバイス」を組み立てる
///   3. その集約デバイスに IOProc を挿して音を受け取る
final class ProcessTap {

    enum Mode {
        /// 指定したプロセスの音だけを取り出す。
        case include([AudioProcess])
        /// 指定したプロセス以外の、システム全体の音を取り出す。
        case excluding([AudioProcess])
    }

    /// ハンドラに渡されるバッファの形式。
    /// Tap の生フォーマットはインターリーブだが、ここでは常に
    /// 非インターリーブ Float32 に正規化して渡す（ミキサー側が扱いやすいため）。
    private(set) var format: AVAudioFormat?
    private(set) var isRunning = false

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var handler: ((AVAudioPCMBuffer) -> Void)?

    private let queue = DispatchQueue(label: "dev.kosuke.Tapdeck.ProcessTap",
                                      qos: .userInitiated)

    deinit { stop() }

    // MARK: - 開始

    func start(mode: Mode,
               mute: CATapMuteBehavior = .unmuted,
               onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }
        handler = onAudio

        do {
            try createTap(mode: mode, mute: mute)
            // 集約デバイスを先に作る。実フォーマットは Tap ではなく
            // 集約デバイスから読む必要があるため（下の resolveFormat 参照）。
            try createAggregateDevice()
            let fmt = try resolveFormat()
            try attachIOProc(format: fmt)
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    private func createTap(mode: Mode, mute: CATapMuteBehavior) throws {
        let description: CATapDescription
        switch mode {
        case .include(let procs):
            description = CATapDescription(
                stereoMixdownOfProcesses: procs.map(\.objectID))
        case .excluding(let procs):
            description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: procs.map(\.objectID))
        }
        description.name = "Tapdeck"
        description.uuid = UUID()
        description.muteBehavior = mute

        try ca("Process Tap の作成") {
            AudioHardwareCreateProcessTap(description, &tapID)
        }
        guard tapID != 0 else { throw CoreAudioError.missing("作成された Tap") }
    }

    private func resolveFormat() throws -> AVAudioFormat {
        var asbd: AudioStreamBasicDescription = try AudioObjectID(tapID)
            .read(kAudioTapPropertyFormat, label: "Tap のフォーマット取得")

        // ここが落とし穴。IOProc に実際に流れてくるのは集約デバイスの入力ストリームで、
        // 集約デバイスのクロックは主サブデバイス（＝既定の出力デバイス）に従う。
        // そのため Tap が申告するサンプルレートと実レートが食い違うことがある。
        //
        // 実測例: 内蔵スピーカーは 44100 Hz で動作しているのに
        //         kAudioTapPropertyFormat は 48000 Hz と申告した。
        //         これを信じると録音が 48000/44100 = 8.8% ピッチシフトする
        //         （440 Hz の音が 479 Hz になる）。
        if let deviceRate: Float64 = try? AudioObjectID(aggregateID)
            .read(kAudioDevicePropertyNominalSampleRate,
                  label: "集約デバイスのサンプルレート取得"),
           deviceRate > 0,
           abs(deviceRate - asbd.mSampleRate) > 1 {
            sampleRateCorrection = (declared: asbd.mSampleRate, actual: deviceRate)
            asbd.mSampleRate = deviceRate
        }

        guard let raw = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError.missing("Tap のフォーマット")
        }
        rawFormat = raw

        guard let normalized = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: raw.sampleRate,
                                             channels: raw.channelCount,
                                             interleaved: false) else {
            throw CoreAudioError.missing("正規化後のフォーマット")
        }
        format = normalized
        return raw
    }

    /// Tap の申告レートと集約デバイスの実レートが食い違った場合の記録。
    private(set) var sampleRateCorrection: (declared: Float64, actual: Float64)?

    /// Tap が実際に吐く形式（インターリーブ）。デバッグ表示用。
    private(set) var rawFormat: AVAudioFormat?

    /// インターリーブされたバッファをチャンネルごとに分離する。
    /// Core Audio の Tap は必ずインターリーブで来るのに対し、AVAudioFile も
    /// AVAudioEngine も非インターリーブを前提にしているため、ここで揃える。
    private func normalize(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let outFormat = format else { return nil }
        guard src.format.isInterleaved else { return src }

        guard let dst = AVAudioPCMBuffer(pcmFormat: outFormat,
                                         frameCapacity: src.frameLength),
              let source = src.floatChannelData?[0],
              let target = dst.floatChannelData else { return nil }

        let frames = Int(src.frameLength)
        let channels = Int(src.format.channelCount)
        for frame in 0..<frames {
            let base = frame * channels
            for channel in 0..<channels {
                target[channel][frame] = source[base + channel]
            }
        }
        dst.frameLength = src.frameLength
        return dst
    }

    /// Tap を含む private な集約デバイスを作る。
    /// クロック源が要るので、既定の出力デバイスをサブデバイスとして必ず含める。
    private func createAggregateDevice() throws {
        guard let tapUID = AudioObjectID(tapID).readString(kAudioTapPropertyUID) else {
            throw CoreAudioError.missing("Tap の UID")
        }
        let outputUID = try defaultOutputDeviceUID()

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tapdeck Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID,
                ]
            ],
        ]

        try ca("集約デバイスの作成") {
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        }
    }

    private func attachIOProc(format rawFmt: AVAudioFormat) throws {
        try ca("IOProc の作成") {
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
                [weak self] _, inInputData, _, _, _ in
                guard let self, let handler = self.handler else { return }
                guard let raw = AVAudioPCMBuffer(pcmFormat: rawFmt,
                                                 bufferListNoCopy: inInputData),
                      let buffer = self.normalize(raw) else { return }
                handler(buffer)
            }
        }
        try ca("集約デバイスの開始") { AudioDeviceStart(aggregateID, ioProcID) }
    }

    // MARK: - 停止

    func stop() {
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        handler = nil
        isRunning = false
    }
}
