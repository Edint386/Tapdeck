import SwiftUI

struct RecorderPanelView: View {
    @EnvironmentObject private var rec: Recorder
    @EnvironmentObject private var mixer: MixerModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $rec.mode) {
                ForEach(Recorder.Mode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(rec.isRecording)

            if rec.mode == .audio {
                audioOnlySection
            } else {
                targetSection
                Divider()
                videoSection
                Divider()
                audioSection
                Divider()
                controlSection
            }
        }
        .padding(18)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await rec.refreshContent() }
    }

    // MARK: Audio only

    /// Recording a mix as an audio file. The same thing the record button in
    /// the mixer does, with the mix and the format in one place.
    private var audioOnlySection: some View {
        let recording = mixer.mixes.first { $0.isRecordingFile }
        let selected = recording ?? mixer.mixes.first { $0.id == rec.audioMixID } ?? mixer.mixes.first
        return VStack(alignment: .leading, spacing: 10) {
            Text("Audio").font(.headline)

            HStack {
                Text("Mix").frame(width: 64, alignment: .leading)
                Picker("", selection: Binding(get: { selected?.id ?? UUID() },
                                              set: { rec.audioMixID = $0 })) {
                    ForEach(mixer.mixes) { mix in
                        Text(mix.name.trimmingCharacters(in: .whitespaces).isEmpty
                             ? "Unnamed mix" : mix.name).tag(mix.id)
                    }
                }
                .labelsHidden()
                .disabled(recording != nil)
            }

            HStack {
                Text("Format").frame(width: 64, alignment: .leading)
                Picker("", selection: $settings.mixRecordingFormat) {
                    ForEach(MixRecorder.FileFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .labelsHidden()
                .disabled(recording != nil)
            }

            if settings.mixRecordingFormat.isLossy {
                HStack {
                    Text("Bitrate").frame(width: 64, alignment: .leading)
                    Picker("", selection: $settings.mixRecordingBitrate) {
                        ForEach(MixRecorder.bitrates, id: \.self) { rate in
                            Text("\(rate / 1000) kbps").tag(rate)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .disabled(recording != nil)
                    Text("MP3 is not offered: macOS has no MP3 encoder, and AAC sounds better at the same bitrate.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if settings.mixRecordingFormat.hasBitDepth {
                HStack {
                    Text("Depth").frame(width: 64, alignment: .leading)
                    Picker("", selection: $settings.mixRecordingBitDepth) {
                        ForEach(MixRecorder.bitDepths, id: \.self) { depth in
                            Text("\(depth)-bit").tag(depth)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .disabled(recording != nil)
                }
            }

            Text(selected.map { $0.isRecordingFile
                 ? "Recording what this mix plays."
                 : "Starts the mix if it is not running, then keeps what it plays." }
                 ?? "Make a mix first.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The monitor: what is going onto the file right now.
            if let selected {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("Level").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        LevelBar(level: selected.level).frame(height: 6)
                        Text(Self.decibels(selected.level))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(selected.level >= 0.99 ? Color.red : .secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                    HStack(spacing: 10) {
                        Text("File").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .leading)
                        Text(selected.isRecordingFile
                             ? "\(Self.size(selected.recordingSize)) so far"
                             : (selected.isRunning ? "Ready" : "Mix stopped"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            }

            HStack(spacing: 12) {
                Button {
                    guard let selected else { return }
                    if !selected.isRunning && !selected.isRecordingFile { selected.start() }
                    selected.toggleFileRecording()
                } label: {
                    Label(selected?.isRecordingFile == true ? "Stop" : "Start Recording",
                          systemImage: selected?.isRecordingFile == true ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(selected == nil)

                Text(RecordButton.timecode(selected?.recordingElapsed ?? 0))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(selected?.isRecordingFile == true ? .red : .secondary)
                    .frame(width: 90, alignment: .trailing)
            }

            if let url = selected?.lastRecordingURL {
                HStack(spacing: 6) {
                    Text("Saved \(url.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .controlSize(.small)
                }
            }
        }
    }

    static func decibels(_ level: Float) -> String {
        level > 0.0005 ? String(format: "%.1f dBFS", 20 * log10(Double(level))) : "−∞ dBFS"
    }

    static func size(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB"]
        var value = Double(bytes), unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return unit == 0 ? "\(Int(value)) bytes" : String(format: "%.1f %@", value, units[unit])
    }

    // MARK: Capture target

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Capture").font(.headline)
                Spacer()
                Button("Refresh") { Task { await rec.refreshContent() } }
                    .controlSize(.small)
                    .disabled(rec.isRecording)
            }
            Picker("", selection: $rec.selectedID) {
                if !rec.displayOptions.isEmpty {
                    Section("Displays") {
                        ForEach(rec.displayOptions) { Text($0.label).tag($0.id) }
                    }
                }
                if !rec.appOptions.isEmpty {
                    Section("Applications") {
                        ForEach(rec.appOptions) { Text($0.label).tag($0.id) }
                    }
                }
                if !rec.windowOptions.isEmpty {
                    Section("Windows") {
                        ForEach(rec.windowOptions) { Text($0.label).tag($0.id) }
                    }
                }
            }
            .labelsHidden()
            .disabled(rec.isRecording)
            .onChange(of: rec.selectedID) { rec.updateOutputSize() }
        }
    }

    // MARK: Video

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Video").font(.headline)

            HStack {
                Text("Size").frame(width: 64, alignment: .leading)
                Picker("", selection: $rec.videoSize) {
                    ForEach(Recorder.VideoSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                .labelsHidden()
                .onChange(of: rec.videoSize) { rec.updateOutputSize() }
                Text(rec.outputSize == .zero
                     ? "—"
                     : "\(Int(rec.outputSize.width))×\(Int(rec.outputSize.height)) px")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Codec").frame(width: 64, alignment: .leading)
                Picker("", selection: $rec.codec) {
                    ForEach(Recorder.Codec.allCases) { codec in Text(codec.title).tag(codec) }
                }
                .labelsHidden()
            }

            HStack {
                Text("Quality").frame(width: 64, alignment: .leading)
                Picker("", selection: $rec.quality) {
                    ForEach(Recorder.Quality.allCases) { quality in Text(quality.title).tag(quality) }
                }
                .labelsHidden()
                Text(rec.outputSize == .zero ? "—"
                     : String(format: "%.1f Mbps", Double(rec.bitrate(for: rec.outputSize)) / 1_000_000))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Rate").frame(width: 64, alignment: .leading)
                Picker("", selection: $rec.fps) {
                    Text("120 fps").tag(120)
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                    Text("24 fps").tag(24)
                    Text("15 fps").tag(15)
                }
                .labelsHidden()
            }

            Toggle("Include the pointer", isOn: $rec.showsCursor)
            Toggle("Include Tapdeck's own window", isOn: $rec.includesOwnWindows)
                .help("Tapdeck leaves its own windows out of a screen recording, so the recording does not show the controls being used. Turn this on to record them too.")
        }
        .disabled(rec.isRecording)
    }

    // MARK: Audio

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio").font(.headline)

            HStack {
                Text("Source").frame(width: 64, alignment: .leading)
                Picker("", selection: $rec.audioSourceID) {
                    Section("This Mac") {
                        Text("System audio and microphone")
                            .tag(Recorder.screenCaptureKitSourceID)
                    }
                    if !rec.tapdeckSources.isEmpty {
                        Section("Tapdeck devices — what a mix sends") {
                            ForEach(rec.tapdeckSources) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                    }
                    if !rec.microphoneSources.isEmpty {
                        Section("Microphones and interfaces") {
                            ForEach(rec.microphoneSources) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                    }
                }
                .labelsHidden()
            }

            if rec.usesMixerOutput {
                Label("Pick Tapdeck and the recording carries whatever the mixer is sending.",
                      systemImage: "slider.vertical.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let channels = rec.audioDeviceOptions.first(where: { $0.uid == rec.audioSourceID })?
                    .inputChannels, channels > 2 {
                    Label("\(channels) channels — the file gets \((channels + 1) / 2) separate audio tracks, one per channel pair, so each can be edited on its own.",
                          systemImage: "square.split.2x1")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Toggle("System audio (anything playing on this Mac)", isOn: $rec.systemAudio)
                Toggle("Microphone", isOn: $rec.microphone)
                Text("No virtual audio device needed — ScreenCaptureKit captures this directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(rec.isRecording)
    }

    // MARK: Transport

    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if rec.isRecording {
                    Button {
                        Task { await rec.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button {
                        Task { await rec.start() }
                    } label: {
                        Label("Start Recording", systemImage: "record.circle")
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
                    Button("Show in Finder") { rec.revealLastOutput() }
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
