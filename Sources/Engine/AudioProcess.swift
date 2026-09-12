import AppKit
import CoreAudio
import Darwin
import Foundation

/// One process that Core Audio considers to be dealing with audio.
///
/// Note that a process tap takes `objectID` (an AudioObjectID), not a PID.
/// Use kAudioHardwarePropertyTranslatePIDToProcessObject to go from a PID.
struct AudioProcess: Identifiable, Hashable {
    var id: AudioObjectID { objectID }

    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let isPlayingAudio: Bool

    /// Enumerate every process Core Audio knows about.
    static func all() throws -> [AudioProcess] {
        let ids: [AudioObjectID] = try AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList,
            label: "reading the audio process list")

        return ids.compactMap { obj -> AudioProcess? in
            guard let pid: pid_t = try? obj.read(kAudioProcessPropertyPID,
                                                 label: "reading the PID") else { return nil }
            // This can come back as an empty string. Keeping it would count as
            // "has a bundle ID" and match the wrong process when restoring.
            let bundleID = obj.readString(kAudioProcessPropertyBundleID)
                .flatMap { $0.isEmpty ? nil : $0 }
            let running: UInt32 = (try? obj.read(kAudioProcessPropertyIsRunningOutput)) ?? 0

            let name = Self.displayName(pid: pid, bundleID: bundleID)

            return AudioProcess(objectID: obj,
                                pid: pid,
                                bundleID: bundleID,
                                name: name,
                                isPlayingAudio: running != 0)
        }
        .sorted {
            if $0.isPlayingAudio != $1.isPlayingAudio { return $0.isPlayingAudio }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Work out a name to show.
    ///
    /// Sources that are not GUI applications (command line tools, helper
    /// processes) have no name in NSRunningApplication, and it can hand back an
    /// empty string, so fall through as far as the executable name.
    private static func displayName(pid: pid_t, bundleID: String?) -> String {
        if let localized = NSRunningApplication(processIdentifier: pid)?.localizedName,
           !localized.isEmpty {
            return localized
        }
        if let component = bundleID?.components(separatedBy: ".").last, !component.isEmpty {
            return component
        }
        if let executable = executableName(pid: pid), !executable.isEmpty {
            return executable
        }
        return "PID \(pid)"
    }

    /// Ask libproc for the executable name.
    private static func executableName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Find by PID, or nil if there is no such process.
    static func find(pid: pid_t) throws -> AudioProcess? {
        try all().first { $0.pid == pid }
    }

    /// Find by bundle identifier, or by a partial match on the display name.
    static func find(matching needle: String) throws -> AudioProcess? {
        let procs = try all()
        if let exact = procs.first(where: { $0.bundleID == needle }) { return exact }
        return procs.first {
            $0.name.localizedCaseInsensitiveContains(needle)
                || ($0.bundleID?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }
}
