import Foundation

/// How a mixer configuration is stored so it survives to the next launch.
///
/// Applications get a new PID every launch, so they are identified by bundle
/// identifier. Processes without one, such as command line tools, are not
/// saved at all.
struct MixerConfiguration: Codable {

    struct Source: Codable {
        enum Kind: String, Codable {
            case application, systemAudio, inputDevice
        }
        var kind: Kind
        /// Bundle identifier for an app, device UID for an input device.
        var identifier: String?
        var name: String
        var gain: Float
        var isMuted: Bool
    }

    var sources: [Source] = []
    var outputDeviceUID: String = "TapdeckDevice"

    // MARK: - Loading and saving

    private static let storageKey = "mixerConfiguration"

    static func load() -> MixerConfiguration {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(MixerConfiguration.self, from: data) else {
            return MixerConfiguration()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: - Conversion to and from the engine's types

    init() {}

    init(sources: [Mixer.Source], outputDeviceUID: String) {
        self.outputDeviceUID = outputDeviceUID
        self.sources = sources.compactMap { source in
            guard source.target.isPersistable else { return nil }
            switch source.target {
            case .application(let bundleID, let name):
                return Source(kind: .application, identifier: bundleID, name: name,
                              gain: source.gain, isMuted: source.isMuted)
            case .systemAudio:
                return Source(kind: .systemAudio, identifier: nil, name: "All system audio",
                              gain: source.gain, isMuted: source.isMuted)
            case .inputDevice(let uid, let name):
                return Source(kind: .inputDevice, identifier: uid, name: name,
                              gain: source.gain, isMuted: source.isMuted)
            }
        }
    }

    var targets: [(target: Mixer.Target, gain: Float, isMuted: Bool)] {
        sources.compactMap { saved in
            let target: Mixer.Target
            switch saved.kind {
            case .application:
                target = .application(bundleID: saved.identifier, name: saved.name)
            case .systemAudio:
                target = .systemAudio
            case .inputDevice:
                guard let uid = saved.identifier else { return nil }
                target = .inputDevice(uid: uid, name: saved.name)
            }
            return (target, saved.gain, saved.isMuted)
        }
    }
}


/// A named mixer configuration, for switching between setups such as
/// "Meetings" and "Streaming".
struct MixerPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var configuration: MixerConfiguration
}

struct MixerPresetStore {
    private static let storageKey = "mixerPresets"

    static func load() -> [MixerPreset] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let presets = try? JSONDecoder().decode([MixerPreset].self, from: data) else {
            return []
        }
        return presets
    }

    static func save(_ presets: [MixerPreset]) {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
