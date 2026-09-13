import SwiftUI

/// The panel that opens from the menu bar.
/// Mixes are meant to be left running, so each can be started, stopped and
/// watched here without opening the window.
struct MenuBarPanelView: View {
    @EnvironmentObject private var model: MixerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Mixes").font(.subheadline.weight(.semibold))
                Spacer()
                if model.runningCount > 0 {
                    Text("\(model.runningCount) running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Stop All") { model.stopAll() }
                        .controlSize(.small)
                }
            }

            if model.mixes.isEmpty {
                Text("No mixes yet").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.mixes) { mix in
                        MenuBarMixRow(mix: mix)
                    }
                }
            }

            Divider()

            HStack {
                Button("Open Window") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Settings…") {
                    // The popover is hosted by AppKit, outside any SwiftUI scene,
                    // so ask the responder chain rather than openSettings.
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
        .task { model.refresh() }
    }
}

private struct MenuBarMixRow: View {
    @ObservedObject var mix: MixSession

    var body: some View {
        HStack(spacing: 9) {
            Button {
                mix.toggleRunning()
            } label: {
                Image(systemName: mix.isRunning ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(mix.isRunning ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(mix.isRunning ? "Stop" : "Start")

            VStack(alignment: .leading, spacing: 3) {
                Text(mix.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(mix.outputSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            LevelBar(level: mix.level).frame(width: 56, height: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(mix.isRunning ? 0.14 : 0.07),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}
