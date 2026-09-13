import AVFoundation
import AppKit
import Combine
import Foundation

/// State for the mixer screen. Wraps the Mixer engine for use from SwiftUI.
@MainActor
final class MixerModel: ObservableObject {

    /// One source row, as displayed.
    struct Row: Identifiable {
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

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var masterLevel: Float = 0

    @Published private(set) var availableProcesses: [AudioProcess] = []
    @Published private(set) var availableInputs: [AudioDevice] = []
    @Published private(set) var outputCandidates: [AudioDevice] = []

    @Published var outputDeviceUID = "TapdeckDevice" {
        didSet { if oldValue != outputDeviceUID { persist() } }
    }

    @Published private(set) var presets: [MixerPreset] = []
    @Published private(set) var activePresetID: UUID?

    private let mixer = Mixer()
    private var meterTimer: Timer?
    private var iconCache: [String: NSImage] = [:]

    init() {
        let configuration = MixerConfiguration.load()
        outputDeviceUID = configuration.outputDeviceUID
        for entry in configuration.targets {
            let source = mixer.add(entry.target)
            source.gain = entry.gain
            source.isMuted = entry.isMuted
            source.channelOffset = entry.channelOffset
        }
        presets = MixerPresetStore.load()
        syncRows()
        status = rows.isEmpty ? "Add a source to get started" : "Restored your last setup"
    }

    // MARK: - Presets

    /// Save the current setup under a name, replacing any setup with that name.
    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let configuration = MixerConfiguration(sources: mixer.sources,
                                               outputDeviceUID: outputDeviceUID)
        if let index = presets.firstIndex(where: { $0.name == trimmed }) {
            presets[index].configuration = configuration
            activePresetID = presets[index].id
        } else {
            let preset = MixerPreset(name: trimmed, configuration: configuration)
            presets.append(preset)
            activePresetID = preset.id
        }
        MixerPresetStore.save(presets)
        status = "Saved preset \"\(trimmed)\""
    }

    /// Load a preset, replacing the current setup.
    func applyPreset(_ id: UUID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        let wasRunning = isRunning
        if wasRunning { stop() }

        mixer.removeAll()
        outputDeviceUID = preset.configuration.outputDeviceUID
        for entry in preset.configuration.targets {
            let source = mixer.add(entry.target)
            source.gain = entry.gain
            source.isMuted = entry.isMuted
            source.channelOffset = entry.channelOffset
        }
        activePresetID = id
        syncRows()
        persist()
        status = "Loaded preset \"\(preset.name)\""

        if wasRunning { start() }
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if activePresetID == id { activePresetID = nil }
        MixerPresetStore.save(presets)
    }

    func clearSources() {
        let wasRunning = isRunning
        if wasRunning { stop() }
        mixer.removeAll()
        activePresetID = nil
        syncRows()
        persist()
        status = "Removed every source"
    }

    // MARK: - Refreshing the lists

    func refresh() {
        availableProcesses = ((try? AudioProcess.all()) ?? [])
            .filter { $0.pid != ProcessInfo.processInfo.processIdentifier }
        let devices = (try? AudioDevice.all()) ?? []
        availableInputs = devices.filter(\.canInput)
        outputCandidates = devices.filter(\.canOutput)

        if outputCandidates.first(where: { $0.uid == outputDeviceUID }) == nil {
            outputDeviceUID = outputCandidates.first { $0.uid == "TapdeckDevice" }?.uid
                ?? outputCandidates.first?.uid ?? ""
        }

        // While running, reconnect to apps that have started since.
        if isRunning {
            let reattached = mixer.reattachDetached()
            if reattached > 0 { status = "Connected \(reattached) source(s)" }
        }
        syncRows()
    }

    // MARK: - Adding and removing sources

    func addApplication(_ process: AudioProcess) {
        add(.application(bundleID: process.bundleID, name: process.name, pid: process.pid))
    }

    func addSystemAudio() {
        guard !mixer.sources.contains(where: { $0.target == .systemAudio }) else {
            status = "System audio is already a source"
            return
        }
        add(.systemAudio)
    }

    func addInput(_ device: AudioDevice) {
        add(.inputDevice(uid: device.uid, name: device.name))
    }

    /// Add the default microphone in one click. "My mic plus my computer
    /// audio" is the common case, so it should not need a menu.
    func addDefaultMicrophone() {
        refresh()
        let builtIn = availableInputs.first { $0.uid == "BuiltInMicrophoneDevice" }
        guard let device = builtIn ?? availableInputs.first(where: { $0.uid != "TapdeckDevice" })
        else {
            status = "No input device found"
            return
        }
        addInput(device)
    }

    /// Add every app that is currently making sound.
    func addPlayingApplications() {
        refresh()
        let playing = availableProcesses.filter(\.isPlayingAudio)
        guard !playing.isEmpty else {
            status = "No app is playing audio right now"
            return
        }
        playing.forEach { addApplication($0) }
        status = "Added \(playing.count) app(s)"
    }

    private func add(_ target: Mixer.Target) {
        let source = mixer.add(target)
        // On a multichannel output, give a new source the first pair nobody is
        // using, so adding sources keeps them apart by default.
        let used = Set(mixer.sources.filter { $0 !== source }.map(\.channelOffset))
        if let free = channelPairs.first(where: { !used.contains($0) }) {
            source.channelOffset = free
        }
        invalidateActivePreset()
        syncRows()
        persist()
    }

    func remove(_ id: UUID) {
        mixer.remove(id: id)
        invalidateActivePreset()
        syncRows()
        persist()
    }

    func setGain(_ gain: Float, for id: UUID) {
        mixer.sources.first { $0.id == id }?.gain = gain
        syncRows()
        persist()
    }

    // MARK: - Channel mapping

    /// Channels on the chosen output device.
    var outputChannelCount: Int {
        outputCandidates.first { $0.uid == outputDeviceUID }?.outputChannels ?? 2
    }

    /// Stereo pairs a source can be placed on, as channel offsets: 0 is 1–2,
    /// 2 is 3–4, and so on. A stereo output has only the one pair.
    var channelPairs: [Int] {
        stride(from: 0, to: max(2, outputChannelCount) - 1, by: 2).map { $0 }
    }

    func setChannelOffset(_ offset: Int, for id: UUID) {
        guard let source = mixer.sources.first(where: { $0.id == id }) else { return }
        source.channelOffset = offset
        invalidateActivePreset()
        syncRows()
        persist()
    }

    /// Spread the sources across separate pairs, in list order, as far as the
    /// output allows. Once pairs run out the remaining sources share the last.
    func spreadAcrossChannels() {
        let pairs = channelPairs
        guard !pairs.isEmpty else { return }
        for (index, source) in mixer.sources.enumerated() {
            source.channelOffset = pairs[min(index, pairs.count - 1)]
        }
        invalidateActivePreset()
        syncRows()
        persist()
        status = mixer.sources.count > pairs.count
            ? "Only \(pairs.count) channel pair(s) on this output; the last pair is shared"
            : "Each source now has its own channel pair"
    }

    func toggleMute(_ id: UUID) {
        guard let source = mixer.sources.first(where: { $0.id == id }) else { return }
        source.isMuted.toggle()
        syncRows()
        persist()
    }

    private func persist() {
        MixerConfiguration(sources: mixer.sources, outputDeviceUID: outputDeviceUID).save()
    }

    /// Editing by hand clears the active preset, since it no longer matches.
    private func invalidateActivePreset() {
        activePresetID = nil
    }

    // MARK: - Building the display rows

    private func syncRows() {
        rows = mixer.sources.map { source in
            Row(id: source.id,
                label: source.label,
                kindLabel: source.target.kindLabel,
                symbolName: Self.symbolName(for: source.target),
                appIcon: icon(for: source.target),
                gain: source.gain,
                isMuted: source.isMuted,
                level: rows.first { $0.id == source.id }?.level ?? 0,
                isAttached: source.isAttached,
                detail: detail(for: source),
                channelOffset: source.channelOffset)
        }
    }

    private func detail(for source: Mixer.Source) -> String {
        if !isRunning { return "" }
        if let reason = source.detachReason { return reason }
        return source.formatDescription
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
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = image
        return image
    }

    // MARK: - Starting and stopping

    func start() {
        guard !isRunning else { return }
        guard !mixer.sources.isEmpty else {
            status = "There are no sources"
            return
        }
        guard let device = outputCandidates.first(where: { $0.uid == outputDeviceUID }) else {
            status = "Output device not found"
            return
        }
        do {
            try mixer.start(to: device)
            isRunning = true
            let attached = mixer.sources.filter(\.isAttached).count
            status = attached == mixer.sources.count
                ? "Sending \(attached) source(s) to \(device.name)"
                : "Sending to \(device.name) — \(attached) of \(mixer.sources.count) connected"
            syncRows()
            startMetering()
        } catch {
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        mixer.stop()
        isRunning = false
        stopMetering()
        masterLevel = 0
        syncRows()
        rows = rows.map { var row = $0; row.level = 0; return row }
        status = "Stopped"
    }

    func toggleRunning() { isRunning ? stop() : start() }

    // MARK: - Metering

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeters() }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func updateMeters() {
        let peaks = Dictionary(uniqueKeysWithValues:
            mixer.sources.map { ($0.id, $0.ring.takePeak()) })
        rows = rows.map { row in
            var updated = row
            // Ease the fall only; a rise is shown immediately.
            updated.level = max(peaks[row.id] ?? 0, row.level * 0.72)
            return updated
        }
        masterLevel = max(mixer.takeMasterPeak(), masterLevel * 0.72)
    }
}
