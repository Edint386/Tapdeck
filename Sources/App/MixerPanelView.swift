import SwiftUI

/// Every mix down the side, the selected one on the right.
struct MixerPanelView: View {
    @EnvironmentObject private var model: MixerModel
    @EnvironmentObject private var menuBar: MenuBarController

    var body: some View {
        HStack(spacing: 0) {
            MixListView()
                .frame(width: 210)
            Divider()
            if let mix = model.selectedMix {
                MixEditorView(mix: mix)
                    .id(mix.id)
            } else {
                VStack(spacing: 10) {
                    Text("No mixes").foregroundStyle(.secondary)
                    Button("New Mix") { model.addMix() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { model.refresh() }
    }
}

// MARK: - The list of mixes

private struct MixListView: View {
    @EnvironmentObject private var model: MixerModel
    @EnvironmentObject private var menuBar: MenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Mixes").font(.headline)
                Spacer()
                let virtual = model.availableInputs.filter { MixerModel.isVirtual($0.uid) }
                if !virtual.isEmpty {
                    Menu {
                        Section("Listen to a virtual device") {
                            ForEach(virtual) { device in
                                Button(device.name) { model.addMonitor(for: device) }
                            }
                        }
                    } label: {
                        Image(systemName: "headphones")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Hear what apps are playing into a Tapdeck device")
                }
                Button {
                    model.addMix()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New mix")
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.mixes) { mix in
                        MixListRow(mix: mix, isSelected: mix.id == model.selectedMix?.id)
                            .onTapGesture { model.selectedMixID = mix.id }
                            .contextMenu {
                                Button(mix.isRunning ? "Stop" : "Start") { mix.toggleRunning() }
                                Button("Duplicate") { model.duplicate(mix.id) }
                                Divider()
                                Button("Delete", role: .destructive) { model.delete(mix.id) }
                            }
                    }
                }
            }

            Spacer(minLength: 0)

            Text("Every mix runs on its own. Start as many as you need at once.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !menuBar.isPlaced {
                Label("No room in the menu bar for Tapdeck. A notched display leaves only a narrow strip for status items.",
                      systemImage: "menubar.arrow.up.rectangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }
}

private struct MixListRow: View {
    @ObservedObject var mix: MixSession
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                mix.toggleRunning()
            } label: {
                Image(systemName: mix.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(mix.isRunning ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(mix.isRunning ? "Stop this mix" : "Start this mix")

            VStack(alignment: .leading, spacing: 3) {
                Text(mix.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(mix.outputSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                LevelBar(level: mix.level).frame(height: 3)
                    .opacity(mix.isRunning ? 1 : 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

// MARK: - Editing one mix

private struct MixEditorView: View {
    @EnvironmentObject private var model: MixerModel
    @ObservedObject var mix: MixSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sourcesSection
                    outputsSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Mix name", text: $mix.name)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))

            LevelBar(level: mix.level).frame(width: 90, height: 6)

            Button {
                model.duplicate(mix.id)
            } label: { Image(systemName: "plus.square.on.square") }
            .buttonStyle(.borderless)
            .help("Duplicate this mix")

            Button {
                model.delete(mix.id)
            } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help("Delete this mix")

            Button {
                mix.toggleRunning()
            } label: {
                Label(mix.isRunning ? "Stop" : "Start",
                      systemImage: mix.isRunning ? "stop.fill" : "play.fill")
                    .frame(width: 70)
            }
            .buttonStyle(.borderedProminent)
            .tint(mix.isRunning ? .red : .accentColor)
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Sources").font(.headline)
                Text("where the audio comes from")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                HStack(spacing: 5) {
                    Button("System") { mix.addSystemAudio() }
                    Button("Mic") { mix.addDefaultMicrophone() }
                    Button("Playing") { mix.addPlayingApplications() }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                sourceMenu
            }

            if mix.sources.isEmpty {
                Text("No sources. Add System and Mic to share your computer audio and your microphone together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(mix.sources) { sourceRow($0) }
                }
            }

            if mix.channelPairs.count > 1 && !mix.sources.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("The main output has \(mix.outputChannelCount) channels, so each source can take its own pair.",
                          systemImage: "square.split.2x1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Separate") { mix.spreadAcrossChannels() }
                        .controlSize(.small)
                        .disabled(mix.isRunning)
                        .help("Give every source its own channel pair")
                }
            }
        }
    }

    private var sourceMenu: some View {
        Menu {
            Menu("Application") {
                ForEach(model.availableProcesses) { process in
                    Button(process.isPlayingAudio ? "♪  \(process.name)" : process.name) {
                        mix.addApplication(process)
                    }
                }
            }
            Menu("Input Device") {
                ForEach(model.availableInputs) { device in
                    Button("\(device.name) (\(device.inputChannels)ch)") { mix.addInput(device) }
                }
            }
            Divider()
            Button("Refresh Lists") { model.refresh() }
            Button("Remove All Sources") { mix.removeAllSources() }
                .disabled(mix.sources.isEmpty)
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func sourceRow(_ row: MixSession.SourceRow) -> some View {
        HStack(spacing: 10) {
            sourceIcon(row)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.label).font(.callout.weight(.medium)).lineLimit(1)
                    if mix.isRunning && !row.isAttached {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Text(row.detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(row.gain) },
                                          set: { mix.setSourceGain(Float($0), for: row.id) }),
                           in: 0...2)
                        .controlSize(.mini)
                        .disabled(row.isMuted)
                    Text(gainLabel(row.gain))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                    if mix.channelPairs.count > 1 {
                        Menu {
                            ForEach(mix.channelPairs, id: \.self) { offset in
                                Button {
                                    mix.setChannelOffset(offset, for: row.id)
                                } label: {
                                    if offset == row.channelOffset {
                                        Label(pairLabel(offset), systemImage: "checkmark")
                                    } else {
                                        Text(pairLabel(offset))
                                    }
                                }
                            }
                        } label: {
                            Text(pairLabel(row.channelOffset))
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Which channels of the main output this source is placed on")
                    }
                    LevelBar(level: row.isMuted ? 0 : row.level).frame(width: 60, height: 4)
                }
            }

            muteButton(isMuted: row.isMuted) { mix.toggleSourceMute(row.id) }
            removeButton("Remove this source") { mix.removeSource(row.id) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(mix.isRunning && !row.isAttached ? Color.orange.opacity(0.45) : .clear))
        .opacity(row.isMuted ? 0.55 : 1)
    }

    @ViewBuilder
    private func sourceIcon(_ row: MixSession.SourceRow) -> some View {
        if let appIcon = row.appIcon {
            Image(nsImage: appIcon).resizable().frame(width: 24, height: 24)
        } else {
            Image(systemName: row.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: Outputs

    private var outputsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Outputs").font(.headline)
                Text("where the mix goes")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    mix.addListeningOutput()
                } label: {
                    Label("Hear It", systemImage: "headphones")
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(model.defaultOutputDevice.map { d in mix.outputs.contains { $0.deviceUID == d.uid } } ?? true)
                .help("Also play this mix to your speakers or headphones, so you hear what you are sending")
                outputMenu
            }

            if mix.outputs.isEmpty {
                Text("No outputs. Add a Tapdeck device so other apps can pick up this mix, and Hear It to listen along.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(mix.outputs) { outputRow($0) }
                }
            }

            if mix.outputs.contains(where: { MixerModel.isVirtual($0.deviceUID) }) {
                Label("Choose a Tapdeck device as the microphone in Zoom, OBS or a recorder and it receives this mix.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var outputMenu: some View {
        Menu {
            let used = Set(mix.outputs.map(\.deviceUID))
            let virtual = model.outputCandidates.filter { MixerModel.isVirtual($0.uid) && !used.contains($0.uid) }
            let hardware = model.outputCandidates.filter { !MixerModel.isVirtual($0.uid) && !used.contains($0.uid) }
            if !virtual.isEmpty {
                Section("Virtual devices") {
                    ForEach(virtual) { device in
                        Button("\(device.name) (\(device.outputChannels)ch)") { mix.addOutput(device) }
                    }
                }
            }
            if !hardware.isEmpty {
                Section("Speakers and interfaces") {
                    ForEach(hardware) { device in
                        Button("\(device.name) (\(device.outputChannels)ch)") { mix.addOutput(device) }
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

    private func outputRow(_ row: MixSession.OutputRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: MixerModel.isVirtual(row.deviceUID) ? "arrow.triangle.branch" : "hifispeaker.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                    if row.isPrimary {
                        Text("MAIN")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.25), in: Capsule())
                            .help("The main output's clock drives the mix, and channel placement refers to its channels.")
                    }
                    if mix.isRunning && !row.isAttached {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Text(row.detail)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { Double(row.gain) },
                                          set: { mix.setOutputGain(Float($0), for: row.id) }),
                           in: 0...2)
                        .controlSize(.mini)
                        .disabled(row.isMuted)
                    Text(gainLabel(row.gain))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                    LevelBar(level: row.isMuted ? 0 : row.level).frame(width: 60, height: 4)
                }
            }

            if !row.isPrimary {
                Button {
                    mix.makePrimary(row.id)
                } label: {
                    Image(systemName: "arrow.up.to.line").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Make this the main output")
            }
            muteButton(isMuted: row.isMuted) { mix.toggleOutputMute(row.id) }
            removeButton("Remove this output") { mix.removeOutput(row.id) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(mix.isRunning && !row.isAttached ? Color.orange.opacity(0.45) : .clear))
        .opacity(row.isMuted ? 0.55 : 1)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(mix.status.isEmpty ? " " : mix.status)
                .font(.caption)
                .foregroundStyle(mix.status.hasPrefix("This would feed back") ? Color.orange : .secondary)
                .lineLimit(2)
            Spacer()
            Button {
                model.refresh()
            } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.borderless)
            .help("Refresh the device and application lists")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Small pieces

    private func muteButton(isMuted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(isMuted ? Color.red : Color.secondary)
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .help(isMuted ? "Unmute" : "Mute")
    }

    private func removeButton(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.caption2).foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func pairLabel(_ offset: Int) -> String { "ch \(offset + 1)–\(offset + 2)" }

    private func gainLabel(_ gain: Float) -> String {
        guard gain > 0.001 else { return "−∞" }
        return String(format: "%+.1f", 20 * log10(gain))
    }
}

/// A level meter. Using amplitude directly makes quiet audio invisible, so it
/// converts to dB and maps -60 dB to 0 dB across the full width.
struct LevelBar: View {
    let level: Float

    private var fraction: Double {
        guard level > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(level)) + 60) / 60))
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
