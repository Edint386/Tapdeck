import AVFoundation
import CoreAudio
import Foundation

/// 複数の音源を合成して1つの出力デバイスへ流す。
///
/// Loopback でいう「仮想デバイスに複数ソースを束ねる」部分。
/// 出力先を Tapdeck 仮想デバイスにすると、その入力側を Zoom や OBS が
/// マイクとして選べるようになる ＝「マイク＋コンピューターオーディオを共有」。
///
///     アプリ音声 (Process Tap) ┐
///     システム全体             ├→ [リングバッファ] → 加算 → 出力デバイス
///     マイク / 外部入力        ┘
final class Mixer: @unchecked Sendable {

    enum SourceKind {
        case application(AudioProcess)
        case systemAudio
        case inputDevice(AudioDevice)
    }

    /// ミキサーに登録された音源1つ。
    final class Source: Identifiable {
        let id = UUID()
        let kind: SourceKind
        let label: String
        let ring: AudioRingBuffer

        var gain: Float = 1.0
        var isMuted = false

        fileprivate var tap: ProcessTap?

        /// 診断用。
        var tapForDiagnostics: ProcessTap? { tap }
        fileprivate var input: DeviceInput?

        /// 音源のフォーマットが出力先と違うときだけ入る。
        fileprivate var converter: FormatConverter?

        /// 診断用。音源が実際に吐いているフォーマット。
        private(set) var sourceFormatDescription = "—"

        fileprivate func prepareConverter(sourceFormat: AVAudioFormat?,
                                          targetFormat: AVAudioFormat) {
            guard let sourceFormat else { return }
            sourceFormatDescription =
                "\(Int(sourceFormat.sampleRate)) Hz / \(sourceFormat.channelCount)ch"
            converter = FormatConverter(from: sourceFormat, to: targetFormat)
            if converter != nil {
                sourceFormatDescription += " → \(Int(targetFormat.sampleRate)) Hz に変換"
            }
        }

        /// 音源から届いたバッファを、必要なら変換してリングバッファへ積む。
        fileprivate func accept(_ buffer: AVAudioPCMBuffer) {
            if let converter {
                guard let converted = converter.convert(buffer) else { return }
                ring.write(converted)
            } else {
                ring.write(buffer)
            }
        }

        fileprivate init(kind: SourceKind, label: String, channels: Int) {
            self.kind = kind
            self.label = label
            self.ring = AudioRingBuffer(channels: channels)
        }

        fileprivate func stop() {
            tap?.stop(); tap = nil
            input?.stop(); input = nil
            converter = nil
            ring.clear()
        }
    }

    private(set) var sources: [Source] = []
    private(set) var isRunning = false
    private(set) var outputDevice: AudioDevice?

    private var output: DeviceOutput?
    private var targetFormat: AVAudioFormat?
    private let sourceLock = NSLock()
    private let channelCount = 2

    /// 出力側のピーク（メーター用）。
    private var masterPeak: Float = 0
    private let meterLock = NSLock()

    deinit { stop() }

    // MARK: - ソースの管理

    @discardableResult
    func addApplication(_ process: AudioProcess) -> Source {
        add(Source(kind: .application(process), label: process.name, channels: channelCount))
    }

    @discardableResult
    func addSystemAudio() -> Source {
        add(Source(kind: .systemAudio, label: "システム全体の音", channels: channelCount))
    }

    @discardableResult
    func addInputDevice(_ device: AudioDevice) -> Source {
        add(Source(kind: .inputDevice(device), label: device.name, channels: channelCount))
    }

    private func add(_ source: Source) -> Source {
        sourceLock.lock()
        sources.append(source)
        sourceLock.unlock()
        if isRunning { try? startSource(source) }
        return source
    }

    func remove(id: UUID) {
        sourceLock.lock()
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            sourceLock.unlock(); return
        }
        let source = sources.remove(at: index)
        sourceLock.unlock()
        source.stop()
    }

    func removeAll() {
        sourceLock.lock()
        let all = sources
        sources.removeAll()
        sourceLock.unlock()
        all.forEach { $0.stop() }
    }

    // MARK: - 開始と停止

    func start(to device: AudioDevice) throws {
        guard !isRunning else { return }
        outputDevice = device

        // 出力先を先に作る。各ソースの変換器を組むのに出力フォーマットが要るため。
        let deviceOutput = try DeviceOutput(device: device, channels: channelCount)
        targetFormat = deviceOutput.outputFormat

        sourceLock.lock()
        let snapshot = sources
        sourceLock.unlock()
        for source in snapshot {
            try startSource(source)
        }

        try deviceOutput.start { [weak self] channels, frameCount in
            self?.render(into: channels, frameCount: frameCount)
        }
        output = deviceOutput
        isRunning = true
    }

    func stop() {
        output?.stop()
        output = nil

        sourceLock.lock()
        let snapshot = sources
        sourceLock.unlock()
        snapshot.forEach { $0.stop() }

        isRunning = false
        outputDevice = nil
        targetFormat = nil
    }

    private func startSource(_ source: Source) throws {
        switch source.kind {
        case .application(let process):
            let tap = ProcessTap()
            // クロックは指定しない（＝既定の出力デバイス）。出力先を指定すると
            // レートは揃うが、そこへ流れていない音は拾えなくなる（実測で無音になった）。
            try tap.start(mode: .include([process])) { [weak source] buffer in
                source?.accept(buffer)
            }
            source.tap = tap
            if let targetFormat { source.prepareConverter(sourceFormat: tap.format, targetFormat: targetFormat) }

        case .systemAudio:
            // 自分自身の出力は除外する。含めるとミキサーの出力が
            // そのまま入力に戻ってフィードバックループになる。
            let me = try? AudioProcess.find(pid: ProcessInfo.processInfo.processIdentifier)
            let tap = ProcessTap()
            try tap.start(mode: .excluding(me.map { [$0] } ?? [])) { [weak source] buffer in
                source?.accept(buffer)
            }
            source.tap = tap
            if let targetFormat { source.prepareConverter(sourceFormat: tap.format, targetFormat: targetFormat) }

        case .inputDevice(let device):
            let input = try DeviceInput(device: device)
            try input.start { [weak source] buffer in
                source?.accept(buffer)
            }
            source.input = input
            if let targetFormat { source.prepareConverter(sourceFormat: input.format, targetFormat: targetFormat) }
        }
    }

    // MARK: - 合成

    /// 出力デバイスのコールバックから呼ばれる。全ソースを加算する。
    private func render(into channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        for channel in channels {
            for frame in 0..<frameCount { channel[frame] = 0 }
        }

        sourceLock.lock()
        let snapshot = sources
        sourceLock.unlock()

        for source in snapshot {
            let gain = source.isMuted ? 0 : source.gain
            source.ring.mixInto(channels, frameCount: frameCount, gain: gain)
        }

        // クリッピング防止。加算した結果が ±1 を超えたら潰れるので頭を抑える。
        var peak: Float = 0
        for channel in channels {
            for frame in 0..<frameCount {
                var value = channel[frame]
                if value > 1.0 { value = 1.0 } else if value < -1.0 { value = -1.0 }
                channel[frame] = value
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
            }
        }

        meterLock.lock()
        if peak > masterPeak { masterPeak = peak }
        meterLock.unlock()
    }

    /// 出力のピークを取り出して 0 に戻す。
    func takeMasterPeak() -> Float {
        meterLock.lock(); defer { meterLock.unlock() }
        let value = masterPeak
        masterPeak = 0
        return value
    }
}
