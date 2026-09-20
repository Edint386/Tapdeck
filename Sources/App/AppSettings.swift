import AppKit
import Combine
import Foundation

/// App-wide preferences, stored in UserDefaults.
///
/// Settings that the engine reads are pushed into it as they change, so the
/// engine never has to know where preferences live.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Audio

    /// How much audio every buffer holds before it plays.
    enum BufferSize: Int, CaseIterable, Identifiable {
        case low = 1024
        case balanced = 2048
        case stable = 4096
        case safest = 8192

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .low:      return "Low latency"
            case .balanced: return "Balanced"
            case .stable:   return "Stable"
            case .safest:   return "Most stable"
            }
        }

        /// Approximate delay this adds, at 48 kHz.
        var milliseconds: Int { Int((Double(rawValue) / 48_000 * 1000).rounded()) }
    }

    @Published var bufferSize: BufferSize {
        didSet {
            defaults.set(bufferSize.rawValue, forKey: Keys.bufferSize)
            Mixer.bufferCushionFrames = bufferSize.rawValue
        }
    }

    /// Volume applied last, to every output of every mix.
    @Published var masterVolume: Float {
        didSet {
            defaults.set(masterVolume, forKey: Keys.masterVolume)
            MasterVolume.shared.volume = masterVolume
        }
    }

    @Published var isMasterMuted: Bool {
        didSet {
            defaults.set(isMasterMuted, forKey: Keys.masterMuted)
            MasterVolume.shared.isMuted = isMasterMuted
        }
    }

    // MARK: - Loudness

    /// Loudness every normaliser aims for, in LUFS.
    @Published var loudnessTarget: Double {
        didSet {
            defaults.set(loudnessTarget, forKey: Keys.loudnessTarget)
            pushLoudnessTuning()
        }
    }

    /// The most a quiet programme is raised, in dB.
    @Published var loudnessMaximumBoost: Double {
        didSet {
            defaults.set(loudnessMaximumBoost, forKey: Keys.loudnessMaximumBoost)
            pushLoudnessTuning()
        }
    }

    @Published var loudnessSpeed: LoudnessTuning.Speed {
        didSet {
            defaults.set(loudnessSpeed.rawValue, forKey: Keys.loudnessSpeed)
            pushLoudnessTuning()
        }
    }

    /// Common delivery targets, loudest last.
    static let loudnessTargets: [(value: Double, title: String)] = [
        (-23, "−23 LUFS — broadcast, most headroom"),
        (-18, "−18 LUFS — quiet listening"),
        (-16, "−16 LUFS — Apple Music, podcasts"),
        (-14, "−14 LUFS — YouTube, Spotify"),
    ]

    private func pushLoudnessTuning() {
        LoudnessTuning.shared.values = LoudnessTuning.Values(target: loudnessTarget,
                                                             maximumBoost: loudnessMaximumBoost,
                                                             speed: loudnessSpeed)
    }

    // MARK: - General

    @Published var showsMenuBarItem: Bool {
        didSet { defaults.set(showsMenuBarItem, forKey: Keys.showsMenuBarItem) }
    }

    /// What a mix is recorded as.
    @Published var mixRecordingFormat: MixRecorder.FileFormat {
        didSet { defaults.set(mixRecordingFormat.rawValue, forKey: Keys.mixRecordingFormat) }
    }

    /// Bits per second for AAC recordings.
    @Published var mixRecordingBitrate: Int {
        didSet { defaults.set(mixRecordingBitrate, forKey: Keys.mixRecordingBitrate) }
    }

    /// Bits per sample for uncompressed and lossless recordings.
    @Published var mixRecordingBitDepth: Int {
        didSet { defaults.set(mixRecordingBitDepth, forKey: Keys.mixRecordingBitDepth) }
    }

    /// Where screen recordings are written.
    @Published var recordingFolder: URL {
        didSet { defaults.set(recordingFolder.path, forKey: Keys.recordingFolder) }
    }

    static let defaultRecordingFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Movies/Tapdeck", isDirectory: true)

    // MARK: -

    private enum Keys {
        static let bufferSize = "settings.bufferSize"
        static let masterVolume = "settings.masterVolume"
        static let masterMuted = "settings.masterMuted"
        static let loudnessTarget = "settings.loudnessTarget"
        static let loudnessMaximumBoost = "settings.loudnessMaximumBoost"
        static let loudnessSpeed = "settings.loudnessSpeed"
        static let showsMenuBarItem = "settings.showsMenuBarItem"
        static let recordingFolder = "settings.recordingFolder"
        static let mixRecordingFormat = "settings.mixRecordingFormat"
        static let mixRecordingBitrate = "settings.mixRecordingBitrate"
        static let mixRecordingBitDepth = "settings.mixRecordingBitDepth"
    }

    private init() {
        bufferSize = BufferSize(rawValue: defaults.integer(forKey: Keys.bufferSize)) ?? .balanced
        showsMenuBarItem = defaults.object(forKey: Keys.showsMenuBarItem) as? Bool ?? true
        mixRecordingFormat = defaults.string(forKey: Keys.mixRecordingFormat)
            .flatMap(MixRecorder.FileFormat.init(rawValue:)) ?? .aac
        let storedBitrate = defaults.integer(forKey: Keys.mixRecordingBitrate)
        mixRecordingBitrate = MixRecorder.bitrates.contains(storedBitrate) ? storedBitrate : 256_000
        let storedDepth = defaults.integer(forKey: Keys.mixRecordingBitDepth)
        mixRecordingBitDepth = MixRecorder.bitDepths.contains(storedDepth) ? storedDepth : 24
        recordingFolder = defaults.string(forKey: Keys.recordingFolder)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultRecordingFolder

        // Only turns down: a boost here pushed every output into the ceiling.
        masterVolume = min(1, defaults.object(forKey: Keys.masterVolume) as? Float ?? 1)
        isMasterMuted = defaults.bool(forKey: Keys.masterMuted)

        let tuning = LoudnessTuning.Values()
        loudnessTarget = defaults.object(forKey: Keys.loudnessTarget) as? Double ?? tuning.target
        loudnessMaximumBoost = defaults.object(forKey: Keys.loudnessMaximumBoost) as? Double ?? tuning.maximumBoost
        loudnessSpeed = defaults.string(forKey: Keys.loudnessSpeed)
            .flatMap(LoudnessTuning.Speed.init(rawValue:)) ?? tuning.speed

        // Property observers do not run during init, so apply engine-facing
        // values explicitly.
        Mixer.bufferCushionFrames = bufferSize.rawValue
        MasterVolume.shared.volume = masterVolume
        MasterVolume.shared.isMuted = isMasterMuted
        pushLoudnessTuning()
    }

    /// Ask for a folder with the standard panel.
    func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = recordingFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            recordingFolder = url
        }
    }
}
