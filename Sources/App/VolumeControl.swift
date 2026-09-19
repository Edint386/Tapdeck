import SwiftUI

/// A volume fader with a mute button and a readout in decibels.
///
/// The slider moves in amplitude from silent to 0 dB: Tapdeck's own faders
/// only turn down. Making something louder is the device's volume or Even Out,
/// since boosting the signal only pushes it into the ceiling. The readout is in
/// decibels because that is how loudness is perceived and how the rest of the
/// app reports levels.
struct VolumeControl: View {
    let title: String?
    @Binding var volume: Float
    @Binding var isMuted: Bool
    var maximum: Float = 1

    var body: some View {
        HStack(spacing: 8) {
            if let title {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Button {
                isMuted.toggle()
            } label: {
                Image(systemName: icon)
                    .foregroundStyle(isMuted ? Color.red : Color.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(isMuted ? "Unmute" : "Mute")

            Slider(value: Binding(get: { Double(volume) }, set: { volume = Float($0) }),
                   in: 0...Double(maximum))
                .controlSize(.small)
                .disabled(isMuted)

            Text(Self.decibels(isMuted ? 0 : volume))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .contextMenu {
            Button("Reset to 0 dB") { volume = 1; isMuted = false }
        }
    }

    private var icon: String {
        if isMuted || volume == 0 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    static func decibels(_ gain: Float) -> String {
        guard gain > 0.0005 else { return "−∞ dB" }
        return String(format: "%+.1f dB", 20 * log10(gain))
    }
}

/// The app-wide master volume, bound to settings.
struct MasterVolumeControl: View {
    @EnvironmentObject private var settings: AppSettings
    var showsTitle = true

    var body: some View {
        VolumeControl(title: showsTitle ? "Master" : nil,
                      volume: $settings.masterVolume,
                      isMuted: $settings.isMasterMuted)
            .help("Volume for everything Tapdeck plays, across every mix and output")
    }
}
