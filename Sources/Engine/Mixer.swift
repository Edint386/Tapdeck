import AVFoundation
import AppKit
import CoreAudio
import Foundation

/// Combines several sources into one output device.
///
/// This is the part Loopback calls bundling sources onto a virtual device.
/// Point the output at a Tapdeck virtual device and Zoom or OBS can pick its
/// input side as a microphone, which is how "share my mic and my computer
/// audio" works.
///
///     app audio (process tap) ┐
///     all system audio        ├→ [convert] → [ring buffer] → sum → output device
///     microphone / interface  ┘
final class Mixer: @unchecked Sendable {

    /// What a source refers to.
    ///
    /// The concrete AudioProcess or AudioDevice is resolved when the mixer
    /// starts. Applications get a new PID every launch, so they are identified
    /// by bundle identifier; without that, a saved configuration would fail to
    /// reconnect next time.
    enum Target: Equatable {
        /// `pid` pins the exact process chosen in this session. It is never
        /// saved: after a relaunch the process is found again by bundle
        /// identifier. Without it, two processes sharing a name — two instances
        /// of one app, or two helper tools — would both resolve to whichever
        /// was found first, and one source would silently tap the other's audio.
        case application(bundleID: String?, name: String, pid: pid_t? = nil)
        case systemAudio
        case inputDevice(uid: String, name: String)

        var label: String {
            switch self {
            case .application(_, let name, _): return name
            case .systemAudio:              return "All system audio"
            case .inputDevice(_, let name): return name
            }
        }

        var kindLabel: String {
            switch self {
            case .application: return "App"
            case .systemAudio: return "System"
            case .inputDevice: return "Input"
            }
        }

        /// Whether this can be saved. A process with no bundle identifier
        /// cannot be found again on the next launch.
        var isPersistable: Bool {
            switch self {
            case .application(let bundleID, _, _): return bundleID != nil
            case .systemAudio, .inputDevice:    return true
            }
        }
    }

    /// One source registered with the mixer.
    final class Source: Identifiable {
        let id = UUID()
        let target: Target
        let ring: AudioRingBuffer

        var gain: Float = 1.0
        var isMuted = false

        /// The output channel this source's left channel lands on. Its right
        /// channel goes to the one after. 0 means channels 1–2, 2 means 3–4.
        ///
        /// On a stereo output every source shares channels 1–2 and is mixed.
        /// On a wider device, giving sources different offsets keeps them apart,
        /// so whatever receives the device can treat each pair as its own track.
        var channelOffset = 0

        /// The target could not be found, so nothing is connected. The row
        /// stays even while the app is closed, and attaches once it starts.
        private(set) var isAttached = false
        private(set) var detachReason: String?

        fileprivate var tap: ProcessTap?

        /// For diagnostics.
        var tapForDiagnostics: ProcessTap? { tap }
        fileprivate var input: DeviceInput?
        fileprivate var converter: FormatConverter?

        private(set) var formatDescription = "—"

        var label: String { target.label }

        fileprivate init(target: Target, channels: Int) {
            self.target = target
            self.ring = AudioRingBuffer(channels: channels)
        }

        fileprivate func markAttached(sourceFormat: AVAudioFormat?, targetFormat: AVAudioFormat) {
            isAttached = true
            detachReason = nil
            guard let sourceFormat else { return }
            formatDescription = "\(Int(sourceFormat.sampleRate)) Hz / \(sourceFormat.channelCount)ch"
            converter = FormatConverter(from: sourceFormat, to: targetFormat)
            if converter != nil {
                formatDescription += " → \(Int(targetFormat.sampleRate)) Hz"
            }
        }

        fileprivate func markDetached(_ reason: String) {
            isAttached = false
            detachReason = reason
            formatDescription = "—"
        }

        /// Take a buffer from the source, convert it if needed, and queue it.
        fileprivate func accept(_ buffer: AVAudioPCMBuffer) {
            if let converter {
                guard let converted = converter.convert(buffer) else { return }
                ring.write(converted)
            } else {
                ring.write(buffer)
            }
        }

        fileprivate func stop() {
            tap?.stop(); tap = nil
            input?.stop(); input = nil
            converter = nil
            isAttached = false
            ring.clear()
        }
    }

    private(set) var sources: [Source] = []
    private(set) var isRunning = false
    private(set) var outputDevice: AudioDevice?

    private(set) var output: DeviceOutput?
    /// Format every source is converted to before buffering: the output's
    /// sample rate, but always stereo. Channel placement happens at mix time.
    private var targetFormat: AVAudioFormat?
    private let sourceLock = NSLock()

    /// Sources are buffered as stereo regardless of how wide the output is.
    private let sourceChannelCount = 2

    /// Channels on the current output device. Two until the mixer starts.
    private(set) var outputChannelCount = 2

    private var masterPeak: Float = 0
    private let meterLock = NSLock()

    deinit { stop() }

    // MARK: - Managing sources

    @discardableResult
    func add(_ target: Target) -> Source {
        let source = Source(target: target, channels: sourceChannelCount)
        sourceLock.lock()
        sources.append(source)
        sourceLock.unlock()
        if isRunning { try? attach(source) }
        return source
    }

    func remove(id: UUID) {
        sourceLock.lock()
        guard let index = sources.firstIndex(where: { $0.id == id }) else {
            sourceLock.unlock(); return
        }
        let source = sources.remove(at: index)
        sourceLock.unlock()
        source.stop()
    }

    /// Reorder. SwiftUI's move(fromOffsets:toOffset:) is deliberately avoided
    /// so the engine does not depend on a UI framework.
    func move(from offsets: IndexSet, to destination: Int) {
        sourceLock.lock()
        defer { sourceLock.unlock() }

        let moving = offsets.sorted().compactMap { sources.indices.contains($0) ? sources[$0] : nil }
        guard !moving.isEmpty else { return }

        let insertionIndex = destination - offsets.filter { $0 < destination }.count
        for index in offsets.sorted(by: >) where sources.indices.contains(index) {
            sources.remove(at: index)
        }
        sources.insert(contentsOf: moving, at: max(0, min(insertionIndex, sources.count)))
    }

    func removeAll() {
        sourceLock.lock()
        let all = sources
        sources.removeAll()
        sourceLock.unlock()
        all.forEach { $0.stop() }
    }

    /// Reconnect sources that are not attached, for when the target app
    /// starts up later.
    @discardableResult
    func reattachDetached() -> Int {
        guard isRunning else { return 0 }
        sourceLock.lock()
        let pending = sources.filter { !$0.isAttached }
        sourceLock.unlock()

        var reattached = 0
        for source in pending where (try? attach(source)) != nil {
            if source.isAttached { reattached += 1 }
        }
        return reattached
    }

    // MARK: - Starting and stopping

    func start(to device: AudioDevice) throws {
        guard !isRunning else { return }
        outputDevice = device

        // Build the output first: each source's converter needs its format.
        let deviceOutput = try DeviceOutput(device: device)
        outputChannelCount = deviceOutput.channelCount
        targetFormat = AVAudioFormat.discrete(sampleRate: deviceOutput.sampleRate,
                                              channels: sourceChannelCount)

        sourceLock.lock()
        let snapshot = sources
        sourceLock.unlock()
        for source in snapshot { try? attach(source) }

        try deviceOutput.start { [weak self] channels, frameCount in
            self?.render(into: channels, frameCount: frameCount)
        }
        output = deviceOutput
        isRunning = true
    }

    func stop() {
        output?.stop()
        output = nil

        sourceLock.lock()
        let snapshot = sources
        sourceLock.unlock()
        snapshot.forEach { $0.stop() }

        isRunning = false
        outputDevice = nil
        targetFormat = nil
    }

    /// Bind a source to something concrete, leaving it detached if the target
    /// is not present.
    private func attach(_ source: Source) throws {
        guard let targetFormat else { return }
        guard !source.isAttached else { return }

        switch source.target {
        case .application(let bundleID, let name, let pid):
            guard let process = try locateProcess(bundleID: bundleID, name: name, pid: pid) else {
                source.markDetached("\(name) is not running")
                return
            }
            let tap = ProcessTap()
            try tap.start(mode: .include([process])) { [weak source] buffer in
                source?.accept(buffer)
            }
            source.tap = tap
            source.markAttached(sourceFormat: tap.format, targetFormat: targetFormat)

        case .systemAudio:
            // Exclude ourselves. Including our own output would feed the mix
            // straight back into the input and loop.
            let me = try? AudioProcess.find(pid: ProcessInfo.processInfo.processIdentifier)
            let tap = ProcessTap()
            try tap.start(mode: .excluding(me.map { [$0] } ?? [])) { [weak source] buffer in
                source?.accept(buffer)
            }
            source.tap = tap
            source.markAttached(sourceFormat: tap.format, targetFormat: targetFormat)

        case .inputDevice(let uid, let name):
            guard let device = try AudioDevice.find(uid: uid) else {
                source.markDetached("\(name) was not found")
                return
            }
            let input = try DeviceInput(device: device)
            try input.start { [weak source] buffer, _ in
                source?.accept(buffer)
            }
            source.input = input
            source.markAttached(sourceFormat: input.format, targetFormat: targetFormat)
        }
    }

    /// Find the process a source refers to.
    ///
    /// A PID from this session wins, provided that process is still the same
    /// program — PIDs are reused once a process exits. Otherwise fall back to
    /// the bundle identifier, and only then to the name.
    private func locateProcess(bundleID: String?, name: String, pid: pid_t?) throws -> AudioProcess? {
        let all = try AudioProcess.all()
        if let pid, let exact = all.first(where: { $0.pid == pid }),
           exact.bundleID == bundleID, exact.name == name {
            return exact
        }
        if let bundleID {
            return all.first { $0.bundleID == bundleID }
        }
        return all.first { $0.name == name }
    }

    // MARK: - Mixing

    /// Called from the output device's callback. Sums every source.
    private func render(into channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        for channel in channels {
            for frame in 0..<frameCount { channel[frame] = 0 }
        }

        sourceLock.lock()
        let snapshot = sources
        sourceLock.unlock()

        for source in snapshot {
            let gain = source.isMuted ? 0 : source.gain
            source.ring.mixInto(channels, frameCount: frameCount, gain: gain,
                                channelOffset: source.channelOffset)
        }

        // Guard against clipping: anything past ±1 would be squashed.
        var peak: Float = 0
        for channel in channels {
            for frame in 0..<frameCount {
                var value = channel[frame]
                if value > 1.0 { value = 1.0 } else if value < -1.0 { value = -1.0 }
                channel[frame] = value
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
            }
        }

        meterLock.lock()
        if peak > masterPeak { masterPeak = peak }
        meterLock.unlock()
    }

    func takeMasterPeak() -> Float {
        meterLock.lock(); defer { meterLock.unlock() }
        let value = masterPeak
        masterPeak = 0
        return value
    }
}
