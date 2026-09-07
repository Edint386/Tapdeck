import AppKit
import AVFoundation
import Combine
import CoreMedia
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit を直接叩く収録エンジン。
/// 仮想オーディオドライバ (BlackHole / Soundflower) は一切使わない。
/// システム音声は SCStreamConfiguration.capturesAudio、
/// マイクは captureMicrophone (macOS 15+) でそれぞれ直接取得する。
@MainActor
final class Recorder: NSObject, ObservableObject {

    enum Target: Hashable {
        case display(CGDirectDisplayID)
        case window(CGWindowID)
        case app(pid_t)
    }

    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
        let target: Target
    }

    enum Failure: LocalizedError {
        case noContent
        case noTarget
        case micDenied

        var errorDescription: String? {
            switch self {
            case .noContent: return "共有可能なコンテンツを取得できませんでした。画面収録の許可を確認してください。"
            case .noTarget:  return "収録対象が見つかりません。一覧を更新してください。"
            case .micDenied: return "マイクの使用が許可されていません。システム設定 > プライバシーとセキュリティ > マイク を確認してください。"
            }
        }
    }

    // MARK: - 一覧

    @Published private(set) var displayOptions: [Option] = []
    @Published private(set) var windowOptions: [Option] = []
    @Published private(set) var appOptions: [Option] = []

    // MARK: - 状態

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastOutput: URL?
    @Published private(set) var status = "準備完了"
    @Published private(set) var outputSize: CGSize = .zero

    // MARK: - 設定

    @Published var selectedID = ""
    @Published var scalePercent = 100
    @Published var fps = 60
    @Published var systemAudio = true
    @Published var microphone = false
    @Published var showsCursor = true

    // MARK: - 内部

    private var content: SCShareableContent?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var ticker: Timer?
    private var startedAt: Date?

    private var allOptions: [Option] { displayOptions + appOptions + windowOptions }

    // MARK: - 収録対象の列挙

    func refreshContent() async {
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            content = c

            displayOptions = c.displays.map { d in
                Option(id: "display:\(d.displayID)",
                       label: "画面全体 — \(d.width)×\(d.height)",
                       target: .display(d.displayID))
            }

            let ownPID = ProcessInfo.processInfo.processIdentifier
            appOptions = c.applications
                .filter { $0.processID != ownPID && !$0.applicationName.isEmpty }
                .filter { app in c.windows.contains { $0.owningApplication?.processID == app.processID } }
                .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
                .map { Option(id: "app:\($0.processID)",
                              label: "アプリ: \($0.applicationName)",
                              target: .app($0.processID)) }

            windowOptions = c.windows
                .filter { ($0.title?.isEmpty == false) && $0.frame.width > 120 && $0.frame.height > 80 }
                .filter { $0.owningApplication?.processID != ownPID }
                .prefix(60)
                .map { w in
                    let owner = w.owningApplication?.applicationName ?? "?"
                    return Option(id: "window:\(w.windowID)",
                                  label: "ウインドウ: \(owner) — \(w.title ?? "")",
                                  target: .window(w.windowID))
                }

            if allOptions.first(where: { $0.id == selectedID }) == nil {
                selectedID = displayOptions.first?.id ?? ""
            }
            updateOutputSize()
            status = "準備完了"
        } catch {
            status = "画面収録の許可が必要です: \(error.localizedDescription)"
        }
    }

    // MARK: - フィルタと解像度

    private func makeFilter() throws -> SCContentFilter {
        guard let content else { throw Failure.noContent }
        guard let opt = allOptions.first(where: { $0.id == selectedID }) else { throw Failure.noTarget }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        switch opt.target {
        case .display(let id):
            guard let d = content.displays.first(where: { $0.displayID == id }) else { throw Failure.noTarget }
            // 自分自身のウインドウは映さない（収録UIが写り込むのを防ぐ）
            let own = content.applications.filter { $0.processID == ownPID }
            return SCContentFilter(display: d, excludingApplications: own, exceptingWindows: [])

        case .window(let id):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw Failure.noTarget }
            return SCContentFilter(desktopIndependentWindow: w)

        case .app(let pid):
            guard let d = content.displays.first,
                  let a = content.applications.first(where: { $0.processID == pid })
            else { throw Failure.noTarget }
            return SCContentFilter(display: d, including: [a], exceptingWindows: [])
        }
    }

    /// 選択中の対象を、指定倍率で収録したときの実ピクセルサイズ。
    /// H.264 は偶数サイズしか受け付けないので 2 の倍数に丸める。
    private func pixelSize(for filter: SCContentFilter) -> (Int, Int) {
        let rect = filter.contentRect
        let scale = CGFloat(filter.pointPixelScale)
        let factor = CGFloat(scalePercent) / 100
        let w = max(2, Int((rect.width * scale * factor).rounded()) / 2 * 2)
        let h = max(2, Int((rect.height * scale * factor).rounded()) / 2 * 2)
        return (w, h)
    }

    func updateOutputSize() {
        guard let filter = try? makeFilter() else { outputSize = .zero; return }
        let (w, h) = pixelSize(for: filter)
        outputSize = CGSize(width: w, height: h)
    }

    // MARK: - 収録

    func start() async {
        guard !isRecording else { return }
        do {
            if microphone { try await ensureMicrophoneAccess() }

            let filter = try makeFilter()
            let (w, h) = pixelSize(for: filter)

            let cfg = SCStreamConfiguration()
            cfg.width = w
            cfg.height = h
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            cfg.showsCursor = showsCursor
            cfg.scalesToFit = true
            cfg.captureResolution = .best
            cfg.queueDepth = 6
            cfg.pixelFormat = kCVPixelFormatType_32BGRA

            // ここが「マイクしか選べない」を解消している部分
            cfg.capturesAudio = systemAudio
            cfg.excludesCurrentProcessAudio = true
            cfg.captureMicrophone = microphone

            let url = Self.makeOutputURL()
            let rcfg = SCRecordingOutputConfiguration()
            rcfg.outputURL = url
            rcfg.outputFileType = .mov
            rcfg.videoCodecType = .h264

            let out = SCRecordingOutput(configuration: rcfg, delegate: self)
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addRecordingOutput(out)
            try await s.startCapture()

            stream = s
            output = out
            lastOutput = url
            outputSize = CGSize(width: w, height: h)
            startedAt = Date()
            elapsed = 0
            isRecording = true
            status = "収録中 — \(w)×\(h) @ \(fps)fps"
            startTicker()
        } catch {
            status = "開始できませんでした: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard let s = stream else { return }
        do {
            try await s.stopCapture()
            status = "保存しました: \(lastOutput?.lastPathComponent ?? "")"
        } catch {
            status = "停止時にエラー: \(error.localizedDescription)"
        }
        stream = nil
        output = nil
        isRecording = false
        ticker?.invalidate()
        ticker = nil
        startedAt = nil
    }

    func revealLastOutput() {
        guard let url = lastOutput else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 補助

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let started = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw Failure.micDenied
        default:
            throw Failure.micDenied
        }
    }

    private static func makeOutputURL() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Tapdeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return dir.appendingPathComponent("Tapdeck-\(fmt.string(from: Date())).mov")
    }
}

// MARK: - Delegates

extension Recorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.status = "ストリームが停止しました: \(error.localizedDescription)"
            self.isRecording = false
            self.ticker?.invalidate()
        }
    }
}

extension Recorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.status = "収録開始" }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            self.status = "書き出し失敗: \(error.localizedDescription)"
            self.isRecording = false
            self.ticker?.invalidate()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.status = "書き出し完了: \(self.lastOutput?.lastPathComponent ?? "")" }
    }
}
