import SwiftUI

struct AudioPanelView: View {
    @EnvironmentObject private var model: AudioEngineModel
    @State private var newDeviceName = ""
    @State private var isAddingDevice = false

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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("仮想デバイス").font(.headline)
                Spacer()
                Button {
                    newDeviceName = ""
                    isAddingDevice = true
                } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .disabled(model.virtualDevices.count >= 8)
                .help("仮想デバイスを追加")
                Button("更新") { model.refresh() }
                    .controlSize(.small)
                    .disabled(model.isTesting)
            }

            if model.tapdeck == nil && model.virtualDevices.count <= 1 {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text("ドライバが未インストールです。").font(.callout)
                }
                Text("sudo ./install-driver.sh")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                VStack(spacing: 4) {
                    ForEach(model.virtualDevices) { device in
                        virtualDeviceRow(device)
                    }
                }
            }

            Text("用途ごとにデバイスを分けられます（「Zoom用」「配信用」など）。\n追加・削除は数秒で反映されます。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.virtualDeviceStatus.isEmpty {
                Text(model.virtualDeviceStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        .popover(isPresented: $isAddingDevice, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("仮想デバイスの名前").font(.subheadline.weight(.medium))
                TextField("Zoom用 / 配信用 など", text: $newDeviceName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { commitNewDevice() }
                HStack {
                    Spacer()
                    Button("キャンセル") { isAddingDevice = false }
                    Button("追加") { commitNewDevice() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newDeviceName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
        }
    }

    private func commitNewDevice() {
        model.addVirtualDevice(name: newDeviceName)
        isAddingDevice = false
    }

    private func virtualDeviceRow(_ device: VirtualDeviceConfiguration.Device) -> some View {
        let live = model.devices.first { $0.uid == device.uid }
        return HStack(spacing: 8) {
            Image(systemName: live != nil ? "checkmark.circle.fill" : "clock")
                .font(.caption)
                .foregroundStyle(live != nil ? Color.green : Color.secondary)

            TextField("", text: Binding(
                get: { device.name },
                set: { model.renameVirtualDevice(id: device.id, to: $0) }
            ))
            .textFieldStyle(.plain)
            .font(.callout)

            if let live {
                Text("入力 \(live.inputChannels)ch / 出力 \(live.outputChannels)ch / \(Int(live.sampleRate)) Hz")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                Text("反映待ち").font(.system(size: 9)).foregroundStyle(.tertiary)
            }

            Button {
                model.removeVirtualDevice(id: device.id)
            } label: { Image(systemName: "xmark").font(.caption2).foregroundStyle(.tertiary) }
            .buttonStyle(.borderless)
            .disabled(model.virtualDevices.count <= 1)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
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

            Divider().padding(.vertical, 2)

            HStack(spacing: 10) {
                Button {
                    Task { await model.recordInput() }
                } label: {
                    Label(model.isMonitoring ? "録音中 …" : "入力をモニタ録音",
                          systemImage: "waveform.badge.mic")
                }
                .disabled(model.isMonitoring || model.isTesting || model.tapdeck == nil)
                if model.isMonitoring { ProgressView().controlSize(.small) }
            }
            if !model.monitorStatus.isEmpty {
                Text(model.monitorStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
