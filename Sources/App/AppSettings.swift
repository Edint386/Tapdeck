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

    // MARK: - General

    @Published var showsMenuBarItem: Bool {
        didSet { defaults.set(showsMenuBarItem, forKey: Keys.showsMenuBarItem) }
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
        static let showsMenuBarItem = "settings.showsMenuBarItem"
        static let recordingFolder = "settings.recordingFolder"
    }

    private init() {
        bufferSize = BufferSize(rawValue: defaults.integer(forKey: Keys.bufferSize)) ?? .balanced
        showsMenuBarItem = defaults.object(forKey: Keys.showsMenuBarItem) as? Bool ?? true
        recordingFolder = defaults.string(forKey: Keys.recordingFolder)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultRecordingFolder

        // Property observers do not run during init, so apply engine-facing
        // values explicitly.
        Mixer.bufferCushionFrames = bufferSize.rawValue
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
