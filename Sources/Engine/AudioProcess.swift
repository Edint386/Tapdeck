import AppKit
import CoreAudio
import Darwin
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
            // 空文字で返ることがある。そのまま持つと「バンドルIDあり」と
            // 誤判定し、保存・復元で別プロセスと取り違える。
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

    /// 表示名を決める。
    ///
    /// GUI アプリでない音源（コマンドラインツール、ヘルパープロセス）は
    /// NSRunningApplication から名前を取れない。空文字が返ることもあるので、
    /// 実行ファイル名まで順に辿る。
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

    /// libproc から実行ファイル名を引く。
    private static func executableName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
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
