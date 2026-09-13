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
        }
        .formStyle(.grouped)
    }
}
