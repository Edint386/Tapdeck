import AVFoundation
import Combine
import Foundation

/// ミキサー画面の状態。Mixer（エンジン）を包んで SwiftUI から扱えるようにする。
@MainActor
final class MixerModel: ObservableObject {

    /// 表示用のソース1行ぶん。エンジン側の Source を UI の都合に合わせて写したもの。
    struct Row: Identifiable {
        let id: UUID
        let label: String
        let kindLabel: String
        var gain: Float
        var isMuted: Bool
        var level: Float
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = "ソースを追加してください"
    @Published private(set) var masterLevel: Float = 0

    @Published private(set) var availableProcesses: [AudioProcess] = []
    @Published private(set) var availableInputs: [AudioDevice] = []
    @Published private(set) var outputCandidates: [AudioDevice] = []
    @Published var outputDeviceUID = "TapdeckDevice"

    private let mixer = Mixer()
    private var meterTimer: Timer?

    // MARK: - 一覧の更新

    func refresh() {
        availableProcesses = ((try? AudioProcess.all()) ?? [])
            .filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
        let devices = (try? AudioDevice.all()) ?? []
        availableInputs = devices.filter(\.canInput)
        outputCandidates = devices.filter(\.canOutput)
        if outputCandidates.first(where: { $0.uid == outputDeviceUID }) == nil {
            outputDeviceUID = outputCandidates.first(where: { $0.uid == "TapdeckDevice" })?.uid
                ?? outputCandidates.first?.uid ?? ""
        }
    }

    // MARK: - ソースの追加と削除

    func addApplication(_ process: AudioProcess) {
        mixer.addApplication(process)
        syncRows()
    }

    func addSystemAudio() {
        mixer.addSystemAudio()
        syncRows()
    }

    func addInput(_ device: AudioDevice) {
        mixer.addInputDevice(device)
        syncRows()
    }

    /// 既定のマイクを1クリックで足す。「マイク＋コンピューターオーディオ」が
    /// 最も多い使い方なので、メニューを開かずに済むようにしておく。
    func addDefaultMicrophone() {
        refresh()
        let builtIn = availableInputs.first { $0.uid == "BuiltInMicrophoneDevice" }
        guard let device = builtIn ?? availableInputs.first(where: { $0.uid != "TapdeckDevice" })
        else {
            status = "入力デバイスが見つかりません"
            return
        }
        addInput(device)
    }

    /// いま音を鳴らしているアプリをまとめて足す。
    func addPlayingApplications() {
        refresh()
        let playing = availableProcesses.filter(\.isPlayingAudio)
        guard !playing.isEmpty else {
            status = "いま音を出しているアプリはありません"
            return
        }
        playing.forEach { mixer.addApplication($0) }
        syncRows()
        status = "\(playing.count) 個のアプリを追加しました"
    }

    func remove(_ id: UUID) {
        mixer.remove(id: id)
        syncRows()
    }

    func setGain(_ gain: Float, for id: UUID) {
        mixer.sources.first { $0.id == id }?.gain = gain
        syncRows()
    }

    func toggleMute(_ id: UUID) {
        guard let source = mixer.sources.first(where: { $0.id == id }) else { return }
        source.isMuted.toggle()
        syncRows()
    }

    private func syncRows() {
        rows = mixer.sources.map { source in
            Row(id: source.id,
                label: source.label,
                kindLabel: Self.kindLabel(source.kind),
                gain: source.gain,
                isMuted: source.isMuted,
                level: rows.first { $0.id == source.id }?.level ?? 0)
        }
    }

    private static func kindLabel(_ kind: Mixer.SourceKind) -> String {
        switch kind {
        case .application: return "アプリ"
        case .systemAudio: return "システム"
        case .inputDevice: return "入力"
        }
    }

    // MARK: - 開始と停止

    func start() {
        guard !isRunning else { return }
        guard !mixer.sources.isEmpty else {
            status = "ソースが1つもありません"
            return
        }
        guard let device = outputCandidates.first(where: { $0.uid == outputDeviceUID }) else {
            status = "出力先デバイスが見つかりません"
            return
        }
        do {
            try mixer.start(to: device)
            isRunning = true
            status = "\(device.name) へ \(mixer.sources.count) ソースを送出中"
            startMetering()
        } catch {
            status = "開始できませんでした: \(error.localizedDescription)"
        }
    }

    func stop() {
        mixer.stop()
        isRunning = false
        stopMetering()
        masterLevel = 0
        rows = rows.map { var r = $0; r.level = 0; return r }
        status = "停止しました"
    }

    // MARK: - メーター

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeters() }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func updateMeters() {
        let peaks = Dictionary(uniqueKeysWithValues:
            mixer.sources.map { ($0.id, $0.ring.takePeak()) })
        rows = rows.map { row in
            var updated = row
            let peak = peaks[row.id] ?? 0
            // 落ちるときだけ緩やかに。跳ね上がりは即座に反映する。
            updated.level = max(peak, row.level * 0.7)
            return updated
        }
        masterLevel = max(mixer.takeMasterPeak(), masterLevel * 0.7)
    }
}
