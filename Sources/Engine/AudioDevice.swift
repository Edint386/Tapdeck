import CoreAudio
import Foundation

/// One audio device present on the system.
/// The mixer uses these as its sources and as its output destination.
struct AudioDevice: Identifiable, Hashable {
    var id: AudioDeviceID { deviceID }

    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double

    var canInput: Bool  { inputChannels  > 0 }
    var canOutput: Bool { outputChannels > 0 }

    static func all() throws -> [AudioDevice] {
        let ids: [AudioDeviceID] = try AudioObjectID.system.readArray(
            kAudioHardwarePropertyDevices, label: "reading the device list")

        return ids.compactMap { id -> AudioDevice? in
            let obj = AudioObjectID(id)
            guard let uid = obj.readString(kAudioDevicePropertyDeviceUID) else { return nil }
            let name = obj.readString(kAudioObjectPropertyName) ?? uid
            let rate: Float64 = (try? obj.read(kAudioDevicePropertyNominalSampleRate)) ?? 0

            return AudioDevice(deviceID: id,
                               uid: uid,
                               name: name,
                               inputChannels: channelCount(obj, scope: kAudioObjectPropertyScopeInput),
                               outputChannels: channelCount(obj, scope: kAudioObjectPropertyScopeOutput),
                               sampleRate: rate)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Count channels from the stream configuration.
    /// kAudioDevicePropertyStreamConfiguration returns a variable-length AudioBufferList.
    private static func channelCount(_ obj: AudioObjectID,
                                     scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, raw) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func find(uid: String) throws -> AudioDevice? {
        try all().first { $0.uid == uid }
    }

    static func find(nameContains needle: String) throws -> AudioDevice? {
        let devices = try all()
        return devices.first { $0.uid == needle }
            ?? devices.first { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    /// The virtual device published by the Tapdeck driver.
    static func tapdeck() throws -> AudioDevice? {
        try find(uid: "TapdeckDevice")
    }
}
