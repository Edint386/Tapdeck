import AVFoundation
import AppKit
import CoreAudio
import Foundation

/// 複数の音源を合成して1つの出力デバイスへ流す。
///
/// Loopback でいう「仮想デバイスに複数ソースを束ねる」部分。
/// 出力先を Tapdeck 仮想デバイスにすると、その入力側を Zoom や OBS が
/// マイクとして選べる ＝「マイク＋コンピューターオーディオを共有」。
///
///     アプリ音声 (Process Tap) ┐
///     システム全体             ├→ [変換] → [リングバッファ] → 加算 → 出力デバイス
///     マイク / 外部入力        ┘
final class Mixer: @unchecked Sendable {

    /// ソースが何を指しているか。
    ///
    /// 実体（AudioProcess / AudioDevice）は開始時に解決する。アプリは再起動で
    /// PID が変わるため、同定はバンドルIDで行う。こうしないと設定を保存しても
    /// 次回の起動で繋がらない。
    enum Target: Equatable {
        case application(bundleID: String?, name: String)
        case systemAudio
        case inputDevice(uid: String, name: String)

        var label: String {
            switch self {
            case .application(_, let name): return name
            case .systemAudio:              return "システム全体の音"
            case .inputDevice(_, let name): return name
            }
        }

        var kindLabel: String {
            switch self {
            case .application: return "アプリ"
            case .systemAudio: return "システム"
            case .inputDevice: return "入力"
            }
        }

        /// 保存できるか。バンドルIDを持たないプロセスは次回起動時に同定できない。
        var isPersistable: Bool {
            switch self {
            case .application(let bundleID, _): return bundleID != nil
            case .systemAudio, .inputDevice:    return true
            }
        }
    }

    /// ミキサーに登録された音源1つ。
    final class Source: Identifiable {
        let id = UUID()
        let target: Target
        let ring: AudioRingBuffer

        var gain: Float = 1.0
        var isMuted = false

        /// 対象が見つからず接続できていない状態。
        /// アプリを終了していても行は残り、起動したら繋がる。
        private(set) var isAttached = false
        private(set) var detachReason: String?

        fileprivate var tap: ProcessTap?

        /// 診断用。
        var tapForDiagnostics: ProcessTap? { tap }
        fileprivate var input: DeviceInput?
        fileprivate var converter: FormatConverter?

        private(set) var formatDescription = "—"

        var label: String { target.label }

        fileprivate init(target: Target, channels: Int) {
            self.target = target
            self.ring = AudioRingBuffer(channels: channels)
        }

        fileprivate func markAttached(sourceFormat: AVAudioFormat?, targetFormat: AVAudioFormat) {
            isAttached = true
            detachReason = nil
            guard let sourceFormat else { return }
            formatDescription = "\(Int(sourceFormat.sampleRate)) Hz / \(sourceFormat.channelCount)ch"
            converter = FormatConverter(from: sourceFormat, to: targetFormat)
            if converter != nil {
                formatDescription += " → \(Int(targetFormat.sampleRate)) Hz"
            }
        }

        fileprivate func markDetached(_ reason: String) {
            isAttached = false
            detachReason = reason
            formatDescription = "—"
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

        fileprivate func stop() {
            tap?.stop(); tap = nil
            input?.stop(); input = nil
            converter = nil
            isAttached = false
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

    private var masterPeak: Float = 0
    private let meterLock = NSLock()

    deinit { stop() }

    // MARK: - ソースの管理

    @discardableResult
    func add(_ target: Target) -> Source {
        let source = Source(target: target, channels: channelCount)
        sourceLock.lock()
        sources.append(source)
        sourceLock.unlock()
        if isRunning { try? attach(source) }
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

    /// 並べ替え。SwiftUI の move(fromOffsets:toOffset:) は使わない
    /// （エンジンが UI フレームワークに依存しないようにするため）。
    func move(from offsets: IndexSet, to destination: Int) {
        sourceLock.lock()
        defer { sourceLock.unlock() }

        let moving = offsets.sorted().compactMap { sources.indices.contains($0) ? sources[$0] : nil }
        guard !moving.isEmpty else { return }

        let insertionIndex = destination - offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) where sources.indices.contains(index) {
            sources.remove(at: index)
        }
        sources.insert(contentsOf: moving, at: max(0, min(insertionIndex, sources.count)))
    }

    func removeAll() {
        sourceLock.lock()
        let all = sources
        sources.removeAll()
        sourceLock.unlock()
        all.forEach { $0.stop() }
    }

    /// 未接続のソースを繋ぎ直す。対象アプリが後から起動した場合に使う。
    @discardableResult
    func reattachDetached() -> Int {
        guard isRunning else { return 0 }
        sourceLock.lock()
        let pending = sources.filter { !$0.isAttached }
        sourceLock.unlock()

        var reattached = 0
        for source in pending where (try? attach(source)) != nil {
            if source.isAttached { reattached += 1 }
        }
        return reattached
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
        for source in snapshot { try? attach(source) }

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

    /// ソースを実体に結びつける。対象が居なければ未接続のまま残す。
    private func attach(_ source: Source) throws {
        guard let targetFormat else { return }
        guard !source.isAttached else { return }

        switch source.target {
        case .application(let bundleID, let name):
            guard let process = try locateProcess(bundleID: bundleID, name: name) else {
                source.markDetached("\(name) は起動していません")
                return
            }
            let tap = ProcessTap()
            try tap.start(mode: .include([process])) { [weak source] buffer in
                source?.accept(buffer)
            }
            source.tap = tap
            source.markAttached(sourceFormat: tap.format, targetFormat: targetFormat)

        case .systemAudio:
            // 自分自身の出力は除外する。含めるとミキサーの出力がそのまま
            // 入力に戻ってフィードバックループになる。
            let me = try? AudioProcess.find(pid: ProcessInfo.processInfo.processIdentifier)
            let tap = ProcessTap()
            try tap.start(mode: .excluding(me.map { [$0] } ?? [])) { [weak source] buffer in
                source?.accept(buffer)
            }
            source.tap = tap
            source.markAttached(sourceFormat: tap.format, targetFormat: targetFormat)

        case .inputDevice(let uid, let name):
            guard let device = try AudioDevice.find(uid: uid) else {
                source.markDetached("\(name) が見つかりません")
                return
            }
            let input = try DeviceInput(device: device)
            try input.start { [weak source] buffer, _ in
                source?.accept(buffer)
            }
            source.input = input
            source.markAttached(sourceFormat: input.format, targetFormat: targetFormat)
        }
    }

    private func locateProcess(bundleID: String?, name: String) throws -> AudioProcess? {
        let all = try AudioProcess.all()
        if let bundleID {
            return all.first { $0.bundleID == bundleID }
        }
        return all.first { $0.name == name }
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

        // クリッピング防止。加算結果が ±1 を超えると潰れる。
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

    func takeMasterPeak() -> Float {
        meterLock.lock(); defer { meterLock.unlock() }
        let value = masterPeak
        masterPeak = 0
        return value
    }
}
