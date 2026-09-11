import Foundation

/// ドライバが公開する仮想デバイスの一覧。
///
/// アプリが書き、ドライバ（coreaudiod 内）が監視して増減を反映する。
/// 置き場所が /Users/Shared なのは、coreaudiod が _coreaudiod ユーザーで動くため
/// ユーザーのホームを読めず、かといって /Library へアプリが書くには管理者権限が
/// 要るため。ここは両方の条件を満たす数少ない場所。
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

    static let directoryURL = URL(fileURLWithPath: "/Users/Shared/Tapdeck", isDirectory: true)
    static let fileURL = directoryURL.appendingPathComponent("Devices.plist")

    /// ドライバが設定ファイル無しのときに作る既定のデバイス。
    static let defaultDevice = Device(uid: "TapdeckDevice", name: "Tapdeck", channelCount: 2)

    // MARK: - 読み書き

    static func load() -> VirtualDeviceConfiguration {
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

        var errorDescription: String? {
            switch self {
            case .cannotCreateDirectory(let detail):
                return "設定の置き場所を作れませんでした: \(detail)"
            case .cannotWrite(let detail):
                return "設定を書き込めませんでした: \(detail)"
            }
        }
    }

    func save() throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: Self.directoryURL.path) {
            do {
                // coreaudiod から読めるよう、誰でも読める権限で作る。
                try manager.createDirectory(
                    at: Self.directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755])
            } catch {
                throw WriteError.cannotCreateDirectory(error.localizedDescription)
            }
        }

        let raw = devices.map { device -> [String: Any] in
            ["UID": device.uid, "Name": device.name, "Channels": device.channelCount]
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: raw,
                                                          format: .xml, options: 0)
            try data.write(to: Self.fileURL, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Self.fileURL.path)
        } catch {
            throw WriteError.cannotWrite(error.localizedDescription)
        }
    }

    /// ドライバは2秒ごとに設定を読み直す。書いてから反映されるまでの目安。
    static let propagationDelay: TimeInterval = 3
}
