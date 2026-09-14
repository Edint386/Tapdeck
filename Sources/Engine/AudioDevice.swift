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
    var transport: Transport = .other

    var canInput: Bool  { inputChannels  > 0 }
    var canOutput: Bool { outputChannels > 0 }

    /// How a device is connected, from kAudioDevicePropertyTransportType.
    enum Transport: String, Codable, Hashable {
        case builtIn, usb, bluetooth, airPlay, hdmi, displayPort, thunderbolt, virtual, aggregate, other

        init(_ code: UInt32) {
            switch code {
            case kAudioDeviceTransportTypeBuiltIn:     self = .builtIn
            case kAudioDeviceTransportTypeUSB:         self = .usb
            case kAudioDeviceTransportTypeBluetooth,
                 kAudioDeviceTransportTypeBluetoothLE: self = .bluetooth
            case kAudioDeviceTransportTypeAirPlay:     self = .airPlay
            case kAudioDeviceTransportTypeHDMI:        self = .hdmi
            case kAudioDeviceTransportTypeDisplayPort: self = .displayPort
            case kAudioDeviceTransportTypeThunderbolt: self = .thunderbolt
            case kAudioDeviceTransportTypeVirtual:     self = .virtual
            case kAudioDeviceTransportTypeAggregate,
                 kAudioDeviceTransportTypeAutoAggregate: self = .aggregate
            default:                                   self = .other
            }
        }

        var isWireless: Bool { self == .airPlay || self == .bluetooth }

        /// Roughly how late a device of this kind plays what it is sent, in
        /// milliseconds. Wireless devices buffer far more than they report
        /// through kAudioDeviceLatency: AirPlay reported 0 when measured.
        /// A starting point for lining outputs up, to be fine-tuned by ear.
        var typicalLatencyMilliseconds: Double {
            switch self {
            case .airPlay:   return 2_000
            case .bluetooth: return 150
            default:         return 0
            }
        }
    }

    static func all() throws -> [AudioDevice] {
        let ids: [AudioDeviceID] = try AudioObjectID.system.readArray(
            kAudioHardwarePropertyDevices, label: "reading the device list")

        return ids.compactMap { id -> AudioDevice? in
            let obj = AudioObjectID(id)
            guard let uid = obj.readString(kAudioDevicePropertyDeviceUID) else { return nil }
            let name = obj.readString(kAudioObjectPropertyName) ?? uid
            let rate: Float64 = (try? obj.read(kAudioDevicePropertyNominalSampleRate)) ?? 0
            let transport: UInt32 = (try? obj.read(kAudioDevicePropertyTransportType)) ?? 0

            return AudioDevice(deviceID: id,
                               uid: uid,
                               name: name,
                               inputChannels: channelCount(obj, scope: kAudioObjectPropertyScopeInput),
                               outputChannels: channelCount(obj, scope: kAudioObjectPropertyScopeOutput),
                               sampleRate: rate,
                               transport: Transport(transport))
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

    /// Find a saved device, including one that has come back under a new UID.
    ///
    /// Some devices are given a fresh UID each time they appear. The AirPlay
    /// device is one: its UID carries a long number that changed between
    /// sessions (`…-50150987687166-Audio`, then `…-89446392180958-Audio`), so a
    /// mix saved with one could never find it again. When the exact UID is
    /// missing, a device with the same name whose UID matches once such
    /// numbers are ignored is taken to be the same device.
    static func find(uid: String, name: String, in devices: [AudioDevice]) -> AudioDevice? {
        if let exact = devices.first(where: { $0.uid == uid }) { return exact }
        let signature = stableSignature(of: uid)
        guard signature != uid else { return nil }
        let matches = devices.filter { $0.name == name && stableSignature(of: $0.uid) == signature }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A UID with its hyphen-separated runs of eight or more digits removed.
    static func stableSignature(of uid: String) -> String {
        uid.split(separator: "-", omittingEmptySubsequences: false)
            .filter { !($0.count >= 8 && $0.allSatisfy(\.isNumber)) }
            .joined(separator: "-")
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
