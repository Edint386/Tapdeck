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
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await rec.refreshContent() }
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
                Picker("", selection: $rec.scalePercent) {
                    Text("100% (native)").tag(100)
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
                Text("Rate").frame(width: 64, alignment: .leading)
                Picker("", selection: $rec.fps) {
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                    Text("24 fps").tag(24)
                    Text("15 fps").tag(15)
                }
                .labelsHidden()
            }

            Toggle("Include the pointer", isOn: $rec.showsCursor)
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
                    Text("ScreenCaptureKit (system audio and microphone)")
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
