import AppKit
import CoreAudio
import Foundation

/// Core Audio が「音を扱っている」と認識しているプロセス1つ分。
///
/// 重要: Process Tap に渡すのは PID ではなく `objectID`（AudioObjectID）。
/// PID から引くには kAudioHardwarePropertyTranslatePIDToProcessObject を使う。
struct AudioProcess: Identifiable, Hashable {
    var id: AudioObjectID { objectID }

    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let isPlayingAudio: Bool

    /// Core Audio が知っている全プロセスを列挙する。
    static func all() throws -> [AudioProcess] {
        let ids: [AudioObjectID] = try AudioObjectID.system.readArray(
            kAudioHardwarePropertyProcessObjectList,
            label: "オーディオプロセス一覧の取得")

        return ids.compactMap { obj -> AudioProcess? in
            guard let pid: pid_t = try? obj.read(kAudioProcessPropertyPID,
                                                 label: "PID の取得") else { return nil }
            let bundleID = obj.readString(kAudioProcessPropertyBundleID)
            let running: UInt32 = (try? obj.read(kAudioProcessPropertyIsRunningOutput)) ?? 0

            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName
                ?? bundleID?.components(separatedBy: ".").last
                ?? "PID \(pid)"

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

    /// PID から探す。見つからなければ nil。
    static func find(pid: pid_t) throws -> AudioProcess? {
        try all().first { $0.pid == pid }
    }

    /// バンドルIDまたは表示名の部分一致で探す。
    static func find(matching needle: String) throws -> AudioProcess? {
        let procs = try all()
        if let exact = procs.first(where: { $0.bundleID == needle }) { return exact }
        return procs.first {
            $0.name.localizedCaseInsensitiveContains(needle)
                || ($0.bundleID?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }
}
