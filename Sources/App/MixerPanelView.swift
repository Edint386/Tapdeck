import SwiftUI

struct MixerPanelView: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            outputSection
            Divider()
            sourcesSection
            Divider()
            transportSection
        }
        .padding(18)
        .frame(width: 460)
        .task { model.refresh() }
    }

    // MARK: 出力先

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("出力先").font(.headline)
                Spacer()
                Button("更新") { model.refresh() }.controlSize(.small)
            }
            Picker("", selection: $model.outputDeviceUID) {
                ForEach(model.outputCandidates) { device in
                    Text("\(device.name) — \(device.outputChannels)ch").tag(device.uid)
                }
            }
            .labelsHidden()
            .disabled(model.isRunning)

            if model.outputDeviceUID == "TapdeckDevice" {
                Text("Zoom や OBS の入力に「Tapdeck」を選ぶと、ここでミックスした音が渡ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: ソース

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ソース").font(.headline)
                Spacer()
                addMenu
            }

            // よく使う組み合わせはメニューを開かずに足せるようにする。
            HStack(spacing: 6) {
                Button("＋ システム音") { model.addSystemAudio() }
                Button("＋ マイク")     { model.addDefaultMicrophone() }
                Button("＋ 再生中のアプリ") { model.addPlayingApplications() }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            if model.rows.isEmpty {
                Text("ソースがありません。右上の「追加」からアプリ・システム音・マイクを足してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 120, alignment: .top)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.rows) { row in
                            sourceRow(row)
                        }
                    }
                }
                .frame(height: 160)
            }
        }
    }

    private var addMenu: some View {
        Menu("追加") {
            Button("システム全体の音") { model.addSystemAudio() }

            Menu("アプリ") {
                ForEach(model.availableProcesses) { process in
                    Button(process.isPlayingAudio ? "♪ \(process.name)" : process.name) {
                        model.addApplication(process)
                    }
                }
            }

            Menu("マイク・入力デバイス") {
                ForEach(model.availableInputs) { device in
                    Button("\(device.name) (\(device.inputChannels)ch)") {
                        model.addInput(device)
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func sourceRow(_ row: MixerModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.kindLabel)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18), in: Capsule())

                Text(row.label).font(.callout).lineLimit(1)
                Spacer()

                Button {
                    model.toggleMute(row.id)
                } label: {
                    Image(systemName: row.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(row.isMuted ? .red : .secondary)
                }
                .buttonStyle(.borderless)

                Button {
                    model.remove(row.id)
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 8) {
                Slider(value: Binding(
                    get: { Double(row.gain) },
                    set: { model.setGain(Float($0), for: row.id) }
                ), in: 0...2)
                .controlSize(.mini)
                .disabled(row.isMuted)

                LevelBar(level: row.isMuted ? 0 : row.level).frame(width: 70, height: 5)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: 操作

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    model.isRunning ? model.stop() : model.start()
                } label: {
                    Label(model.isRunning ? "停止" : "ミックス開始",
                          systemImage: model.isRunning ? "stop.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(model.rows.isEmpty)

                VStack(alignment: .leading, spacing: 2) {
                    Text("出力").font(.system(size: 9)).foregroundStyle(.secondary)
                    LevelBar(level: model.masterLevel).frame(width: 90, height: 7)
                }
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// 簡易レベルメーター。振幅をそのまま横幅にすると小さい音がほぼ見えないので、
/// dB に変換して -60dB〜0dB を全幅に割り当てる。
struct LevelBar: View {
    let level: Float

    private var fraction: Double {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return min(1, max(0, (db + 60) / 60))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(fraction > 0.95 ? Color.red : (fraction > 0.8 ? Color.yellow : Color.green))
                    .frame(width: geometry.size.width * fraction)
            }
        }
    }
}
