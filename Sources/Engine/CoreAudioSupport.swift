import CoreAudio
import Foundation

// Core Audio の C API を Swift から扱うための最小限の下地。
// AudioObjectGetPropertyData の呼び出しは定型が長いので、ここに集約する。

enum CoreAudioError: LocalizedError {
    case status(String, OSStatus)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .status(let label, let st):
            var code = st.bigEndian
            let chars = withUnsafeBytes(of: &code) { raw in
                raw.map { b -> Character in
                    let s = Character(UnicodeScalar(b))
                    return s.isLetter || s.isNumber || s.isPunctuation ? s : "?"
                }
            }
            return "\(label) が失敗しました (OSStatus \(st) '\(String(chars))')"
        case .missing(let what):
            return "\(what) が見つかりません"
        }
    }
}

@discardableResult
func ca(_ label: String, _ body: () -> OSStatus) throws -> OSStatus {
    let st = body()
    guard st == noErr else { throw CoreAudioError.status(label, st) }
    return st
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func propertySize(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> UInt32 {
        var addr = Self.address(selector, scope)
        var size: UInt32 = 0
        try ca("プロパティサイズの取得") {
            AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size)
        }
        return size
    }

    /// 固定長の値を1つ読む。
    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as type: T.Type = T.self,
        label: String = "プロパティの読み取り"
    ) throws -> T {
        var addr = Self.address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let buf = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buf.deallocate() }
        try ca(label) { AudioObjectGetPropertyData(self, &addr, 0, nil, &size, buf) }
        return buf.pointee
    }

    /// 可変長の配列を読む（AudioObjectID の一覧など）。
    func readArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as type: T.Type = T.self,
        label: String = "配列プロパティの読み取り"
    ) throws -> [T] {
        let size = try propertySize(selector, scope: scope)
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }

        var addr = Self.address(selector, scope)
        var mutableSize = size
        let buf = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
        defer { buf.deallocate() }

        try ca(label) {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &mutableSize, buf.baseAddress!)
        }
        return Array(buf.prefix(Int(mutableSize) / MemoryLayout<T>.stride))
    }

    /// CFString で返るプロパティを読む。値が無い場合は nil。
    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = Self.address(selector, scope)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let st = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, ptr)
        }
        guard st == noErr else { return nil }
        return value as String?
    }

    func hasProperty(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var addr = Self.address(selector, scope)
        return AudioObjectHasProperty(self, &addr)
    }
}

/// システムの既定出力デバイスの UID。集約デバイスのクロック源として必要。
func defaultOutputDeviceUID() throws -> String {
    let deviceID: AudioDeviceID = try AudioObjectID.system.read(
        kAudioHardwarePropertyDefaultOutputDevice,
        label: "既定の出力デバイスの取得")
    guard let uid = AudioObjectID(deviceID).readString(kAudioDevicePropertyDeviceUID) else {
        throw CoreAudioError.missing("既定出力デバイスの UID")
    }
    return uid
}
