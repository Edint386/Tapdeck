import SwiftUI

/// Settings pane: the virtual devices the driver publishes.
struct VirtualDevicesSettingsView: View {
    @EnvironmentObject private var model: AudioEngineModel
    @State private var newDeviceName = ""
    @State private var newDeviceChannels = 2
    @State private var isAddingDevice = false

    var body: some View {
        ScrollView {
            virtualDeviceSection
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { model.refresh() }
    }

    // MARK: Virtual devices

    private var virtualDeviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Virtual Devices").font(.headline)
                Spacer()
                Button {
                    newDeviceName = ""
                    newDeviceChannels = 2
                    isAddingDevice = true
                } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .disabled(model.virtualDevices.count >= 8)
                .help("Add a virtual device")
                Button("Refresh") { model.refresh() }
                    .controlSize(.small)
                    .disabled(model.isTesting)
            }

            if model.tapdeck == nil && model.virtualDevices.count <= 1 {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text("The driver is not installed.").font(.callout)
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

            Text("Keep a separate device per purpose — Meetings, Streaming, and so on.\nChanges take effect right away.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let status = model.virtualDeviceStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .popover(isPresented: $isAddingDevice, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Device name").font(.subheadline.weight(.medium))
                TextField("Meetings, Streaming, …", text: $newDeviceName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { commitNewDevice() }
                Picker("Channels", selection: $newDeviceChannels) {
                    Text("2 — stereo").tag(2)
                    Text("4 — two sources apart").tag(4)
                    Text("6 — three sources apart").tag(6)
                    Text("8 — four sources apart").tag(8)
                    Text("16").tag(16)
                }
                .frame(width: 220)
                HStack {
                    Spacer()
                    Button("Cancel") { isAddingDevice = false }
                    Button("Add") { commitNewDevice() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newDeviceName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
            .appLanguage()
        }
    }

    private func commitNewDevice() {
        model.addVirtualDevice(name: newDeviceName, channels: newDeviceChannels)
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
                Text("in \(live.inputChannels)ch / out \(live.outputChannels)ch / \(Int(live.sampleRate)) Hz")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            } else {
                Text("pending").font(.system(size: 9)).foregroundStyle(.tertiary)
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

}

/// Settings pane: checks that the virtual devices and capture paths work, and
/// every audio device the system can see.
struct DiagnosticsSettingsView: View {
    @EnvironmentObject private var model: AudioEngineModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                loopbackSection
                Divider()
                deviceListSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { model.refresh() }
    }

    // MARK: Loopback check

    private var loopbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loopback Check").font(.headline)
            Text("Sends 440 Hz into the virtual device's output and checks that it can be read back from the same device's input.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    Task { await model.runLoopbackTest() }
                } label: {
                    let title: LocalizedStringKey = model.isTesting ? "Checking…" : "Run Check"
                    Label(title, systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.isTesting || model.tapdeck == nil)

                if model.isTesting { ProgressView().controlSize(.small) }
            }
            .controlSize(.large)

            if model.receivedSamples > 0 {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Samples").foregroundStyle(.secondary)
                        Text("\(model.receivedSamples)")
                            .font(.system(.caption, design: .monospaced))
                    }
                    GridRow {
                        Text("Peak").foregroundStyle(.secondary)
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
                            Text("File").foregroundStyle(.secondary)
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
                    let title: LocalizedStringKey = model.isMonitoring ? "Recording…" : "Record the Input"
                    Label(title, systemImage: "waveform.badge.mic")
                }
                .disabled(model.isMonitoring || model.isTesting || model.tapdeck == nil)
                if model.isMonitoring { ProgressView().controlSize(.small) }
            }
            if let status = model.monitorStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
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

    // MARK: Device list

    private var deviceListSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio Devices").font(.headline)
            VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.devices) { device in
                        HStack(spacing: 8) {
                            Text(device.name).frame(width: 240, alignment: .leading).lineLimit(1)
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
    }
}
