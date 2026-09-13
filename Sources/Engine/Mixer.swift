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

    /// Frames every buffer accumulates before playing: latency traded for
    /// resilience against clock drift and scheduling hiccups. Read when a mix
    /// starts, so changing it affects mixes started afterwards.
    static var bufferCushionFrames = 2048

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
            self.ring = AudioRingBuffer(channels: channels, primeFrames: Mixer.bufferCushionFrames)
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

    /// One destination of the mix.
    ///
    /// The first output that can be opened is the primary: its device clock
    /// drives the mix. Every other output receives a copy of the finished mix
    /// through a ring buffer, converted to its own sample rate and folded to its
    /// own channel count if they differ. That is what lets one mix go to a
    /// virtual device and to your speakers at the same time, so you can hear
    /// what you are sending.
    final class Output: Identifiable {
        let id = UUID()
        let deviceUID: String
        let deviceName: String

        var gain: Float = 1.0
        var isMuted = false

        private(set) var isAttached = false
        private(set) var isPrimary = false
        private(set) var detachReason: String?
        private(set) var channelCount = 0
        private(set) var sampleRate: Double = 0

        fileprivate var device: DeviceOutput?
        fileprivate var ring: AudioRingBuffer?
        fileprivate var converter: FormatConverter?
        fileprivate var scratch: AVAudioPCMBuffer?

        /// Ramp for this output's gain combined with the master volume.
        fileprivate var gainRamp = GainRamp()

        /// Everything after the mix: this output's gain times the master
        /// volume, then clipping and metering. Runs on this output's own
        /// real-time thread.
        fileprivate func finish(_ channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
            let target = (isMuted ? 0 : gain) * MasterVolume.shared.gain
            gainRamp.apply(to: channels, frameCount: frameCount, target: target)
            record(peak: clipAndMeasure(channels, frameCount: frameCount))
        }

        private let meterLock = NSLock()
        private var peak: Float = 0

        fileprivate init(deviceUID: String, deviceName: String) {
            self.deviceUID = deviceUID
            self.deviceName = deviceName
        }

        /// The most recent output peak, reset on read.
        func takePeak() -> Float {
            meterLock.lock(); defer { meterLock.unlock() }
            let value = peak
            peak = 0
            return value
        }

        fileprivate func record(peak value: Float) {
            meterLock.lock()
            if value > peak { peak = value }
            meterLock.unlock()
        }

        fileprivate func attach(device: DeviceOutput, primary: Bool) {
            self.device = device
            isAttached = true
            isPrimary = primary
            detachReason = nil
            channelCount = device.channelCount
            sampleRate = device.sampleRate
        }

        fileprivate func markDetached(_ reason: String) {
            isAttached = false
            isPrimary = false
            detachReason = reason
        }

        fileprivate func stop() {
            device?.stop()
            device = nil
            ring = nil
            converter = nil
            scratch = nil
            isAttached = false
            isPrimary = false
        }
    }

    enum StartError: LocalizedError {
        case noOutputs
        case noUsableOutput([String])
        case feedback(String)

        var errorDescription: String? {
            switch self {
            case .noOutputs:
                return "Add at least one output."
            case .noUsableOutput(let reasons):
                return "None of the outputs could be opened: " + reasons.joined(separator: "; ")
            case .feedback(let device):
                return "\(device) is both a source and an output of this mix, which would feed back."
            }
        }
    }

    private(set) var outputs: [Output] = []

    /// This mix's volume, applied to the summed sources before the mix is
    /// copied to any output — one fader for everything the mix sends.
    var volume: Float = 1
    var isMuted = false
    private var volumeRamp = GainRamp()

    private(set) var sources: [Source] = []
    private(set) var isRunning = false

    /// The primary output's device stage, for diagnostics.
    var output: DeviceOutput? { outputs.first(where: \.isPrimary)?.device }

    /// Format every source is converted to before buffering: the primary
    /// output's sample rate, but always stereo. Channel placement happens at
    /// mix time.
    private var targetFormat: AVAudioFormat?
    private let sourceLock = NSLock()

    /// Sources are buffered as stereo regardless of how wide the output is.
    private let sourceChannelCount = 2

    /// Channels on the primary output. Two until the mixer starts.
    private(set) var outputChannelCount = 2

    /// Secondary outputs as seen by the real-time thread. Replaced wholesale
    /// under the lock rather than mutated, so the render callback can take a
    /// consistent snapshot cheaply.
    private var fanOut: [Output] = []
    private var primaryOutput: Output?

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

    // MARK: - Managing outputs

    /// Add an output. Changing outputs while running restarts the mix, since
    /// the primary output's clock may change.
    @discardableResult
    func addOutput(uid: String, name: String) -> Output {
        let output = Output(deviceUID: uid, deviceName: name)
        outputs.append(output)
        restartIfRunning()
        return output
    }

    func removeOutput(id: UUID) {
        guard let index = outputs.firstIndex(where: { $0.id == id }) else { return }
        let removed = outputs.remove(at: index)
        removed.stop()
        restartIfRunning()
    }

    /// Make an output the primary one, the one whose clock drives the mix.
    func makePrimary(id: UUID) {
        guard let index = outputs.firstIndex(where: { $0.id == id }), index != 0 else { return }
        let output = outputs.remove(at: index)
        outputs.insert(output, at: 0)
        restartIfRunning()
    }

    private func restartIfRunning() {
        guard isRunning else { return }
        stop()
        try? start()
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

    /// Convenience for a single destination: adds it if no outputs exist yet.
    func start(to device: AudioDevice) throws {
        if outputs.isEmpty { outputs.append(Output(deviceUID: device.uid, deviceName: device.name)) }
        try start()
    }

    func start() throws {
        guard !isRunning else { return }
        guard !outputs.isEmpty else { throw StartError.noOutputs }

        // A device that is both captured and played into by the same mix would
        // loop straight back on itself.
        let outputUIDs = Set(outputs.map(\.deviceUID))
        sourceLock.lock()
        let snapshot = sources
        sourceLock.unlock()
        for source in snapshot {
            if case .inputDevice(let uid, let name) = source.target, outputUIDs.contains(uid) {
                throw StartError.feedback(name)
            }
        }

        // Open outputs in order. The first that opens is the primary.
        var reasons: [String] = []
        var primary: Output?
        var secondaries: [Output] = []
        for output in outputs {
            do {
                guard let device = try AudioDevice.find(uid: output.deviceUID) else {
                    output.markDetached("\(output.deviceName) was not found")
                    reasons.append("\(output.deviceName) was not found")
                    continue
                }
                let stage = try DeviceOutput(device: device)
                output.attach(device: stage, primary: primary == nil)
                if primary == nil { primary = output } else { secondaries.append(output) }
            } catch {
                output.markDetached(error.localizedDescription)
                reasons.append("\(output.deviceName): \(error.localizedDescription)")
            }
        }
        guard let primary, let primaryStage = primary.device else {
            throw StartError.noUsableOutput(reasons)
        }

        outputChannelCount = primaryStage.channelCount
        targetFormat = AVAudioFormat.discrete(sampleRate: primaryStage.sampleRate,
                                              channels: sourceChannelCount)

        // Each secondary gets a buffer, and a converter when its rate differs.
        for output in secondaries {
            guard let stage = output.device else { continue }
            output.ring = AudioRingBuffer(channels: stage.channelCount,
                                          primeFrames: Mixer.bufferCushionFrames)
            output.scratch = AVAudioFormat.discrete(sampleRate: primaryStage.sampleRate,
                                                    channels: stage.channelCount)
                .flatMap { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: 8192) }
            if stage.sampleRate != primaryStage.sampleRate,
               let from = AVAudioFormat.discrete(sampleRate: primaryStage.sampleRate,
                                                 channels: stage.channelCount),
               let to = AVAudioFormat.discrete(sampleRate: stage.sampleRate,
                                               channels: stage.channelCount) {
                output.converter = FormatConverter(from: from, to: to)
            }
        }

        volumeRamp.reset(to: isMuted ? 0 : volume)
        for output in outputs {
            output.gainRamp.reset(to: (output.isMuted ? 0 : output.gain) * MasterVolume.shared.gain)
        }
        for source in snapshot {
            source.ring.setPrimeFrames(Mixer.bufferCushionFrames)
            try? attach(source)
        }

        sourceLock.lock()
        fanOut = secondaries
        primaryOutput = primary
        sourceLock.unlock()

        // Secondaries first: they play silence until their buffers fill.
        for output in secondaries {
            try? output.device?.start { [weak output] channels, frameCount in
                guard let output, let ring = output.ring else { return }
                ring.mixInto(channels, frameCount: frameCount, gain: 1)
                output.finish(channels, frameCount: frameCount)
            }
        }
        try primaryStage.start { [weak self] channels, frameCount in
            self?.render(into: channels, frameCount: frameCount)
        }
        isRunning = true
    }

    func stop() {
        sourceLock.lock()
        fanOut = []
        primaryOutput = nil
        sourceLock.unlock()

        // Primary first so nothing new is fanned out while secondaries close.
        outputs.first(where: \.isPrimary)?.stop()
        outputs.forEach { $0.stop() }

        sourceLock.lock()
        let snapshot = sources
        sourceLock.unlock()
        snapshot.forEach { $0.stop() }

        isRunning = false
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

    /// Called from the primary output's callback. Sums every source, copies the
    /// result to the other outputs, then applies the primary's own gain.
    private func render(into channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        for channel in channels {
            for frame in 0..<frameCount { channel[frame] = 0 }
        }

        sourceLock.lock()
        let snapshot = sources
        let secondaries = fanOut
        let primary = primaryOutput
        sourceLock.unlock()

        for source in snapshot {
            let gain = source.isMuted ? 0 : source.gain
            source.ring.mixInto(channels, frameCount: frameCount, gain: gain,
                                channelOffset: source.channelOffset)
        }

        // The mix's own volume applies to everything it sends.
        volumeRamp.apply(to: channels, frameCount: frameCount, target: isMuted ? 0 : volume)

        // Fan out before the primary's gain, so muting or turning down one
        // output never affects the others.
        for output in secondaries {
            Self.fanOut(channels, frameCount: frameCount, to: output)
        }

        if let primary {
            primary.finish(channels, frameCount: frameCount)
        } else {
            _ = clipAndMeasure(channels, frameCount: frameCount)
        }
    }

    /// Copy the mix to a secondary output, folding its channels to the output's
    /// width. Channel i of the mix lands on channel i modulo the output's width,
    /// so a four-channel mix played on stereo speakers puts 1 and 3 on the left
    /// and 2 and 4 on the right: everything stays audible.
    private static func fanOut(_ mix: [UnsafeMutablePointer<Float>], frameCount: Int, to output: Output) {
        guard let ring = output.ring, output.channelCount > 0 else { return }
        let width = output.channelCount

        let buffer: AVAudioPCMBuffer
        if let scratch = output.scratch, Int(scratch.frameCapacity) >= frameCount {
            buffer = scratch
        } else if let format = output.scratch?.format,
                  let larger = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(frameCount)) {
            output.scratch = larger
            buffer = larger
        } else {
            return
        }
        guard let folded = buffer.floatChannelData else { return }

        for channel in 0..<width {
            folded[channel].update(repeating: 0, count: frameCount)
        }
        for (index, source) in mix.enumerated() {
            let target = folded[index % width]
            for frame in 0..<frameCount { target[frame] += source[frame] }
        }
        for channel in 0..<width {
            let target = folded[channel]
            for frame in 0..<frameCount {
                target[frame] = min(1, max(-1, target[frame]))
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        if let converter = output.converter {
            guard let converted = converter.convert(buffer) else { return }
            ring.write(converted)
        } else {
            ring.write((0..<width).map { UnsafePointer(folded[$0]) }, frameCount: frameCount)
        }
    }

    /// Peak of the primary output, reset on read.
    func takeMasterPeak() -> Float {
        outputs.first(where: \.isPrimary)?.takePeak() ?? 0
    }
}
