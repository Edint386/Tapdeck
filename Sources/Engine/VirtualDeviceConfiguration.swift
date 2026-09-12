import CoreAudio
import Foundation

/// ドライバが公開する仮想デバイスの一覧。
///
/// アプリが書き、ドライバ（coreaudiod 内）が監視して増減を反映する。
///
/// 置き場所は /Library/Preferences/Audio 配下でなければならない。
/// coreaudiod はサンドボックス下で動き、読める場所が
/// com.apple.audio.coreaudiod.sb で限定されている。/Users/Shared などは
/// 許可されておらず、読もうとしても失敗するだけで拒否ログも残らない。
///
/// Audio 自体は root:_coreaudiod の 775、その下の Data は SIP の restricted で
/// アプリからは書けない。そこで install-driver.sh が Audio/Tapdeck を
/// ユーザー所有で作り、そこへ書く。
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

    /// 設定ファイルの控え。Apple 管理下のディレクトリなので、
    /// システム更新などで消える可能性を考えて手元にも持っておく。
    private static let mirrorKey = "virtualDeviceConfiguration"

    /// ドライバが設定ファイル無しのときに作る既定のデバイス。
    static let defaultDevice = Device(uid: "TapdeckDevice", name: "Tapdeck", channelCount: 2)

    // MARK: - 読み書き

    static func load() -> VirtualDeviceConfiguration {
        // ファイルが消えていたら控えから書き戻す。
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

    enum WriteError: LocalizedError {
        case cannotCreateDirectory(String)
        case cannotWrite(String)
        case driverUnavailable
        case rejected(OSStatus)

        var errorDescription: String? {
            switch self {
            case .cannotCreateDirectory(let detail):
                return "Could not create the configuration directory: \(detail)"
            case .cannotWrite(let detail):
                return "Could not write the configuration: \(detail)"
            case .driverUnavailable:
                return "The Tapdeck driver is not installed. Run: sudo ./install-driver.sh"
            case .rejected(let status):
                return "The driver rejected the device list (OSStatus \(status))"
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
                "\(directoryURL.path) がありません。sudo ./install-driver.sh を実行してください。")
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: raw,
                                                          format: .xml, options: 0)
            try data.write(to: fileURL, options: .atomic)
            // coreaudiod は _coreaudiod ユーザーなので、誰でも読める権限にする。
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
