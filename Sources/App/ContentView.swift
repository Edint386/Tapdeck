import SwiftUI

struct RecorderPanelView: View {
    @EnvironmentObject private var rec: Recorder
    @EnvironmentObject private var mixer: MixerModel
    @EnvironmentObject private var settings: AppSettings

    /// Three fixed bands, the same in both modes, so switching modes changes
    /// only what is inside the middle: the mode switch at the top, the options
    /// in full-width cards that scroll, and the record bar pinned at the bottom.
    /// The column used to be only as wide as its content, so every switch slid
    /// the whole panel sideways and moved the record button.
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $rec.mode) {
                ForEach(Recorder.Mode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .disabled(isRecordingAnything)
            .padding(.vertical, 12)

            Divider()

            Form {
                if rec.mode == .audio {
                    mixSourceSection
                    fileSection
                    monitorSection
                } else {
                    captureSection
                    videoSection
                    screenAudioSection
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)

            Divider()

            recordBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await rec.refreshContent() }
    }

    private var isRecordingAnything: Bool {
        rec.isRecording || mixer.mixes.contains { $0.isRecordingFile }
    }

    // MARK: - Audio only

    /// The mix being recorded, else the one chosen, else the first.
    private var selectedMix: MixSession? {
        mixer.mixes.first { $0.isRecordingFile }
            ?? mixer.mixes.first { $0.id == rec.audioMixID }
            ?? mixer.mixes.first
    }

    private var mixSourceSection: some View {
        Section {
            Picker(selection: Binding(get: { selectedMix?.id ?? UUID() },
                                      set: { rec.audioMixID = $0 })) {
                ForEach(mixer.mixes) { mix in
                    Text(mix.name.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "Unnamed mix" : mix.name).tag(mix.id)
                }
            } label: {
                Text("Mix")
                Text(selectedMix == nil ? "Make a mix first"
                     : "What it plays, after its effects and volume. A stopped mix is started for you.")
            }
            .disabled(isRecordingAnything)
        } header: {
            Text("Source")
        }
    }

    private var fileSection: some View {
        let format = settings.mixRecordingFormat
        return Section {
            Picker(selection: $settings.mixRecordingFormat) {
                ForEach(MixRecorder.FileFormat.allCases) { format in Text(format.title).tag(format) }
            } label: {
                Text("Format")
                Text("No MP3: macOS cannot encode it")
            }
            // Always one quality row, whatever the format, so choosing a
            // format never changes the height.
            if format.isLossy {
                Picker("Quality", selection: $settings.mixRecordingBitrate) {
                    ForEach(MixRecorder.bitrates, id: \.self) { rate in Text("\(rate / 1000) kbps").tag(rate) }
                }
            } else if format.hasBitDepth {
                Picker("Quality", selection: $settings.mixRecordingBitDepth) {
                    ForEach(MixRecorder.bitDepths, id: \.self) { depth in Text("\(depth)-bit").tag(depth) }
                }
            } else {
                LabeledContent("Quality") { Text("Lossless") }
            }
            LabeledContent("Save to") {
                Text(Self.shortPath(settings.recordingFolder))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } header: {
            Text("File")
        }
        .disabled(isRecordingAnything)
    }

    private var monitorSection: some View {
        let mix = selectedMix
        let level = mix?.level ?? 0
        return Section {
            LabeledContent("Level") {
                HStack(spacing: 10) {
                    LevelBar(level: level).frame(width: 220, height: 6)
                    Text(Self.decibels(level))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(level >= 0.99 ? Color.red : .secondary)
                        .frame(width: 90, alignment: .trailing)
                }
            }
            // A separate Text in each branch, not a ternary of string literals:
            // that would pick the verbatim initializer and never be translated.
            LabeledContent("Mix") {
                if let mix {
                    if mix.isRunning { Text("Playing") } else { Text("Stopped") }
                } else {
                    Text(verbatim: "—")
                }
            }
            LabeledContent("File") {
                if let mix {
                    if mix.isRecordingFile { Text("\(Self.size(mix.recordingSize)) so far") } else { Text("Not recording") }
                } else {
                    Text(verbatim: "—")
                }
            }
        } header: {
            Text("Monitor")
        }
    }

    // MARK: - Screen and audio

    private var captureSection: some View {
        Section {
            Picker("Record", selection: $rec.selectedID) {
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
            .onChange(of: rec.selectedID) { rec.updateOutputSize() }
            Toggle("Include the pointer", isOn: $rec.showsCursor)
            Toggle(isOn: $rec.includesOwnWindows) {
                Text("Include Tapdeck's own window")
                Text("Left out by default, so the recording does not show the controls being used")
            }
        } header: {
            HStack {
                Text("Capture")
                Spacer()
                Button("Refresh") { Task { await rec.refreshContent() } }
                    .controlSize(.small)
            }
        }
        .disabled(rec.isRecording)
    }

    private var videoSection: some View {
        Section {
            Picker(selection: $rec.videoSize) {
                ForEach(Recorder.VideoSize.allCases) { size in Text(size.title).tag(size) }
            } label: {
                Text("Size")
                Text(rec.outputSize == .zero ? "—"
                     : "\(Int(rec.outputSize.width)) × \(Int(rec.outputSize.height)) pixels")
            }
            .onChange(of: rec.videoSize) { rec.updateOutputSize() }
            Picker("Codec", selection: $rec.codec) {
                ForEach(Recorder.Codec.allCases) { codec in Text(codec.title).tag(codec) }
            }
            Picker(selection: $rec.quality) {
                ForEach(Recorder.Quality.allCases) { quality in Text(quality.title).tag(quality) }
            } label: {
                Text("Quality")
                Text(rec.outputSize == .zero ? "—"
                     : String(format: "%.1f Mbps", Double(rec.bitrate(for: rec.outputSize)) / 1_000_000))
            }
            Picker("Frame rate", selection: $rec.fps) {
                Text("120 fps").tag(120)
                Text("60 fps").tag(60)
                Text("30 fps").tag(30)
                Text("24 fps").tag(24)
                Text("15 fps").tag(15)
            }
        } header: {
            Text("Video")
        }
        .disabled(rec.isRecording)
    }

    private var screenAudioSection: some View {
        Section {
            Picker("Source", selection: $rec.audioSourceID) {
                Section("This Mac") {
                    Text("System audio and microphone").tag(Recorder.screenCaptureKitSourceID)
                }
                if !rec.tapdeckSources.isEmpty {
                    Section("Tapdeck devices — what a mix sends") {
                        ForEach(rec.tapdeckSources) { device in Text(device.name).tag(device.uid) }
                    }
                }
                if !rec.microphoneSources.isEmpty {
                    Section("Microphones and interfaces") {
                        ForEach(rec.microphoneSources) { device in Text(device.name).tag(device.uid) }
                    }
                }
            }
            if rec.usesMixerOutput {
                let channels = rec.audioDeviceOptions.first(where: { $0.uid == rec.audioSourceID })?.inputChannels ?? 2
                LabeledContent("Tracks") {
                    if channels > 2 { Text("\((channels + 1) / 2), one per channel pair") } else { Text("1, what the mix sends") }
                }
            } else {
                Toggle("System audio", isOn: $rec.systemAudio)
                Toggle(isOn: $rec.microphone) {
                    Text("Microphone")
                    Text("Written as its own track, so it can be edited apart")
                }
            }
        } header: {
            Text("Audio")
        }
        .disabled(rec.isRecording)
    }

    // MARK: - Record bar

    /// One bar for both modes, always in the same place.
    private var recordBar: some View {
        let audio = rec.mode == .audio
        let mix = selectedMix
        let recording = audio ? (mix?.isRecordingFile ?? false) : rec.isRecording
        let elapsed = audio ? (mix?.recordingElapsed ?? 0) : rec.elapsed
        let canStart = audio ? mix != nil : !rec.selectedID.isEmpty
        let status: LocalizedStringResource? = audio ? mix?.status : rec.status
        let lastFile = audio ? mix?.lastRecordingURL : rec.lastOutput

        return HStack(spacing: 16) {
            Button {
                if audio {
                    guard let mix else { return }
                    if !mix.isRunning && !mix.isRecordingFile { mix.start() }
                    mix.toggleFileRecording()
                } else {
                    Task { recording ? await rec.stop() : await rec.start() }
                }
            } label: {
                let title: LocalizedStringKey = recording ? "Stop" : "Record"
                Label(title, systemImage: recording ? "stop.fill" : "record.circle")
                    .frame(width: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(recording ? .red : .accentColor)
            .controlSize(.large)
            .disabled(!recording && !canStart)
            .keyboardShortcut(recording ? "." : "r", modifiers: .command)

            Text(Self.timecode(elapsed))
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(recording ? .red : .secondary)

            Text(status ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Show in Finder") {
                if let lastFile { NSWorkspace.shared.activateFileViewerSelecting([lastFile]) }
            }
            .disabled(lastFile == nil || recording)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Pieces

    static func shortPath(_ url: URL) -> String {
        url.path(percentEncoded: false)
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
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

    static func timecode(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

