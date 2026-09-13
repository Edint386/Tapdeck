import AVFoundation
import AppKit
import Combine
import CoreAudio
import Foundation

/// Every mix the user has set up, plus the device and application lists they
/// all draw from.
///
/// Mixes run independently, so any number can be active at once. What they
/// cannot do is form a loop between them, and that is checked here, where every
/// mix is visible.
@MainActor
final class MixerModel: ObservableObject {

    @Published private(set) var mixes: [MixSession] = []
    @Published var selectedMixID: UUID?

    /// How many mixes are running. Drives the menu bar icon.
    @Published private(set) var runningCount = 0

    @Published private(set) var availableProcesses: [AudioProcess] = []
    @Published private(set) var availableInputs: [AudioDevice] = []
    @Published private(set) var outputCandidates: [AudioDevice] = []

    private var meterTimer: Timer?

    init() {
        refreshLists()
        mixes = MixLibraryStore.load().map { MixSession(saved: $0, library: self) }
        selectedMixID = mixes.first?.id

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.mixes.forEach { $0.updateMeters() }
            }
        }
    }

    var selectedMix: MixSession? {
        mixes.first { $0.id == selectedMixID } ?? mixes.first
    }

    // MARK: - Lists

    func refresh() {
        refreshLists()
        mixes.forEach { $0.reattach() }
    }

    private func refreshLists() {
        availableProcesses = ((try? AudioProcess.all()) ?? [])
            .filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
        // Aggregate devices that AVAudioEngine leaves behind are not useful
        // destinations and only confuse the list.
        let devices = ((try? AudioDevice.all()) ?? [])
            .filter { !$0.uid.hasPrefix("CADefaultDeviceAggregate") }
        availableInputs = devices.filter(\.canInput)
        outputCandidates = devices.filter(\.canOutput)
    }

    static func isVirtual(_ uid: String) -> Bool { uid.hasPrefix("TapdeckDevice") }

    /// Somewhere you can actually hear: the system output, unless that has been
    /// pointed at a Tapdeck device, in which case the first real output.
    var defaultOutputDevice: AudioDevice? {
        if let uid = try? defaultOutputDeviceUID(), !Self.isVirtual(uid),
           let device = outputCandidates.first(where: { $0.uid == uid }) {
            return device
        }
        return outputCandidates.first { !Self.isVirtual($0.uid) }
    }

    func deviceName(_ uid: String) -> String {
        (outputCandidates + availableInputs).first { $0.uid == uid }?.name ?? uid
    }

    // MARK: - Managing mixes

    @discardableResult
    func addMix() -> MixSession {
        let virtual = outputCandidates.first { $0.uid == VirtualDeviceConfiguration.defaultDevice.uid }
            ?? outputCandidates.first { Self.isVirtual($0.uid) }
        let saved = SavedMix(name: nextName("Mix"),
                             sources: [],
                             outputs: virtual.map { [SavedOutput(uid: $0.uid, name: $0.name)] } ?? [])
        return insert(saved)
    }

    /// A mix that plays a virtual device's input side to your speakers.
    ///
    /// This is for when the system output has been set to a Tapdeck device so
    /// that apps play into it: without this, you would hear nothing at all.
    func addMonitor(for device: AudioDevice) {
        guard let speakers = defaultOutputDevice else { return }
        var source = MixerConfiguration.Source(kind: .inputDevice, identifier: device.uid,
                                               name: device.name, gain: 1, isMuted: false)
        source.channelOffset = 0
        let mix = insert(SavedMix(name: nextName("Listen to \(device.name)"),
                                  sources: [source],
                                  outputs: [SavedOutput(uid: speakers.uid, name: speakers.name)]))
        mix.start()
    }

    func duplicate(_ id: UUID) {
        guard let original = mixes.first(where: { $0.id == id }) else { return }
        var copy = original.saved
        copy.id = UUID()
        copy.name = nextName(original.name)
        insert(copy, after: id)
    }

    func delete(_ id: UUID) {
        guard let index = mixes.firstIndex(where: { $0.id == id }) else { return }
        mixes[index].stop()
        mixes.remove(at: index)
        if selectedMixID == id {
            selectedMixID = mixes.isEmpty ? nil : mixes[min(index, mixes.count - 1)].id
        }
        sessionStateChanged()
        persist()
    }

    @discardableResult
    private func insert(_ saved: SavedMix, after id: UUID? = nil) -> MixSession {
        let session = MixSession(saved: saved, library: self)
        if let id, let index = mixes.firstIndex(where: { $0.id == id }) {
            mixes.insert(session, at: index + 1)
        } else {
            mixes.append(session)
        }
        selectedMixID = session.id
        persist()
        return session
    }

    private func nextName(_ base: String) -> String {
        let names = Set(mixes.map(\.name))
        if !names.contains(base) { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    func stopAll() {
        mixes.forEach { $0.stop() }
    }

    // MARK: - State

    func persist() {
        MixLibraryStore.save(mixes.map(\.saved))
    }

    func sessionStateChanged() {
        runningCount = mixes.filter(\.isRunning).count
    }

    // MARK: - Feedback

    /// Explain why running this mix — with an optional extra source or output —
    /// would create a feedback loop, or return nil if it would not.
    ///
    /// Audio flows from a device a mix captures to every device that mix plays
    /// into. Across all running mixes that forms a graph, and any cycle in it
    /// is a loop: one mix capturing Streaming and playing to Meetings while
    /// another captures Meetings and plays to Streaming will howl.
    func feedbackProblem(for session: MixSession,
                         addingOutput: String? = nil,
                         addingInput: String? = nil) -> String? {
        var edges: [String: Set<String>] = [:]
        for mix in mixes where mix.isRunning || mix === session {
            var inputs = mix.inputDeviceUIDs
            var outputs = mix.outputDeviceUIDs
            if mix === session {
                if let addingInput { inputs.append(addingInput) }
                if let addingOutput { outputs.append(addingOutput) }
            }
            for input in inputs {
                edges[input, default: []].formUnion(outputs)
            }
        }

        // Depth-first search for a path that returns to where it started.
        func cycle(from start: String) -> [String]? {
            var stack: [(node: String, path: [String])] = [(start, [start])]
            var visited: Set<String> = []
            while let (node, path) = stack.popLast() {
                for next in edges[node] ?? [] {
                    if next == start { return path + [start] }
                    if visited.insert(next).inserted { stack.append((next, path + [next])) }
                }
            }
            return nil
        }

        for node in edges.keys.sorted() {
            if let loop = cycle(from: node) {
                let route = loop.map(deviceName).joined(separator: " → ")
                return "This would feed back on itself: \(route)"
            }
        }
        return nil
    }
}
