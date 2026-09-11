import AVFoundation
import AppKit
import Combine
import Foundation

/// ミキサー画面の状態。Mixer（エンジン）を包んで SwiftUI から扱えるようにする。
@MainActor
final class MixerModel: ObservableObject {

    /// 表示用のソース1行ぶん。
    struct Row: Identifiable {
        let id: UUID
        let label: String
        let kindLabel: String
        let symbolName: String
        let appIcon: NSImage?
        var gain: Float
        var isMuted: Bool
        var level: Float
        var isAttached: Bool
        var detail: String
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var masterLevel: Float = 0

    @Published private(set) var availableProcesses: [AudioProcess] = []
    @Published private(set) var availableInputs: [AudioDevice] = []
    @Published private(set) var outputCandidates: [AudioDevice] = []

    @Published var outputDeviceUID = "TapdeckDevice" {
        didSet { if oldValue != outputDeviceUID { persist() } }
    }

    @Published private(set) var presets: [MixerPreset] = []
    @Published private(set) var activePresetID: UUID?

    private let mixer = Mixer()
    private var meterTimer: Timer?
    private var iconCache: [String: NSImage] = [:]

    init() {
        let configuration = MixerConfiguration.load()
        outputDeviceUID = configuration.outputDeviceUID
        for entry in configuration.targets {
            let source = mixer.add(entry.target)
            source.gain = entry.gain
            source.isMuted = entry.isMuted
        }
        presets = MixerPresetStore.load()
        syncRows()
        status = rows.isEmpty ? "ソースを追加してください" : "前回の構成を復元しました"
    }

    // MARK: - プリセット

    /// いまの構成に名前を付けて保存する。同名があれば上書きする。
    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let configuration = MixerConfiguration(sources: mixer.sources,
                                               outputDeviceUID: outputDeviceUID)
        if let index = presets.firstIndex(where: { $0.name == trimmed }) {
            presets[index].configuration = configuration
            activePresetID = presets[index].id
        } else {
            let preset = MixerPreset(name: trimmed, configuration: configuration)
            presets.append(preset)
            activePresetID = preset.id
        }
        MixerPresetStore.save(presets)
        status = "プリセット「\(trimmed)」を保存しました"
    }

    /// プリセットを読み込んで、いまの構成を置き換える。
    func applyPreset(_ id: UUID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        let wasRunning = isRunning
        if wasRunning { stop() }

        mixer.removeAll()
        outputDeviceUID = preset.configuration.outputDeviceUID
        for entry in preset.configuration.targets {
            let source = mixer.add(entry.target)
            source.gain = entry.gain
            source.isMuted = entry.isMuted
        }
        activePresetID = id
        syncRows()
        persist()
        status = "プリセット「\(preset.name)」を読み込みました"

        if wasRunning { start() }
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if activePresetID == id { activePresetID = nil }
        MixerPresetStore.save(presets)
    }

    func clearSources() {
        let wasRunning = isRunning
        if wasRunning { stop() }
        mixer.removeAll()
        activePresetID = nil
        syncRows()
        persist()
        status = "ソースをすべて外しました"
    }

    // MARK: - 一覧の更新

    func refresh() {
        availableProcesses = ((try? AudioProcess.all()) ?? [])
            .filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
        let devices = (try? AudioDevice.all()) ?? []
        availableInputs = devices.filter(\.canInput)
        outputCandidates = devices.filter(\.canOutput)

        if outputCandidates.first(where: { $0.uid == outputDeviceUID }) == nil {
            outputDeviceUID = outputCandidates.first { $0.uid == "TapdeckDevice" }?.uid
                ?? outputCandidates.first?.uid ?? ""
        }

        // 動作中なら、後から起動したアプリに繋ぎ直す。
        if isRunning {
            let reattached = mixer.reattachDetached()
            if reattached > 0 { status = "\(reattached) 件のソースに接続しました" }
        }
        syncRows()
    }

    // MARK: - ソースの追加と削除

    func addApplication(_ process: AudioProcess) {
        add(.application(bundleID: process.bundleID, name: process.name))
    }

    func addSystemAudio() {
        guard !mixer.sources.contains(where: { $0.target == .systemAudio }) else {
            status = "システム全体の音は既に追加されています"
            return
        }
        add(.systemAudio)
    }

    func addInput(_ device: AudioDevice) {
        add(.inputDevice(uid: device.uid, name: device.name))
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
        playing.forEach { addApplication($0) }
        status = "\(playing.count) 個のアプリを追加しました"
    }

    private func add(_ target: Mixer.Target) {
        mixer.add(target)
        invalidateActivePreset()
        syncRows()
        persist()
    }

    func remove(_ id: UUID) {
        mixer.remove(id: id)
        invalidateActivePreset()
        syncRows()
        persist()
    }

    func setGain(_ gain: Float, for id: UUID) {
        mixer.sources.first { $0.id == id }?.gain = gain
        syncRows()
        persist()
    }

    func toggleMute(_ id: UUID) {
        guard let source = mixer.sources.first(where: { $0.id == id }) else { return }
        source.isMuted.toggle()
        syncRows()
        persist()
    }

    private func persist() {
        MixerConfiguration(sources: mixer.sources, outputDeviceUID: outputDeviceUID).save()
    }

    /// 手で構成を変えたらプリセットの選択を外す（内容が一致しなくなるため）。
    private func invalidateActivePreset() {
        activePresetID = nil
    }

    // MARK: - 表示用の変換

    private func syncRows() {
        rows = mixer.sources.map { source in
            Row(id: source.id,
                label: source.label,
                kindLabel: source.target.kindLabel,
                symbolName: Self.symbolName(for: source.target),
                appIcon: icon(for: source.target),
                gain: source.gain,
                isMuted: source.isMuted,
                level: rows.first { $0.id == source.id }?.level ?? 0,
                isAttached: source.isAttached,
                detail: detail(for: source))
        }
    }

    private func detail(for source: Mixer.Source) -> String {
        if !isRunning { return "" }
        if let reason = source.detachReason { return reason }
        return source.formatDescription
    }

    private static func symbolName(for target: Mixer.Target) -> String {
        switch target {
        case .application: return "app.badge"
        case .systemAudio: return "speaker.wave.3.fill"
        case .inputDevice: return "mic.fill"
        }
    }

    /// アプリのアイコンはバンドルIDから引く。起動していなくても取得できる。
    private func icon(for target: Mixer.Target) -> NSImage? {
        guard case .application(let bundleID, _) = target, let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = image
        return image
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
            let attached = mixer.sources.filter(\.isAttached).count
            status = attached == mixer.sources.count
                ? "\(device.name) へ \(attached) ソースを送出中"
                : "\(device.name) へ送出中（\(attached)/\(mixer.sources.count) 接続）"
            syncRows()
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
        syncRows()
        rows = rows.map { var row = $0; row.level = 0; return row }
        status = "停止しました"
    }

    func toggleRunning() { isRunning ? stop() : start() }

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
            // 落ちるときだけ緩やかに。跳ね上がりは即座に反映する。
            updated.level = max(peaks[row.id] ?? 0, row.level * 0.72)
            return updated
        }
        masterLevel = max(mixer.takeMasterPeak(), masterLevel * 0.72)
    }
}
