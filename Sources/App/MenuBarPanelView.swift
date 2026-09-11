import SwiftUI

/// メニューバーから開くパネル。
/// ミキサーは出しっぱなしで使うものなので、ウインドウを開かずに
/// 開始・停止、レベル確認、プリセット切り替えができるようにする。
struct MenuBarPanelView: View {
    @EnvironmentObject private var model: MixerModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            sources
            if !model.presets.isEmpty {
                Divider()
                presets
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 290)
        .task { model.refresh() }
    }

    // MARK: 上部

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(model.isRunning ? "送出中" : "停止中")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(outputName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Button {
                    model.toggleRunning()
                } label: {
                    Label(model.isRunning ? "停止" : "開始",
                          systemImage: model.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRunning ? .red : .accentColor)
                .disabled(model.rows.isEmpty)

                LevelBar(level: model.masterLevel).frame(width: 80, height: 6)
            }
        }
    }

    private var outputName: String {
        model.outputCandidates.first { $0.uid == model.outputDeviceUID }?.name ?? "—"
    }

    // MARK: ソース

    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.rows.isEmpty {
                Text("ソースがありません")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.rows) { row in
                    HStack(spacing: 7) {
                        if let appIcon = row.appIcon {
                            Image(nsImage: appIcon).resizable().frame(width: 15, height: 15)
                        } else {
                            Image(systemName: row.symbolName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 15)
                        }
                        Text(row.label)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(row.isMuted ? .tertiary : .primary)
                        Spacer(minLength: 4)
                        LevelBar(level: row.isMuted ? 0 : row.level)
                            .frame(width: 44, height: 3)
                        Button {
                            model.toggleMute(row.id)
                        } label: {
                            Image(systemName: row.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(row.isMuted ? Color.red : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    // MARK: プリセット

    private var presets: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("プリセット").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(model.presets) { preset in
                Button {
                    model.applyPreset(preset.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.activePresetID == preset.id
                              ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(model.activePresetID == preset.id
                                             ? Color.accentColor : Color.secondary)
                        Text(preset.name).font(.caption)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 下部

    private var footer: some View {
        HStack {
            Button("ウインドウを開く") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .font(.caption)
            Spacer()
            Button("終了") { NSApp.terminate(nil) }
                .font(.caption)
        }
        .buttonStyle(.borderless)
    }
}
