import SwiftUI

struct AudioPanelView: View {
    @EnvironmentObject private var model: AudioEngineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            virtualDeviceSection
            Divider()
            loopbackSection
            Divider()
            deviceListSection
        }
        .padding(18)
        .frame(width: 460)
        .task { model.refresh() }
    }

    // MARK: 仮想デバイス

    private var virtualDeviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("仮想デバイス").font(.headline)
                Spacer()
                Button("更新") { model.refresh() }
                    .controlSize(.small)
                    .disabled(model.isTesting)
            }

            if let device = model.tapdeck {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(device.name) — 入力 \(device.inputChannels)ch / 出力 \(device.outputChannels)ch / \(Int(device.sampleRate)) Hz")
                        .font(.callout)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text("見つかりません。ドライバが未インストールです。").font(.callout)
                }
                Text("sudo cp -R build/Tapdeck.driver /Library/Audio/Plug-Ins/HAL/\nsudo killall coreaudiod")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: ループバック検証

    private var loopbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ループバック検証").font(.headline)
            Text("仮想デバイスの出力側に 440Hz を流し、同じデバイスの入力側から読み返せるかを確かめます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    Task { await model.runLoopbackTest() }
                } label: {
                    Label(model.isTesting ? "検証中 …" : "検証を実行",
                          systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.isTesting || model.tapdeck == nil)

                if model.isTesting { ProgressView().controlSize(.small) }
            }
            .controlSize(.large)

            if model.receivedSamples > 0 {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("取得サンプル数").foregroundStyle(.secondary)
                        Text("\(model.receivedSamples)")
                            .font(.system(.caption, design: .monospaced))
                    }
                    GridRow {
                        Text("ピーク").foregroundStyle(.secondary)
                        Text(String(format: "%.1f dB", model.peakDB))
                            .font(.system(.caption, design: .monospaced))
                    }
                    GridRow {
                        Text("RMS").foregroundStyle(.secondary)
                        Text(String(format: "%.1f dB", model.rmsDB))
                            .font(.system(.caption, design: .monospaced))
                    }
                    if model.capturedFile != nil {
                        GridRow {
                            Text("録音").foregroundStyle(.secondary)
                            Text("loopback-test.wav")
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                .font(.caption)
            }

            HStack(spacing: 6) {
                switch model.verdict {
                case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .unknown: EmptyView()
                }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: デバイス一覧

    private var deviceListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("オーディオデバイス").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.devices) { device in
                        HStack(spacing: 8) {
                            Text(device.name).frame(width: 200, alignment: .leading)
                            Text("in \(device.inputChannels)")
                                .foregroundStyle(device.canInput ? .primary : .tertiary)
                            Text("out \(device.outputChannels)")
                                .foregroundStyle(device.canOutput ? .primary : .tertiary)
                            Text("\(Int(device.sampleRate)) Hz").foregroundStyle(.secondary)
                        }
                        .font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .frame(height: 92)
        }
    }
}
