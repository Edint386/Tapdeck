import SwiftUI

struct RecorderPanelView: View {
    @EnvironmentObject private var rec: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            targetSection
            Divider()
            videoSection
            Divider()
            audioSection
            Divider()
            controlSection
        }
        .padding(18)
        .frame(width: 460)
        .task { await rec.refreshContent() }
    }

    // MARK: 収録対象

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("収録対象").font(.headline)
                Spacer()
                Button("更新") { Task { await rec.refreshContent() } }
                    .controlSize(.small)
                    .disabled(rec.isRecording)
            }
            Picker("", selection: $rec.selectedID) {
                if !rec.displayOptions.isEmpty {
                    Section("ディスプレイ") {
                        ForEach(rec.displayOptions) { Text($0.label).tag($0.id) }
                    }
                }
                if !rec.appOptions.isEmpty {
                    Section("アプリケーション") {
                        ForEach(rec.appOptions) { Text($0.label).tag($0.id) }
                    }
                }
                if !rec.windowOptions.isEmpty {
                    Section("ウインドウ") {
                        ForEach(rec.windowOptions) { Text($0.label).tag($0.id) }
                    }
                }
            }
            .labelsHidden()
            .disabled(rec.isRecording)
            .onChange(of: rec.selectedID) { rec.updateOutputSize() }
        }
    }

    // MARK: 映像

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("映像").font(.headline)

            HStack {
                Text("解像度").frame(width: 64, alignment: .leading)
                Picker("", selection: $rec.scalePercent) {
                    Text("100% (等倍)").tag(100)
                    Text("75%").tag(75)
                    Text("50%").tag(50)
                    Text("25%").tag(25)
                }
                .labelsHidden()
                .onChange(of: rec.scalePercent) { rec.updateOutputSize() }
                Text(rec.outputSize == .zero
                     ? "—"
                     : "\(Int(rec.outputSize.width))×\(Int(rec.outputSize.height)) px")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("フレーム").frame(width: 64, alignment: .leading)
                Picker("", selection: $rec.fps) {
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                    Text("24 fps").tag(24)
                    Text("15 fps").tag(15)
                }
                .labelsHidden()
            }

            Toggle("マウスカーソルを含める", isOn: $rec.showsCursor)
        }
        .disabled(rec.isRecording)
    }

    // MARK: 音声

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("音声").font(.headline)

            HStack {
                Text("音源").frame(width: 64, alignment: .leading)
                Picker("", selection: $rec.audioSourceID) {
                    Text("ScreenCaptureKit（システム音声・マイク）")
                        .tag(Recorder.screenCaptureKitSourceID)
                    if !rec.audioDeviceOptions.isEmpty {
                        Divider()
                        ForEach(rec.audioDeviceOptions) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
                .labelsHidden()
            }

            if rec.usesMixerOutput {
                Label("「Tapdeck」を選ぶと、ミキサーで組んだ音がそのまま収録に乗ります。",
                      systemImage: "slider.vertical.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle("システム音声（Macで鳴っている音）", isOn: $rec.systemAudio)
                Toggle("マイク", isOn: $rec.microphone)
                Text("仮想オーディオデバイスは不要です。ScreenCaptureKit が直接取得します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(rec.isRecording)
    }

    // MARK: 操作

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if rec.isRecording {
                    Button {
                        Task { await rec.stop() }
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        Task { await rec.start() }
                    } label: {
                        Label("収録開始", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(rec.selectedID.isEmpty)
                }

                Text(Self.timecode(rec.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(rec.isRecording ? .red : .secondary)
                    .frame(width: 90, alignment: .trailing)
            }
            .controlSize(.large)

            HStack {
                Text(rec.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if rec.lastOutput != nil && !rec.isRecording {
                    Button("Finderで表示") { rec.revealLastOutput() }
                        .controlSize(.small)
                }
            }
        }
    }

    static func timecode(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
