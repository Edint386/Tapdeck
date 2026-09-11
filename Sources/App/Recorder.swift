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

    // MARK: - 音源の選択

    /// 収録に乗せる音をどこから取るか。
    ///
    /// ScreenCaptureKit の SCRecordingOutput は音声も面倒を見てくれるが、
    /// 音源が「システム音声」と「マイク」に固定される。ミキサーで組んだ音を
    /// 乗せたい場合は、映像と音声を自前で多重化する必要がある。
    static let screenCaptureKitSourceID = ""

    @Published private(set) var audioDeviceOptions: [AudioDevice] = []
    @Published var audioSourceID = Recorder.screenCaptureKitSourceID

    var usesMixerOutput: Bool { audioSourceID != Self.screenCaptureKitSourceID }

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
    private var deviceInput: DeviceInput?
    private let muxerBox = MuxerBox()
    private let videoQueue = DispatchQueue(label: "dev.kosuke.Tapdeck.recorder.video",
                                           qos: .userInitiated)
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

            audioDeviceOptions = ((try? AudioDevice.all()) ?? []).filter(\.canInput)
            if audioSourceID != Self.screenCaptureKitSourceID,
               !audioDeviceOptions.contains(where: { $0.uid == audioSourceID }) {
                audioSourceID = Self.screenCaptureKitSourceID
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
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)

            if usesMixerOutput {
                // 映像は SCStream から受け取り、音声は指定デバイスから取って
                // AVAssetWriter で多重化する。
                guard let device = audioDeviceOptions.first(where: { $0.uid == audioSourceID })
                else { throw Failure.noTarget }

                cfg.capturesAudio = false
                cfg.captureMicrophone = false

                let input = try DeviceInput(device: device)
                let muxer = try MuxedRecorder(outputURL: url,
                                              videoSize: CGSize(width: w, height: h),
                                              audioFormat: input.format)
                muxer.start()
                muxerBox.value = muxer

                try input.start { [muxerBox] buffer, timeStamp in
                    muxerBox.value?.appendAudio(buffer, at: timeStamp)
                }
                deviceInput = input

                try s.addStreamOutput(self, type: .screen,
                                      sampleHandlerQueue: videoQueue)
                try await s.startCapture()
            } else {
                let rcfg = SCRecordingOutputConfiguration()
                rcfg.outputURL = url
                rcfg.outputFileType = .mov
                rcfg.videoCodecType = .h264

                let out = SCRecordingOutput(configuration: rcfg, delegate: self)
                try s.addRecordingOutput(out)
                try await s.startCapture()
                output = out
            }

            stream = s
            lastOutput = url
            outputSize = CGSize(width: w, height: h)
            startedAt = Date()
            elapsed = 0
            isRecording = true
            status = usesMixerOutput
                ? "収録中 — \(w)×\(h) @ \(fps)fps / 音声は \(audioSourceName)"
                : "収録中 — \(w)×\(h) @ \(fps)fps / 音声は ScreenCaptureKit"
            startTicker()
        } catch {
            status = "開始できませんでした: \(error.localizedDescription)"
        }
    }

    var audioSourceName: String {
        audioDeviceOptions.first { $0.uid == audioSourceID }?.name ?? "—"
    }

    func stop() async {
        guard let s = stream else { return }
        do {
            try await s.stopCapture()
        } catch {
            status = "停止時にエラー: \(error.localizedDescription)"
        }

        deviceInput?.stop()
        deviceInput = nil

        if let muxer = muxerBox.value {
            await muxer.finish()
            muxerBox.value = nil
            if let failure = muxer.failure {
                status = "書き出しに失敗: \(failure.localizedDescription)"
            } else {
                status = "保存しました: \(lastOutput?.lastPathComponent ?? "")"
            }
        } else {
            status = "保存しました: \(lastOutput?.lastPathComponent ?? "")"
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


/// 実時間のコールバックから多重化器へ届けるための受け皿。
/// SCStreamOutput も AUHAL も MainActor の外から呼ばれる。
final class MuxerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: MuxedRecorder?

    var value: MuxedRecorder? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

extension Recorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .screen else { return }

        // 画面に変化が無い周期でも呼ばれる。完成フレーム以外は捨てる。
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }

        muxerBox.value?.appendVideo(sampleBuffer)
    }
}
