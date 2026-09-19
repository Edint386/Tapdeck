import AVFoundation
import CoreAudio
import Foundation

// The minimum needed to drive Core Audio's C API from Swift.
// Calls to AudioObjectGetPropertyData are verbose, so they are gathered here.

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
            return "\(label) failed (OSStatus \(st) '\(String(chars))')"
        case .missing(let what):
            return "\(what) was not found"
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
        try ca("reading the property size") {
            AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size)
        }
        return size
    }

    /// Read a single fixed-size value.
    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as type: T.Type = T.self,
        label: String = "reading a property"
    ) throws -> T {
        var addr = Self.address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let buf = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buf.deallocate() }
        try ca(label) { AudioObjectGetPropertyData(self, &addr, 0, nil, &size, buf) }
        return buf.pointee
    }

    /// Read a variable-length array, such as a list of AudioObjectIDs.
    func readArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as type: T.Type = T.self,
        label: String = "reading an array property"
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

    /// Read a property that comes back as a CFString, or nil if absent.
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

/// UID of the system default output device, needed as the clock for an
/// aggregate device.
func defaultOutputDeviceUID() throws -> String {
    let deviceID: AudioDeviceID = try AudioObjectID.system.read(
        kAudioHardwarePropertyDefaultOutputDevice,
        label: "reading the default output device")
    guard let uid = AudioObjectID(deviceID).readString(kAudioDevicePropertyDeviceUID) else {
        throw CoreAudioError.missing("the default output device UID")
    }
    return uid
}

/// Make a device the Mac's output. Returns whether Core Audio accepted it.
@discardableResult
func setDefaultOutputDevice(_ device: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value = device
    return AudioObjectSetPropertyData(AudioObjectID.system, &address, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
}

extension AVAudioFormat {
    /// Non-interleaved Float32 with any number of discrete channels.
    ///
    /// `init(commonFormat:sampleRate:channels:interleaved:)` returns nil above
    /// two channels, silently. Anything multichannel has to go through a
    /// channel layout instead.
    static func discrete(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        let count = AVAudioChannelCount(max(1, channels))
        if count <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                 channels: count, interleaved: false)
        }
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(count)) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                             interleaved: false, channelLayout: layout)
    }
}
