import SwiftUI

struct MixerPanelView: View {
    @EnvironmentObject private var model: MixerModel
    @EnvironmentObject private var menuBar: MenuBarController
    @State private var isNamingPreset = false
    @State private var presetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sourcesSection
            Divider()
            footer
        }
        .frame(width: 500)
        .task { model.refresh() }
    }

    // MARK: Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            presetBar
            HStack(spacing: 8) {
                Text("Sources").font(.headline)
                if !model.rows.isEmpty {
                    Text("\(model.rows.count)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                quickAddButtons
                addMenu
            }

            if model.rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.rows) { sourceRow($0) }
                    }
                    .padding(.bottom, 2)
                }
                .frame(height: 218)
            }
        }
        .padding(18)
    }

    /// Presets, for switching between setups.
    private var presetBar: some View {
        HStack(spacing: 8) {
            Menu {
                if model.presets.isEmpty {
                    Text("No saved presets")
                } else {
                    ForEach(model.presets) { preset in
                        Button {
                            model.applyPreset(preset.id)
                        } label: {
                            if model.activePresetID == preset.id {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
                        }
                    }
                    Divider()
                    Menu("Delete") {
                        ForEach(model.presets) { preset in
                            Button(preset.name) { model.deletePreset(preset.id) }
                        }
                    }
                }
                Divider()
                Button("Save Current Setup…") {
                    presetName = model.presets.first { $0.id == model.activePresetID }?.name ?? ""
                    isNamingPreset = true
                }
                .disabled(model.rows.isEmpty)
                Button("Remove All Sources") { model.clearSources() }
                    .disabled(model.rows.isEmpty)
            } label: {
                Label(activePresetLabel, systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()
        }
        .popover(isPresented: $isNamingPreset, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Preset name").font(.subheadline.weight(.medium))
                TextField("Meetings, Streaming, …", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { commitPreset() }
                HStack {
                    Spacer()
                    Button("Cancel") { isNamingPreset = false }
                    Button("Save") { commitPreset() }
                        .buttonStyle(.borderedProminent)
                        .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
        }
    }

    private var activePresetLabel: String {
        model.presets.first { $0.id == model.activePresetID }?.name ?? "Presets"
    }

    private func commitPreset() {
        model.savePreset(named: presetName)
        isNamingPreset = false
    }

    private var quickAddButtons: some View {
        HStack(spacing: 5) {
            Button("System") { model.addSystemAudio() }
            Button("Mic")    { model.addDefaultMicrophone() }
            Button("Playing") { model.addPlayingApplications() }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    private var addMenu: some View {
        Menu {
            Menu("Application") {
                ForEach(model.availableProcesses) { process in
                    Button(process.isPlayingAudio ? "♪  \(process.name)" : process.name) {
                        model.addApplication(process)
                    }
                }
            }
            Menu("Input Device") {
                ForEach(model.availableInputs) { device in
                    Button("\(device.name)（\(device.inputChannels)ch）") {
                        model.addInput(device)
                    }
                }
            }
            Divider()
            Button("Refresh Lists") { model.refresh() }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No sources yet")
                .font(.callout).foregroundStyle(.secondary)
            Text("Add System and Mic to share your computer audio and your\nmicrophone together on a video call.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 218)
    }

    private func sourceRow(_ row: MixerModel.Row) -> some View {
        HStack(spacing: 10) {
            icon(for: row)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.label)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if model.isRunning && !row.isAttached {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Text(row.detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    Slider(value: Binding(
                        get: { Double(row.gain) },
                        set: { model.setGain(Float($0), for: row.id) }
                    ), in: 0...2)
                    .controlSize(.mini)
                    .disabled(row.isMuted)

                    Text(gainLabel(row.gain))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)

                    if model.channelPairs.count > 1 {
                        Menu {
                            ForEach(model.channelPairs, id: \.self) { offset in
                                Button {
                                    model.setChannelOffset(offset, for: row.id)
                                } label: {
                                    if offset == row.channelOffset {
                                        Label(Self.pairLabel(offset), systemImage: "checkmark")
                                    } else {
                                        Text(Self.pairLabel(offset))
                                    }
                                }
                            }
                        } label: {
                            Text(Self.pairLabel(row.channelOffset))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Which output channels this source is placed on")
                    }

                    LevelBar(level: row.isMuted ? 0 : row.level)
                        .frame(width: 64, height: 4)
                }
            }

            Button {
                model.toggleMute(row.id)
            } label: {
                Image(systemName: row.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(row.isMuted ? Color.red : Color.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .help(row.isMuted ? "Unmute" : "Mute")

            Button {
                model.remove(row.id)
            } label: {
                Image(systemName: "xmark").font(.caption2).foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Remove this source")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(model.isRunning && !row.isAttached
                              ? Color.orange.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .opacity(row.isMuted ? 0.55 : 1)
    }

    @ViewBuilder
    private func icon(for row: MixerModel.Row) -> some View {
        if let appIcon = row.appIcon {
            Image(nsImage: appIcon)
                .resizable().frame(width: 26, height: 26)
        } else {
            Image(systemName: row.symbolName)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    static func pairLabel(_ offset: Int) -> String {
        "ch \(offset + 1)–\(offset + 2)"
    }

    private func gainLabel(_ gain: Float) -> String {
        guard gain > 0.001 else { return "−∞" }
        return String(format: "%+.1f", 20 * log10(gain))
    }

    // MARK: Output and transport

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Output").font(.subheadline.weight(.medium))
                Picker("", selection: $model.outputDeviceUID) {
                    ForEach(model.outputCandidates) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .disabled(model.isRunning)
                .frame(maxWidth: 210)
                Spacer()
                Button {
                    model.refresh()
                } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh the device and application lists")
            }

            if model.channelPairs.count > 1 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("\(model.outputChannelCount) channels — each source can take its own pair, so recorders and OBS receive them as separate tracks.",
                          systemImage: "square.split.2x1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Separate") { model.spreadAcrossChannels() }
                        .controlSize(.small)
                        .disabled(model.rows.isEmpty || model.isRunning)
                        .help("Give every source its own channel pair")
                }
            } else if model.outputDeviceUID == "TapdeckDevice" {
                Label("Choose Tapdeck as the input in Zoom or OBS and it receives this mix.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button {
                    model.toggleRunning()
                } label: {
                    Label(model.isRunning ? "Stop" : "Start Mixing",
                          systemImage: model.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(model.isRunning ? .red : .accentColor)
                .disabled(model.rows.isEmpty)
                .keyboardShortcut("r", modifiers: .command)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Output level").font(.system(size: 9)).foregroundStyle(.secondary)
                    LevelBar(level: model.masterLevel).frame(width: 104, height: 6)
                }
            }

            if !menuBar.isPlaced {
                Label("The menu bar had no room for Tapdeck. A notched display leaves only a narrow strip for status items — remove a few and it will appear.",
                      systemImage: "menubar.arrow.up.rectangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
    }
}

/// A level meter. Using amplitude directly makes quiet audio invisible, so it
/// converts to dB and maps -60 dB to 0 dB across the full width.
struct LevelBar: View {
    let level: Float

    private var fraction: Double {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return min(1, max(0, (db + 60) / 60))
    }

    private var color: Color {
        fraction > 0.96 ? .red : (fraction > 0.82 ? .yellow : .green)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * fraction)
                    .animation(.linear(duration: 0.05), value: fraction)
            }
        }
    }
}
