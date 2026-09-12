import AVFoundation
import Combine
import CoreAudio
import Foundation

/// アプリ側からオーディオエンジンを操作するモデル。
/// 現状はデバイス一覧と、仮想デバイスのループバック検証を担当する。
@MainActor
final class AudioEngineModel: ObservableObject {

    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var tapdeck: AudioDevice?
    @Published private(set) var processes: [AudioProcess] = []

    @Published private(set) var isTesting = false
    @Published private(set) var status = "準備完了"
    @Published private(set) var peakDB: Double = -120
    @Published private(set) var rmsDB: Double = -120
    @Published private(set) var receivedSamples = 0
    @Published private(set) var verdict: Verdict = .unknown
    @Published private(set) var capturedFile: URL?
    @Published private(set) var isMonitoring = false
    @Published private(set) var monitorStatus = ""
    @Published private(set) var monitorPeakDB: Double = -120

    // MARK: - 仮想デバイスの管理

    @Published private(set) var virtualDevices: [VirtualDeviceConfiguration.Device] = []
    @Published private(set) var virtualDeviceStatus = ""

    enum Verdict {
        case unknown, passed, failed
    }

    private var input: DeviceInput?
    private var output: DeviceOutput?

    /// レベル計測と録音はオーディオスレッドから書き込まれるため、
    /// MainActor 隔離の外に置く必要がある。
    private let meter = LevelAccumulator()

    /// 検証で取り込んだ音の保存先。振幅だけでなく周波数も後から確かめられるようにする。
    static var captureURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.kosuke.Tapdeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("loopback-test.wav")
    }

    // MARK: - 仮想デバイス

    func loadVirtualDevices() {
        virtualDevices = VirtualDeviceConfiguration.load().devices
    }

    func addVirtualDevice(name: String, channels: Int = 2) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard virtualDevices.count < 8 else {
            virtualDeviceStatus = "仮想デバイスは8台までです"
            return
        }
        virtualDevices.append(.init(name: trimmed, channelCount: channels))
        commitVirtualDevices()
    }

    func renameVirtualDevice(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = virtualDevices.firstIndex(where: { $0.id == id })
        else { return }
        virtualDevices[index].name = trimmed
        commitVirtualDevices()
    }

    func removeVirtualDevice(id: String) {
        guard virtualDevices.count > 1 else {
            virtualDeviceStatus = "最低1台は残してください"
            return
        }
        virtualDevices.removeAll { $0.id == id }
        commitVirtualDevices()
    }

    private func commitVirtualDevices() {
        do {
            try VirtualDeviceConfiguration(devices: virtualDevices).save()
            virtualDeviceStatus = "保存しました"
            // The driver applies it immediately, but the HAL needs a moment to
            // republish the device list to clients.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                refresh()
                virtualDeviceStatus = ""
            }
        } catch {
            virtualDeviceStatus = error.localizedDescription
        }
    }

    // MARK: - 一覧

    func refresh() {
        do {
            devices = try AudioDevice.all()
            tapdeck = devices.first { $0.uid == "TapdeckDevice" }
            processes = (try? AudioProcess.all()) ?? []
            loadVirtualDevices()

            if tapdeck == nil {
                status = "Tapdeck 仮想デバイスが見つかりません（ドライバ未インストール）"
                verdict = .failed
            } else if verdict == .unknown {
                // 検証済みの結果は上書きしない。
                status = "準備完了"
            }
        } catch {
            status = "デバイス一覧の取得に失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - ループバック検証

    /// 仮想デバイスの出力側に 440Hz を流し、同じデバイスの入力側から読み返す。
    /// 読み返せればドライバのリングバッファが正しく機能している。
    func runLoopbackTest(seconds: Double = 4) async {
        guard !isTesting else { return }
        guard let device = tapdeck else {
            status = "Tapdeck 仮想デバイスがありません"
            verdict = .failed
            return
        }

        isTesting = true
        verdict = .unknown
        peakDB = -120
        rmsDB = -120
        receivedSamples = 0
        resetMetrics()

        defer { isTesting = false }

        // 入力デバイスの読み取りにはマイク許可が要る。
        // GUI アプリなのでここで普通にプロンプトが出る。
        guard await ensureMicrophoneAccess() else {
            status = "マイクの使用が許可されていません。システム設定 > プライバシーとセキュリティ > マイク を確認してください。"
            verdict = .failed
            return
        }

        do {
            status = "入力側を開いています …"
            let deviceInput = try DeviceInput(device: device)
            let url = Self.captureURL
            try? FileManager.default.removeItem(at: url)
            meter.beginWriting(to: url)

            let meter = self.meter
            try deviceInput.start { buffer, _ in
                meter.accumulate(buffer)
            }
            input = deviceInput

            status = "出力側へ 440Hz を送出中 …"
            let deviceOutput = try DeviceOutput(device: device)
            let rate = deviceOutput.outputFormat.sampleRate
            var phase = 0.0
            let increment = 2.0 * Double.pi * 440.0 / rate

            try deviceOutput.start { channels, frameCount in
                for frame in 0..<frameCount {
                    let value = Float(sin(phase) * 0.25)
                    phase += increment
                    if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
                    for channel in channels { channel[frame] = value }
                }
            }
            output = deviceOutput

            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

            deviceOutput.stop()
            deviceInput.stop()
            output = nil
            input = nil

            finishMeasurement()
        } catch {
            input?.stop(); input = nil
            output?.stop(); output = nil
            status = "検証に失敗: \(error.localizedDescription)"
            verdict = .failed
        }
    }

    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:             return false
        }
    }

    // MARK: - 入力のモニタ録音

    /// 仮想デバイスの入力側をそのまま録音する。
    /// ミキサーが送出している内容を、外部ツールを介さずに確かめるための機能。
    /// （ffmpeg の avfoundation 経由の録音は取りこぼしがあり、測定に使えない）
    static var monitorURL: URL {
        captureURL.deletingLastPathComponent().appendingPathComponent("monitor.wav")
    }

    func recordInput(seconds: Double = 4) async {
        guard !isMonitoring, !isTesting else { return }
        guard let device = tapdeck else {
            monitorStatus = "Tapdeck 仮想デバイスがありません"
            return
        }
        guard await ensureMicrophoneAccess() else {
            monitorStatus = "マイクの使用が許可されていません"
            return
        }

        isMonitoring = true
        monitorPeakDB = -120
        defer { isMonitoring = false }

        let monitorMeter = LevelAccumulator()
        let url = Self.monitorURL
        try? FileManager.default.removeItem(at: url)
        monitorMeter.beginWriting(to: url)

        do {
            let input = try DeviceInput(device: device)
            try input.start { buffer, _ in monitorMeter.accumulate(buffer) }
            monitorStatus = "\(device.name) の入力を録音中 …"
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            input.stop()
            monitorMeter.finishWriting()

            let (peak, _, count) = monitorMeter.snapshot()
            monitorPeakDB = peak > 0 ? 20 * log10(Double(peak)) : -120
            monitorStatus = count > 0
                ? "録音しました（\(count) サンプル、ピーク \(String(format: "%.1f", monitorPeakDB)) dB）"
                : "何も届きませんでした"
        } catch {
            monitorMeter.finishWriting()
            monitorStatus = "録音に失敗: \(error.localizedDescription)"
        }
    }

    // MARK: - 計測

    private func resetMetrics() { meter.reset() }

    private func finishMeasurement() {
        meter.finishWriting()
        capturedFile = FileManager.default.fileExists(atPath: Self.captureURL.path)
            ? Self.captureURL : nil
        let (finalPeak, finalSum, n) = meter.snapshot()
        receivedSamples = n
        guard n > 0 else {
            status = "入力側に音が1サンプルも届きませんでした。"
            verdict = .failed
            return
        }

        let rms = (finalSum / Double(n)).squareRoot()
        peakDB = finalPeak > 0 ? 20 * log10(Double(finalPeak)) : -120
        rmsDB  = rms > 0 ? 20 * log10(rms) : -120

        if finalPeak < 1e-5 {
            status = "無音でした。ループバックが繋がっていません。"
            verdict = .failed
        } else {
            status = "出力側に流した音を入力側から読み返せました。"
            verdict = .passed
        }
    }
}


/// オーディオスレッドから安全に書き込めるレベル計測器。
/// MainActor には属さない。
final class LevelAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var total = 0

    private var file: AVAudioFile?
    private var destination: URL?

    func reset() {
        lock.lock(); peak = 0; sumSquares = 0; total = 0; lock.unlock()
    }

    func beginWriting(to url: URL) {
        lock.lock(); destination = url; file = nil; lock.unlock()
    }

    func finishWriting() {
        lock.lock(); file = nil; destination = nil; lock.unlock()
    }

    func accumulate(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        var localPeak: Float = 0
        var localSum: Double = 0
        var count = 0
        for channel in 0..<channels {
            let pointer = data[channel]
            for frame in 0..<frames {
                let value = abs(pointer[frame])
                if value > localPeak { localPeak = value }
                localSum += Double(value) * Double(value)
                count += 1
            }
        }

        lock.lock()
        if localPeak > peak { peak = localPeak }
        sumSquares += localSum
        total += count

        if file == nil, let destination {
            // 処理フォーマットを入力の実フォーマットに完全一致させる。
            // ずれていると write(from:) が毎回失敗し、ヘッダだけのファイルになる。
            file = try? AVAudioFile(forWriting: destination,
                                    settings: buffer.format.settings,
                                    commonFormat: buffer.format.commonFormat,
                                    interleaved: buffer.format.isInterleaved)
        }
        try? file?.write(from: buffer)
        lock.unlock()
    }

    func snapshot() -> (peak: Float, sumSquares: Double, count: Int) {
        lock.lock(); defer { lock.unlock() }
        return (peak, sumSquares, total)
    }
}
