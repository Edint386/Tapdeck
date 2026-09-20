import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AudioSettingsView()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            VirtualDevicesSettingsView()
                .tabItem { Label("Virtual Devices", systemImage: "arrow.triangle.branch") }
            DiagnosticsSettingsView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("Show Tapdeck in the menu bar", isOn: $settings.showsMenuBarItem)
                Text("The menu bar item starts and stops mixes without opening the window. On a notched display a full menu bar may leave no room for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Recordings") {
                Picker("Record a mix as", selection: $settings.mixRecordingFormat) {
                    ForEach(MixRecorder.FileFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                LabeledContent("Save to") {
                    HStack(spacing: 8) {
                        Text(settings.recordingFolder.path(percentEncoded: false)
                            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { settings.chooseRecordingFolder() }
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: settings.recordingFolder,
                                                                     withIntermediateDirectories: true)
                            NSWorkspace.shared.activateFileViewerSelecting([settings.recordingFolder])
                        }
                    }
                }
                if settings.recordingFolder != AppSettings.defaultRecordingFolder {
                    Button("Use the Default Folder") {
                        settings.recordingFolder = AppSettings.defaultRecordingFolder
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Audio

struct AudioSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Buffer", selection: $settings.bufferSize) {
                    ForEach(AppSettings.BufferSize.allCases) { size in
                        Text("\(size.title) — \(size.rawValue) frames, about \(size.milliseconds) ms")
                            .tag(size)
                    }
                }
                Text("Each source and extra output holds this much audio before it plays. Larger buffers add delay but ride out clock drift and busy moments without dropouts. Applies to mixes started after the change.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Latency")
            }

            Section {
                LabeledContent("Target") {
                    HStack(spacing: 8) {
                        Slider(value: rounded($settings.loudnessTarget), in: -30...(-10))
                            .frame(maxWidth: 180)
                        Text(String(format: "%.0f LUFS", settings.loudnessTarget))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 80, alignment: .trailing)
                        Menu("Presets") {
                            ForEach(AppSettings.loudnessTargets, id: \.value) { preset in
                                Button(preset.title) { settings.loudnessTarget = preset.value }
                            }
                        }
                        .fixedSize()
                    }
                }
                LabeledContent("Maximum boost") {
                    HStack(spacing: 8) {
                        Slider(value: rounded($settings.loudnessMaximumBoost), in: 0...24)
                            .frame(maxWidth: 180)
                        Text(String(format: "+%.0f dB", settings.loudnessMaximumBoost))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                Picker("Speed", selection: $settings.loudnessSpeed) {
                    Text("Gentle").tag(LoudnessTuning.Speed.gentle)
                    Text("Balanced").tag(LoudnessTuning.Speed.balanced)
                    Text("Fast").tag(LoudnessTuning.Speed.fast)
                }
                .pickerStyle(.segmented)
                Text("“Even out loudness” on a mix or a source brings whatever plays to the target, so one video, site or song is about as loud as the next. Quiet material is raised by at most the maximum boost, so background noise is not blown up. Gentle keeps the rise and fall inside a song or film; Fast evens out more. Silence and short pauses leave the level alone, and a peak limiter at −1 dBFS catches sudden jumps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Loudness")
            }
        }
        .formStyle(.grouped)
    }

    /// Whole units, without the tick marks a stepped slider draws.
    private func rounded(_ value: Binding<Double>) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() })
    }
}
