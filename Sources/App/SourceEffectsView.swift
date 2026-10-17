import SwiftUI

/// Everything that shapes one source's sound, opened from its row.
struct SourceEffectsView: View {
    @ObservedObject var mix: MixSession
    let sourceID: UUID

    private var row: MixSession.SourceRow? { mix.sources.first { $0.id == sourceID } }

    /// Edits go straight to the engine, so changes are heard while dragging.
    private var effects: Binding<EffectSettings> {
        Binding(get: { row?.effects ?? EffectSettings() },
                set: { mix.setEffects($0, for: sourceID) })
    }

    var body: some View {
        if let row {
            VStack(alignment: .leading, spacing: 0) {
                header(row)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if row.canReplaceOriginal { replaceSection(row) }
                        filterSection
                        equaliserSection
                        dynamicsSection
                        loudnessSection(row)
                        stereoSection
                        delaySection
                    }
                    .padding(16)
                }
            }
            .frame(width: 380, height: 620)
        }
    }

    // MARK: Header

    private func header(_ row: MixSession.SourceRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.headline).lineLimit(1)
                Text("Effects").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset All") { effects.wrappedValue = EffectSettings() }
                .controlSize(.small)
                .disabled(!row.effects.isActive && row.effects == EffectSettings())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Replace

    private func replaceSection(_ row: MixSession.SourceRow) -> some View {
        section("Original Sound") {
            Toggle("Replace the original sound", isOn: Binding(
                get: { row.replacesOriginal },
                set: { mix.setReplacesOriginal($0, for: sourceID) }))
            Text(row.replacesOriginal
                 ? "The app's own output is silenced while this mix runs, so you hear only Tapdeck's version — with these effects, at this mix's volume, on this mix's outputs. It comes back on its own when the mix stops."
                 : "Off: the app still plays straight to its device and this mix works on a copy. Effects change what the mix sends, not what you hear from the app itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Filters

    private var filterSection: some View {
        section("Filters") {
            Toggle("Low cut", isOn: effects.lowCutEnabled)
            frequencySlider(effects.lowCutFrequency, range: 20...500)
                .disabled(!effects.wrappedValue.lowCutEnabled)
            hint("Removes rumble, desk bumps and hum below the frequency.")

            Toggle("High cut", isOn: effects.highCutEnabled)
                .padding(.top, 4)
            frequencySlider(effects.highCutFrequency, range: 2_000...20_000)
                .disabled(!effects.wrappedValue.highCutEnabled)
            hint("Removes hiss and harshness above the frequency.")
        }
    }

    // MARK: Equaliser

    private var equaliserSection: some View {
        section("Equaliser") {
            HStack {
                Toggle("On", isOn: effects.eqEnabled)
                Spacer()
                Menu("Preset") {
                    ForEach(EffectSettings.equaliserPresets) { preset in
                        Button(preset.id) {
                            var updated = effects.wrappedValue
                            for (index, gain) in preset.gains.enumerated() where index < updated.bands.count {
                                updated.bands[index].gain = gain
                            }
                            updated.eqEnabled = true
                            effects.wrappedValue = updated
                        }
                    }
                }
                .fixedSize()
            }

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(effects.wrappedValue.bands.indices, id: \.self) { index in
                    bandControl(index)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 170)
            .disabled(!effects.wrappedValue.eqEnabled)
            .opacity(effects.wrappedValue.eqEnabled ? 1 : 0.5)
        }
    }

    private func bandControl(_ index: Int) -> some View {
        let band = effects.wrappedValue.bands[index]
        return VStack(spacing: 6) {
            Text(String(format: "%+.1f", band.gain))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(band.gain == 0 ? .secondary : .primary)
            Slider(value: Binding(get: { band.gain },
                                  set: { effects.wrappedValue.bands[index].gain = ($0 * 2).rounded() / 2 }),
                   in: -12...12)
                .controlSize(.mini)
                .rotationEffect(.degrees(-90))
                .frame(width: 110, height: 20)
                .frame(width: 30, height: 110)
                .onTapGesture(count: 2) { effects.wrappedValue.bands[index].gain = 0 }
            Text(Self.frequencyLabel(band.frequency))
                .font(.system(size: 9, weight: .medium))
            let shape: LocalizedStringKey = band.shape == .peak ? "peak" : "shelf"
            Text(shape)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .help("Double-click to reset")
    }

    // MARK: Dynamics

    private var dynamicsSection: some View {
        section("Dynamics") {
            Toggle("Noise gate", isOn: effects.gateEnabled)
            labeledSlider("Threshold", value: effects.gateThreshold, range: -80...(-10), unit: "dB")
                .disabled(!effects.wrappedValue.gateEnabled)
            hint("Silences the source while it stays below the threshold — background noise between words.")

            Toggle("Compressor", isOn: effects.compressorEnabled)
                .padding(.top, 4)
            Group {
                labeledSlider("Threshold", value: effects.compressorThreshold, range: -50...0, unit: "dB")
                labeledSlider("Ratio", value: effects.compressorRatio, range: 1...20, unit: ":1", decimals: 1)
                labeledSlider("Makeup", value: effects.compressorMakeup, range: 0...24, unit: "dB")
            }
            .disabled(!effects.wrappedValue.compressorEnabled)
            hint("Brings loud passages down toward quiet ones. Makeup gain raises the result again.")

            Toggle("Limiter", isOn: effects.limiterEnabled)
                .padding(.top, 4)
            labeledSlider("Ceiling", value: effects.limiterCeiling, range: -24...0, unit: "dB")
                .disabled(!effects.wrappedValue.limiterEnabled)
            hint("No peak ever goes above the ceiling.")
        }
    }

    // MARK: Loudness

    private func loudnessSection(_ row: MixSession.SourceRow) -> some View {
        section("Loudness") {
            HStack {
                Toggle("Even out loudness", isOn: effects.loudnessEnabled)
                Spacer()
                if row.effects.loudnessEnabled, mix.isRunning {
                    Text(LoudnessReading.caption(row.loudnessReading))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            hint("Brings this source to the loudness set in Settings › Audio, however loud or quiet it plays on its own. With the original sound replaced, it evens out what you hear too.")
        }
    }

    // MARK: Stereo

    private var stereoSection: some View {
        section("Stereo") {
            HStack {
                Text("L").font(.caption).foregroundStyle(.secondary)
                Slider(value: effects.balance, in: -1...1)
                    .controlSize(.small)
                    .onTapGesture(count: 2) { effects.wrappedValue.balance = 0 }
                Text("R").font(.caption).foregroundStyle(.secondary)
                Text(Self.balanceLabel(effects.wrappedValue.balance))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            Toggle("Mono", isOn: effects.mono)
            hint("Mono folds both channels together — for a source that only plays on one side.")
        }
    }

    // MARK: Delay

    private var delaySection: some View {
        section("Delay") {
            labeledSlider("Delay", value: effects.delay, range: 0...EffectSettings.maximumDelay,
                          unit: "ms", decimals: 0)
            hint("Holds this source back, for instance to line a microphone up with a video that arrives late.")
        }
    }

    // MARK: Pieces

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func labeledSlider(_ label: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>,
                               unit: String, decimals: Int = 1) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).controlSize(.small)
            Text(String(format: "%.\(decimals)f \(unit)", value.wrappedValue))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    /// Frequency is perceived logarithmically, so the slider moves in octaves.
    private func frequencySlider(_ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        let low = log2(range.lowerBound), high = log2(range.upperBound)
        return HStack(spacing: 8) {
            Text("Frequency").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Slider(value: Binding(get: { log2(max(range.lowerBound, value.wrappedValue)) },
                                  set: { value.wrappedValue = pow(2, $0).rounded() }),
                   in: low...high)
                .controlSize(.small)
            Text(Self.frequencyLabel(value.wrappedValue))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    static func frequencyLabel(_ hertz: Double) -> String {
        hertz >= 1000 ? String(format: hertz >= 10_000 ? "%.0f kHz" : "%.1f kHz", hertz / 1000)
                      : String(format: "%.0f Hz", hertz)
    }

    static func balanceLabel(_ balance: Double) -> LocalizedStringResource {
        if abs(balance) < 0.005 { return "centre" }
        let percent = Int((abs(balance) * 100).rounded())
        return balance < 0 ? "L \(percent)%" : "R \(percent)%"
    }
}
