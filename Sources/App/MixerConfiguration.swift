import Foundation

/// ミキサーの構成を次回起動へ持ち越すための保存形式。
///
/// アプリは再起動で PID が変わるので、同定はバンドルIDで行う。
/// バンドルIDを持たないプロセス（コマンドラインツールなど）は保存しない。
struct MixerConfiguration: Codable {

    struct Source: Codable {
        enum Kind: String, Codable {
            case application, systemAudio, inputDevice
        }
        var kind: Kind
        /// アプリならバンドルID、入力デバイスならデバイスUID。
        var identifier: String?
        var name: String
        var gain: Float
        var isMuted: Bool
    }

    var sources: [Source] = []
    var outputDeviceUID: String = "TapdeckDevice"

    // MARK: - 保存と読み出し

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

    // MARK: - エンジン側の型との変換

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
                return Source(kind: .systemAudio, identifier: nil, name: "システム全体の音",
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


/// 名前を付けて保存したミキサー構成。
/// 「会議用」「配信用」のように、用途ごとの組み合わせを切り替えるためのもの。
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
