import AVFoundation
import AppKit
import Combine
import Foundation

/// One mix: its sources, its outputs, and whether it is running.
///
/// Several of these can run at the same time, each with its own engine.
@MainActor
final class MixSession: ObservableObject, Identifiable {

    /// One source row, as displayed.
    struct SourceRow: Identifiable {
        let id: UUID
        let label: String
        let kindLabel: String
        let symbolName: String
        let appIcon: NSImage?
        var gain: Float
        var isMuted: Bool
        var level: Float
        var isAttached: Bool
        var detail: String
        var channelOffset: Int
    }

    /// One output row, as displayed.
    struct OutputRow: Identifiable {
        let id: UUID
        let deviceUID: String
        let name: String
        var gain: Float
        var isMuted: Bool
        var level: Float
        /// First in the list: its clock drives the mix.
        var isPrimary: Bool
        var isAttached: Bool
        var detail: String
    }

    let id: UUID
    @Published var name: String {
        didSet { if oldValue != name { changed() } }
    }

    @Published private(set) var sources: [SourceRow] = []
    @Published private(set) var outputs: [OutputRow] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var level: Float = 0

    /// This mix's volume: one fader for everything it sends.
    @Published var volume: Float = 1 {
        didSet {
            engine.volume = volume
            if oldValue != volume { changed() }
        }
    }

    /// Silences everything the mix sends while keeping it running.
    @Published var isMuted = false {
        didSet {
            engine.isMuted = isMuted
            if oldValue != isMuted { changed() }
        }
    }

    private let engine = Mixer()
    private weak var library: MixerModel?
    private var iconCache: [String: NSImage] = [:]

    init(saved: SavedMix, library: MixerModel) {
        id = saved.id
        name = saved.name
        self.library = library

        var stored = MixerConfiguration()
        stored.sources = saved.sources
        for entry in stored.targets {
            let source = engine.add(entry.target)
            source.gain = entry.gain
            source.isMuted = entry.isMuted
            source.channelOffset = entry.channelOffset
        }
        volume = saved.volume ?? 1
        isMuted = saved.isMuted ?? false
        engine.volume = volume
        engine.isMuted = isMuted
        for savedOutput in saved.outputs {
            let output = engine.addOutput(uid: savedOutput.uid, name: savedOutput.name)
            output.gain = savedOutput.gain
            output.isMuted = savedOutput.isMuted
        }
        syncRows()
    }

    var saved: SavedMix {
        SavedMix(id: id,
                 name: name,
                 sources: MixerConfiguration(sources: engine.sources, outputDeviceUID: "").sources,
                 outputs: engine.outputs.map {
                     SavedOutput(uid: $0.deviceUID, name: $0.deviceName, gain: $0.gain, isMuted: $0.isMuted)
                 },
                 volume: volume,
                 isMuted: isMuted)
    }

    /// Device UIDs this mix captures from, for feedback checks.
    var inputDeviceUIDs: [String] {
        engine.sources.compactMap {
            if case .inputDevice(let uid, _) = $0.target { return uid }
            return nil
        }
    }

    var outputDeviceUIDs: [String] { engine.outputs.map(\.deviceUID) }

    /// A short line describing where this mix goes.
    var outputSummary: String {
        let names = engine.outputs.map(\.deviceName)
        return names.isEmpty ? "No output" : names.joined(separator: " + ")
    }

    private func changed() {
        library?.persist()
    }

    // MARK: - Sources

    func addApplication(_ process: AudioProcess) {
        addSource(.application(bundleID: process.bundleID, name: process.name, pid: process.pid))
    }

    func addSystemAudio() {
        guard !engine.sources.contains(where: { $0.target == .systemAudio }) else {
            status = "System audio is already a source"
            return
        }
        addSource(.systemAudio)
    }

    func addInput(_ device: AudioDevice) {
        if let problem = library?.feedbackProblem(for: self, addingInput: device.uid) {
            status = problem
            return
        }
        addSource(.inputDevice(uid: device.uid, name: device.name))
    }

    /// Add the default microphone in one click. "My mic plus my computer
    /// audio" is the common case, so it should not need a menu.
    func addDefaultMicrophone() {
        guard let inputs = library?.availableInputs else { return }
        let builtIn = inputs.first { $0.uid == "BuiltInMicrophoneDevice" }
        guard let device = builtIn ?? inputs.first(where: { !MixerModel.isVirtual($0.uid) }) else {
            status = "No input device found"
            return
        }
        addInput(device)
    }

    /// Add every app that is currently making sound.
    func addPlayingApplications() {
        library?.refresh()
        let playing = library?.availableProcesses.filter(\.isPlayingAudio) ?? []
        guard !playing.isEmpty else {
            status = "No app is playing audio right now"
            return
        }
        playing.forEach { addApplication($0) }
        status = "Added \(playing.count) app(s)"
    }

    private func addSource(_ target: Mixer.Target) {
        let source = engine.add(target)
        // On a multichannel output, give a new source the first pair nobody is
        // using, so adding sources keeps them apart by default.
        let used = Set(engine.sources.filter { $0 !== source }.map(\.channelOffset))
        if let free = channelPairs.first(where: { !used.contains($0) }) {
            source.channelOffset = free
        }
        syncRows()
        changed()
    }

    func removeSource(_ id: UUID) {
        engine.remove(id: id)
        syncRows()
        changed()
    }

    func removeAllSources() {
        engine.removeAll()
        syncRows()
        changed()
    }

    func setSourceGain(_ gain: Float, for id: UUID) {
        engine.sources.first { $0.id == id }?.gain = gain
        syncRows()
        changed()
    }

    func toggleSourceMute(_ id: UUID) {
        guard let source = engine.sources.first(where: { $0.id == id }) else { return }
        source.isMuted.toggle()
        syncRows()
        changed()
    }

    // MARK: - Channel mapping

    /// Channels on the primary output, the one channel placement refers to.
    var outputChannelCount: Int {
        if isRunning { return engine.outputChannelCount }
        guard let first = engine.outputs.first else { return 2 }
        return library?.outputCandidates.first { $0.uid == first.deviceUID }?.outputChannels ?? 2
    }

    /// Stereo pairs a source can be placed on, as channel offsets: 0 is 1–2,
    /// 2 is 3–4, and so on.
    var channelPairs: [Int] {
        stride(from: 0, to: max(2, outputChannelCount) - 1, by: 2).map { $0 }
    }

    func setChannelOffset(_ offset: Int, for id: UUID) {
        engine.sources.first { $0.id == id }?.channelOffset = offset
        syncRows()
        changed()
    }

    /// Give every source its own pair, in list order, as far as the output
    /// allows. Once pairs run out the remaining sources share the last.
    func spreadAcrossChannels() {
        let pairs = channelPairs
        guard !pairs.isEmpty else { return }
        for (index, source) in engine.sources.enumerated() {
            source.channelOffset = pairs[min(index, pairs.count - 1)]
        }
        syncRows()
        changed()
        status = engine.sources.count > pairs.count
            ? "Only \(pairs.count) channel pair(s) on this output; the last pair is shared"
            : "Each source now has its own channel pair"
    }

    // MARK: - Outputs

    func addOutput(_ device: AudioDevice) {
        guard !engine.outputs.contains(where: { $0.deviceUID == device.uid }) else {
            status = "\(device.name) is already an output"
            return
        }
        if let problem = library?.feedbackProblem(for: self, addingOutput: device.uid) {
            status = problem
            return
        }
        engine.addOutput(uid: device.uid, name: device.name)
        afterOutputChange()
    }

    /// Add the system's current output device, so you can hear the mix.
    func addListeningOutput() {
        guard let device = library?.defaultOutputDevice else {
            status = "Could not find the system output device"
            return
        }
        addOutput(device)
    }

    func removeOutput(_ id: UUID) {
        engine.removeOutput(id: id)
        afterOutputChange()
    }

    func makePrimary(_ id: UUID) {
        engine.makePrimary(id: id)
        afterOutputChange()
    }

    func setOutputGain(_ gain: Float, for id: UUID) {
        engine.outputs.first { $0.id == id }?.gain = gain
        syncRows()
        changed()
    }

    func toggleOutputMute(_ id: UUID) {
        guard let output = engine.outputs.first(where: { $0.id == id }) else { return }
        output.isMuted.toggle()
        syncRows()
        changed()
    }

    /// The engine restarts itself when outputs change while running; reflect
    /// whatever state it ended up in.
    private func afterOutputChange() {
        if isRunning && !engine.isRunning {
            isRunning = false
            status = "Stopped: the outputs could not be reopened"
            library?.sessionStateChanged()
        }
        syncRows()
        changed()
    }

    // MARK: - Running

    func start() {
        guard !isRunning else { return }
        guard !engine.sources.isEmpty else { status = "Add a source first"; return }
        guard !engine.outputs.isEmpty else { status = "Add an output first"; return }
        if let problem = library?.feedbackProblem(for: self) {
            status = problem
            return
        }
        do {
            try engine.start()
            isRunning = true
            let attached = engine.sources.filter(\.isAttached).count
            let outputsOpen = engine.outputs.filter(\.isAttached).count
            status = "Running — \(attached) of \(engine.sources.count) source(s), "
                   + "\(outputsOpen) of \(engine.outputs.count) output(s)"
        } catch {
            status = "Could not start: \(error.localizedDescription)"
        }
        syncRows()
        library?.sessionStateChanged()
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        isRunning = false
        level = 0
        syncRows()
        sources = sources.map { var row = $0; row.level = 0; return row }
        outputs = outputs.map { var row = $0; row.level = 0; return row }
        status = "Stopped"
        library?.sessionStateChanged()
    }

    func toggleRunning() { isRunning ? stop() : start() }

    /// Reconnect sources whose app has started since.
    func reattach() {
        guard isRunning else { return }
        let count = engine.reattachDetached()
        if count > 0 { status = "Connected \(count) source(s)" }
        syncRows()
    }

    // MARK: - Metering

    func updateMeters() {
        guard isRunning else { return }
        let sourcePeaks = Dictionary(uniqueKeysWithValues: engine.sources.map { ($0.id, $0.ring.takePeak()) })
        let outputPeaks = Dictionary(uniqueKeysWithValues: engine.outputs.map { ($0.id, $0.takePeak()) })
        // Ease the fall only; a rise is shown immediately.
        sources = sources.map { var row = $0; row.level = max(sourcePeaks[row.id] ?? 0, row.level * 0.72); return row }
        outputs = outputs.map { var row = $0; row.level = max(outputPeaks[row.id] ?? 0, row.level * 0.72); return row }
        level = max(outputs.first(where: \.isPrimary)?.level ?? 0, level * 0.72)
    }

    // MARK: - Building the display rows

    private func syncRows() {
        sources = engine.sources.map { source in
            SourceRow(id: source.id,
                      label: source.label,
                      kindLabel: source.target.kindLabel,
                      symbolName: Self.symbolName(for: source.target),
                      appIcon: icon(for: source.target),
                      gain: source.gain,
                      isMuted: source.isMuted,
                      level: sources.first { $0.id == source.id }?.level ?? 0,
                      isAttached: source.isAttached,
                      detail: isRunning ? (source.detachReason ?? source.formatDescription) : "",
                      channelOffset: source.channelOffset)
        }
        outputs = engine.outputs.enumerated().map { index, output in
            OutputRow(id: output.id,
                      deviceUID: output.deviceUID,
                      name: output.deviceName,
                      gain: output.gain,
                      isMuted: output.isMuted,
                      level: outputs.first { $0.id == output.id }?.level ?? 0,
                      isPrimary: isRunning ? output.isPrimary : index == 0,
                      isAttached: output.isAttached,
                      detail: outputDetail(output))
        }
    }

    private func outputDetail(_ output: Mixer.Output) -> String {
        guard isRunning else { return "" }
        if let reason = output.detachReason { return reason }
        return "\(Int(output.sampleRate)) Hz / \(output.channelCount)ch"
    }

    private static func symbolName(for target: Mixer.Target) -> String {
        switch target {
        case .application: return "app.badge"
        case .systemAudio: return "speaker.wave.3.fill"
        case .inputDevice: return "mic.fill"
        }
    }

    /// App icons come from the bundle identifier, so they work even when the
    /// app is not running.
    private func icon(for target: Mixer.Target) -> NSImage? {
        guard case .application(let bundleID, _, _) = target, let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = image
        return image
    }
}
