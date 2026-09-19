import CoreAudio
import Foundation

/// A device's own output volume: the one the volume keys change while the
/// device is the Mac's output.
///
/// Turning an output up here makes it really louder, up to the device's
/// maximum, without touching the signal. Boosting the signal instead can only
/// push it into the ceiling, which is heard as distortion. It also frees a
/// device that is not the Mac's output from whatever volume it was left at,
/// since the volume keys cannot reach it.
///
/// The volume is the device's, not the mix's: every app playing to the device
/// hears the change.
enum DeviceVolume {

    /// Elements that carry a settable volume: the main element when the device
    /// has one, otherwise each channel. Empty when the device has no volume of
    /// its own, as virtual devices do.
    static func elements(of device: AudioDeviceID, channels: Int) -> [UInt32] {
        if isSettable(device, kAudioDevicePropertyVolumeScalar, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        return (1...max(1, channels)).map(UInt32.init).filter {
            isSettable(device, kAudioDevicePropertyVolumeScalar, element: $0)
        }
    }

    /// Volume from 0 to 1 on the device's own scale, or nil if it has none.
    static func volume(of device: AudioDeviceID, channels: Int) -> Float? {
        let values = elements(of: device, channels: channels).compactMap {
            read(device, kAudioDevicePropertyVolumeScalar, element: $0, as: Float32.self)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    /// Set the volume on every element. Raising it above zero also unmutes,
    /// as the volume keys do.
    static func setVolume(_ volume: Float, of device: AudioDeviceID, channels: Int) {
        var value = Float32(min(1, max(0, volume)))
        for element in elements(of: device, channels: channels) {
            var address = self.address(kAudioDevicePropertyVolumeScalar, element: element)
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
        if value > 0, isMuted(device) == true { setMuted(false, device: device) }
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool? {
        read(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain, as: UInt32.self)
            .map { $0 != 0 }
    }

    static func setMuted(_ muted: Bool, device: AudioDeviceID) {
        guard isSettable(device, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain) else { return }
        var value: UInt32 = muted ? 1 : 0
        var address = self.address(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // MARK: - Helpers

    fileprivate static func address(_ selector: AudioObjectPropertySelector,
                                    element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    private static func isSettable(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                   element: UInt32) -> Bool {
        var address = self.address(selector, element: element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func read<T>(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                                element: UInt32, as: T.Type) -> T? {
        var address = self.address(selector, element: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }
}

/// Calls back on the main queue whenever the volume or mute of any watched
/// device changes, from Tapdeck or from anywhere else — the volume keys, the
/// menu bar, System Settings. Listeners, not polling.
final class DeviceVolumeObserver {
    private var registrations: [(AudioDeviceID, AudioObjectPropertyAddress)] = []
    private let block: AudioObjectPropertyListenerBlock

    init(devices: [(id: AudioDeviceID, channels: Int)], onChange: @escaping () -> Void) {
        block = { _, _ in onChange() }
        for device in devices {
            let elements = [kAudioObjectPropertyElementMain] + (1...max(1, device.channels)).map(UInt32.init)
            var addresses = elements.map { DeviceVolume.address(kAudioDevicePropertyVolumeScalar, element: $0) }
            addresses.append(DeviceVolume.address(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain))
            for var address in addresses where AudioObjectHasProperty(device.id, &address) {
                if AudioObjectAddPropertyListenerBlock(device.id, &address, .main, block) == noErr {
                    registrations.append((device.id, address))
                }
            }
        }
    }

    deinit {
        for (device, address) in registrations {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
        }
    }
}
