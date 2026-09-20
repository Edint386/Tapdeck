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

            MasterVolumeControl()
                .padding(.vertical, 4)

            Text("Every mix runs on its own. Start as many as you need at once.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !menuBar.isPlaced {
                HStack(spacing: 6) {
                    Label("No free space in the menu bar", systemImage: "menubar.arrow.up.rectangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button("Panel") { menuBar.toggleMiniPanel() }
                        .controlSize(.mini)
                }
                .help("macOS places status items in the strip right of the notch and keeps Tapdeck's icon off screen once other apps have filled it, so it cannot be clicked — not even by tools that tidy the menu bar, since it was never placed. It appears as soon as room frees up: hold Command and drag another icon out of the menu bar. Meanwhile, use this floating panel or the Dock menu.")
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
    /// Outputs whose delay control is open. An output with a delay set is
    /// always shown open, so the setting is never hidden.
    @State private var openDelays: Set<UUID> = []
    /// The source whose effects popover is open.
    @State private var effectsSourceID: UUID?

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

    /// What mix-level normalisation is doing, in one short line. Kept as a
    /// space when there is nothing to say, so the header does not jump.
    private var loudnessCaption: String {
        guard mix.normalizesLoudness, mix.isRunning else { return " " }
        return LoudnessReading.caption(mix.loudnessReading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Mix name", text: $mix.name)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))

            VStack(spacing: 2) {
                Toggle(isOn: $mix.normalizesLoudness) {
                    // Icon only: the header is tight, and the tooltip explains it.
                    Image(systemName: "waveform")
                        .frame(width: 18)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Even out loudness: bring everything this mix plays to the loudness set in Settings › Audio, so one video, site or song is about as loud as the next")
                Text(loudnessCaption)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .trailing, spacing: 3) {
                VolumeControl(title: nil, volume: $mix.volume, isMuted: $mix.isMuted)
                    .frame(width: 210)
                    .help("This mix's volume, for everything it sends")
                LevelBar(level: mix.level).frame(width: 150, height: 4)
            }

            RecordButton(mix: mix)

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
                    if row.replacesOriginal {
                        Text("REPLACES")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.25), in: Capsule())
                            .help("The app's own sound is silenced while this mix runs")
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
                                          set: { mix.setSourceGain(Float($0), for: row.id) }),
                           in: 0...1)
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

            Button {
                effectsSourceID = row.id
            } label: {
                Text("FX")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .foregroundStyle(row.effects.isActive ? Color.white : Color.secondary)
                    .background(row.effects.isActive ? Color.accentColor : Color.secondary.opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Filters, equaliser, dynamics and more for this source")
            .popover(isPresented: Binding(get: { effectsSourceID == row.id },
                                          set: { if !$0 { effectsSourceID = nil } }),
                     arrowEdge: .trailing) {
                SourceEffectsView(mix: mix, sourceID: row.id)
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

            if mix.suggestedOutputDelays != nil && !mix.outputsAreLinedUp {
                lineUpHint
            }

            if mix.outputs.contains(where: { $0.transport == .airPlay }) {
                HStack(spacing: 6) {
                    Label("While this mix runs, AirPlay becomes the Mac's output and apps are heard only through the mix. The receiver is chosen in Control Center › Sound.",
                          systemImage: "airplayaudio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Sound Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
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

    /// Offered when a wireless output plays behind the other speakers.
    private var lineUpHint: some View {
        let slowest = mix.outputs.max { $0.transport.typicalLatencyMilliseconds < $1.transport.typicalLatencyMilliseconds }
        let name = slowest?.transport == .airPlay ? "AirPlay" : "Bluetooth"
        let seconds = (slowest?.transport.typicalLatencyMilliseconds ?? 0) / 1000
        return HStack(spacing: 8) {
            Label(String(format: "%@ usually plays about %@ behind the other speakers, which sounds like an echo.",
                         name, seconds >= 1 ? String(format: "%.0f s", seconds) : String(format: "%.0f ms", seconds * 1000)),
                  systemImage: "clock.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Line Up") { mix.lineUpOutputs() }
                .controlSize(.small)
                .help("Delay the other speakers by the typical difference. Fine-tune each by ear afterwards.")
        }
        .padding(8)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func outputSymbol(_ row: MixSession.OutputRow) -> String {
        if MixerModel.isVirtual(row.deviceUID) { return "arrow.triangle.branch" }
        switch row.transport {
        case .airPlay:   return "airplayaudio"
        case .bluetooth: return "headphones"
        default:         return "hifispeaker.fill"
        }
    }

    private var outputMenu: some View {
        Menu {
            let used = Set(mix.outputs.map(\.deviceUID))
            let available = model.outputCandidates.filter { !used.contains($0.uid) }
            let virtual = available.filter { MixerModel.isVirtual($0.uid) }
            let wireless = available.filter { !MixerModel.isVirtual($0.uid) && $0.transport.isWireless }
            let hardware = available.filter { !MixerModel.isVirtual($0.uid) && !$0.transport.isWireless }
            if !virtual.isEmpty {
                Section("Virtual devices") {
                    ForEach(virtual) { device in
                        Button("\(device.name) (\(device.outputChannels)ch)") { mix.addOutput(device) }
                    }
                }
            }
            if !wireless.isEmpty {
                Section("AirPlay and Bluetooth") {
                    ForEach(wireless) { device in
                        Button("\(device.name) — \(device.transport == .airPlay ? "AirPlay" : "Bluetooth")") {
                            mix.addOutput(device)
                        }
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
            Image(systemName: outputSymbol(row))
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
                    if let deviceVolume = row.deviceVolume {
                        // The device's own volume: really louder when raised,
                        // and never distorting.
                        Slider(value: Binding(get: { Double(deviceVolume) },
                                              set: { mix.setDeviceVolume(Float($0), for: row.id) }),
                               in: 0...1)
                            .controlSize(.mini)
                            .help("The device's own volume, the one the volume keys change when it is the Mac's output. Every app playing to it hears the change.")
                        Text(row.isDeviceMuted ? "muted" : "\(Int((deviceVolume * 100).rounded()))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(row.isDeviceMuted ? Color.orange : .secondary)
                            .frame(width: 38, alignment: .trailing)
                    } else {
                        Slider(value: Binding(get: { Double(row.gain) },
                                              set: { mix.setOutputGain(Float($0), for: row.id) }),
                               in: 0...1)
                            .controlSize(.mini)
                            .disabled(row.isMuted)
                            .help(MixerModel.isVirtual(row.deviceUID)
                                  ? "Level of this mix on the virtual device. It has no volume of its own."
                                  : "Level of this mix on the device. Its own volume is not available right now.")
                        Text(gainLabel(row.gain))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    LevelBar(level: row.isMuted ? 0 : row.level).frame(width: 60, height: 4)
                    LimitBadge(decibels: row.limiting)
                }
                if hasOutputSettings(row) || openDelays.contains(row.id) {
                    delayControl(row)
                }
            }

            Button {
                if openDelays.contains(row.id) { openDelays.remove(row.id) } else { openDelays.insert(row.id) }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(hasOutputSettings(row) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(row.deviceVolume != nil
                  ? "Delay and level for this output"
                  : "Delay this output to line it up with a slower one")

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

    /// Whether an output has a delay or a level trim set, so its settings stay
    /// in view.
    private func hasOutputSettings(_ row: MixSession.OutputRow) -> Bool {
        row.delayMilliseconds > 0 || (row.deviceVolume != nil && row.gain < 1)
    }

    private func delayControl(_ row: MixSession.OutputRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if row.deviceVolume != nil {
                HStack(spacing: 8) {
                    Text("Level")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                    Slider(value: Binding(get: { Double(row.gain) },
                                          set: { mix.setOutputGain(Float($0), for: row.id) }),
                           in: 0...1)
                        .controlSize(.mini)
                        .help("This mix's level on the device, against other apps playing there. The fader above is the device's own volume.")
                    Text(gainLabel(row.gain))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(row.gain < 1 ? .primary : .secondary)
                        .frame(width: 50, alignment: .trailing)
                }
            }
            HStack(spacing: 8) {
                Text("Delay")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
                Slider(value: Binding(get: { row.delayMilliseconds },
                                      set: { mix.setOutputDelay($0, for: row.id) }),
                       in: 0...Mixer.Output.maximumDelayMilliseconds)
                    .controlSize(.mini)
                // Coarse slider, fine buttons: aligning by ear needs 5 ms steps.
                Button { mix.setOutputDelay(row.delayMilliseconds - 5, for: row.id) } label: {
                    Image(systemName: "minus").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("5 ms less")
                Text("\(Int(row.delayMilliseconds)) ms")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(row.delayMilliseconds > 0 ? .primary : .secondary)
                    .frame(width: 50, alignment: .trailing)
                Button { mix.setOutputDelay(row.delayMilliseconds + 5, for: row.id) } label: {
                    Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("5 ms more")
                Menu {
                    Button("None") { mix.setOutputDelay(0, for: row.id) }
                    Button("Bluetooth, roughly 150 ms") { mix.setOutputDelay(150, for: row.id) }
                    Button("AirPlay, roughly 2000 ms") { mix.setOutputDelay(2000, for: row.id) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.caption)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Starting points; fine-tune by ear")
            }
            Text(delayHint(row))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private func delayHint(_ row: MixSession.OutputRow) -> String {
        var hint = "Delay the faster outputs until the echo between them disappears."
        if let reported = row.reportedLatencyMilliseconds {
            hint += String(format: " This device reports %.0f ms of its own; wireless devices often report less than they add.",
                           reported)
        }
        return hint
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
/// Shows while an output's limiter is holding peaks down. Space is always
/// reserved so the row does not shift when it appears.
struct LimitBadge: View {
    let decibels: Double

    var body: some View {
        Text("LIMIT")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.orange, in: Capsule())
            .opacity(decibels > 0.3 ? 1 : 0)
            .help(String(format: "Tapdeck is turning peaks down by %.1f dB here so they do not distort. "
                         + "To avoid it, turn a source or the mix down, or turn the device volume up.", decibels))
            .accessibilityHidden(decibels <= 0.3)
    }
}

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
