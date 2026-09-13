import Foundation

/// A saved mix: its sources and the outputs it plays to.
///
/// Mixes replace presets. A preset could only be loaded into the one mixer,
/// replacing whatever was there, so two setups could never run together. Each
/// mix is independent and any number can run at once — one feeding a meeting,
/// another feeding a stream.
struct SavedMix: Codable, Identifiable {
    var id = UUID()
    var name: String
    var sources: [MixerConfiguration.Source]
    var outputs: [SavedOutput]
    /// Optional so mixes saved before mix volume existed still decode.
    var volume: Float?
    var isMuted: Bool?
}

struct SavedOutput: Codable {
    var uid: String
    var name: String
    var gain: Float = 1
    var isMuted = false
}

enum MixLibraryStore {
    private static let storageKey = "mixLibrary"

    static func load() -> [SavedMix] {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let mixes = try? JSONDecoder().decode([SavedMix].self, from: data) {
            return mixes
        }
        return migrateFromSingleMixer()
    }

    static func save(_ mixes: [SavedMix]) {
        guard let data = try? JSONEncoder().encode(mixes) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Build the first library from what earlier versions stored: the single
    /// mixer configuration becomes a mix called Main, and every preset becomes a
    /// mix of its own. The old keys are left in place so an older build still
    /// finds them.
    private static func migrateFromSingleMixer() -> [SavedMix] {
        var mixes: [SavedMix] = []

        if UserDefaults.standard.data(forKey: "mixerConfiguration") != nil {
            let configuration = MixerConfiguration.load()
            mixes.append(SavedMix(name: "Main",
                                  sources: configuration.sources,
                                  outputs: [output(for: configuration.outputDeviceUID)]))
        }
        for preset in MixerPresetStore.load() {
            mixes.append(SavedMix(name: preset.name,
                                  sources: preset.configuration.sources,
                                  outputs: [output(for: preset.configuration.outputDeviceUID)]))
        }

        if mixes.isEmpty {
            mixes.append(SavedMix(name: "Main", sources: [],
                                  outputs: [output(for: VirtualDeviceConfiguration.defaultDevice.uid)]))
        }
        save(mixes)
        return mixes
    }

    private static func output(for uid: String) -> SavedOutput {
        let name = (try? AudioDevice.find(uid: uid))??.name
            ?? (uid == VirtualDeviceConfiguration.defaultDevice.uid ? "Tapdeck" : uid)
        return SavedOutput(uid: uid, name: name)
    }
}
