import CoreAudio
import Foundation

/// The list of virtual devices the driver publishes.
///
/// The app owns this list and hands it to the driver. The file below is only a
/// record of the current state — see `push()` for the path that actually takes
/// effect.
///
/// The file has to live under /Library/Preferences/Audio, because the process
/// hosting the driver is sandboxed and can only read a handful of locations.
/// Somewhere like /Users/Shared is not among them, and reading simply fails
/// with no denial in the log.
///
/// Audio itself is root:_coreaudiod 775 and the Data directory beneath it is
/// SIP-restricted, so neither is writable by the app. install-driver.sh
/// therefore creates Audio/Tapdeck owned by the user.
struct VirtualDeviceConfiguration {

    struct Device: Identifiable, Hashable {
        var id: String { uid }
        var uid: String
        var name: String
        var channelCount: Int

        init(uid: String = "TapdeckDevice-\(UUID().uuidString.prefix(8))",
             name: String,
             channelCount: Int = 2) {
            self.uid = uid
            self.name = name
            self.channelCount = channelCount
        }
    }

    var devices: [Device]

    static let directoryURL = URL(fileURLWithPath: "/Library/Preferences/Audio/Tapdeck",
                                  isDirectory: true)
    static let fileURL = directoryURL.appendingPathComponent("Devices.plist")

    /// A copy of the configuration. The directory belongs to the system, so
    /// keep our own in case an update clears it.
    private static let mirrorKey = "virtualDeviceConfiguration"

    /// The device the driver falls back to when it has no configuration.
    static let defaultDevice = Device(uid: "TapdeckDevice", name: "Tapdeck", channelCount: 2)

    // MARK: - Reading and writing

    static func load() -> VirtualDeviceConfiguration {
        // Restore from our copy if the file has gone.
        if !FileManager.default.fileExists(atPath: fileURL.path),
           let mirrored = UserDefaults.standard.array(forKey: mirrorKey) as? [[String: Any]],
           !mirrored.isEmpty {
            try? write(raw: mirrored)
        }

        guard let data = try? Data(contentsOf: fileURL),
              let raw = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [[String: Any]] else {
            return VirtualDeviceConfiguration(devices: [defaultDevice])
        }

        let devices = raw.compactMap { entry -> Device? in
            guard let uid = entry["UID"] as? String, !uid.isEmpty else { return nil }
            let name = entry["Name"] as? String ?? uid
            let channels = entry["Channels"] as? Int ?? 2
            return Device(uid: uid, name: name, channelCount: channels)
        }
        return VirtualDeviceConfiguration(devices: devices.isEmpty ? [defaultDevice] : devices)
    }

    enum WriteError: LocalizedError, MessageError {
        case cannotCreateDirectory(String)
        case cannotWrite(String)
        case driverUnavailable
        case rejected(OSStatus)

        var errorDescription: String? { String(localized: message) }

        var message: LocalizedStringResource {
            switch self {
            case .cannotCreateDirectory(let detail):
                return "Could not create the configuration directory: \(detail)"
            case .cannotWrite(let detail):
                return "Could not write the configuration: \(detail)"
            case .driverUnavailable:
                return "The Tapdeck driver is not installed. Run: sudo ./install-driver.sh"
            case .rejected(let status):
                return "The driver rejected the device list (OSStatus \(Int(status)))"
            }
        }
    }

    func save() throws {
        let raw = propertyListRepresentation
        UserDefaults.standard.set(raw, forKey: Self.mirrorKey)

        // Hand the list to the driver first — that is what actually takes effect.
        try push()

        // Keep a copy on disk as well. The driver cannot read it from its
        // sandbox today, but it costs nothing and documents the current state.
        try? Self.write(raw: raw)
    }

    private static func write(raw: [[String: Any]]) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directoryURL.path) else {
            throw WriteError.cannotCreateDirectory(
                "\(directoryURL.path) does not exist. Run: sudo ./install-driver.sh")
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: raw,
                                                          format: .xml, options: 0)
            try data.write(to: fileURL, options: .atomic)
            // The driver host runs as another user, so make it world readable.
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        } catch {
            throw WriteError.cannotWrite(error.localizedDescription)
        }
    }

    // MARK: - Handing the list to the driver

    /// Bundle identifier of the HAL plug-in, used to locate its object.
    static let driverBundleID = "dev.kosuke.Tapdeck.driver"

    /// Custom property the driver exposes to receive the device list ('tpdv').
    static let deviceListSelector: AudioObjectPropertySelector = 0x74706476

    /// Locate the plug-in object that our driver registered with the HAL.
    static func plugInObjectID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateBundleIDToPlugIn,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var bundleID = driverBundleID as CFString
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = withUnsafeMutablePointer(to: &bundleID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID.system, &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier,
                                       &size, &objectID)
        }
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else {
            throw WriteError.driverUnavailable
        }
        return objectID
    }

    /// Push the list straight to the driver through the HAL.
    ///
    /// The driver runs inside a heavily sandboxed helper process that cannot
    /// read files an unprivileged app is able to write, so a configuration file
    /// alone never reaches it. A custom property travels through Core Audio
    /// itself and takes effect immediately.
    func push() throws {
        let plugIn = try Self.plugInObjectID()
        var address = AudioObjectPropertyAddress(
            mSelector: Self.deviceListSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var payload: CFPropertyList = propertyListRepresentation as CFArray
        let status = withUnsafeMutablePointer(to: &payload) { pointer in
            AudioObjectSetPropertyData(plugIn, &address, 0, nil,
                                       UInt32(MemoryLayout<CFPropertyList>.size), pointer)
        }
        guard status == noErr else { throw WriteError.rejected(status) }
    }

    var propertyListRepresentation: [[String: Any]] {
        devices.map { ["UID": $0.uid, "Name": $0.name, "Channels": $0.channelCount] }
    }
}
