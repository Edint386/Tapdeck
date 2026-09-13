import AVFoundation
import Foundation

/// A ring buffer for one source.
///
/// Every mixer source runs on its own clock — a process tap follows the default
/// output device, a microphone follows itself — and none of them line up with
/// the output callback in period or phase. This sits between them and absorbs
/// the difference in rate.
///
/// On overflow the oldest frames are dropped; on underflow silence is returned.
/// Latency that keeps growing sounds worse than an occasional gap, which is why
/// it drops rather than stretches.
final class AudioRingBuffer: @unchecked Sendable {

    private let capacityFrames: Int
    private let channelCount: Int
    private var storage: [Float]

    private var writePosition = 0
    private var filledFrames = 0
    private let lock = NSLock()

    /// Frames to accumulate before reading starts — deliberate latency.
    ///
    /// Source and output run on different clocks, so matching their rates still
    /// leaves their phase unmatched. Reading without a cushion keeps the buffer
    /// permanently near empty and every small wobble punches a gap in the
    /// waveform. It shows up as the overall level being right while one
    /// frequency drops: a 440 Hz sine measured -39.2 dB where -21.1 dB was
    /// expected.
    private var primeFrames: Int

    /// Whether enough has accumulated for reading to begin. Reset on underflow
    /// so the cushion is rebuilt.
    private var isPrimed = false

    /// Peak of the most recently written span, for metering.
    private var recentPeak: Float = 0

    init(channels: Int, capacityFrames: Int = 16384, primeFrames: Int = 2048) {
        self.channelCount = max(1, channels)
        self.capacityFrames = max(512, capacityFrames)
        self.primeFrames = min(max(0, primeFrames), self.capacityFrames / 2)
        self.storage = [Float](repeating: 0, count: self.channelCount * self.capacityFrames)
    }

    /// Change the cushion. Takes effect the next time the buffer primes, so it
    /// is applied when a mix starts rather than mid-stream.
    func setPrimeFrames(_ frames: Int) {
        lock.lock()
        primeFrames = min(max(0, frames), capacityFrames / 2)
        isPrimed = false
        lock.unlock()
    }

    /// How often reading ran dry. If this climbs, raise primeFrames.
    private(set) var underrunCount = 0

    /// How often unread data was overwritten. Causes phase jumps while the
    /// amplitude still looks correct.
    private(set) var overrunCount = 0

    var availableFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return filledFrames
    }

    func clear() {
        lock.lock()
        for index in storage.indices { storage[index] = 0 }
        writePosition = 0
        filledFrames = 0
        recentPeak = 0
        isPrimed = false
        underrunCount = 0
        overrunCount = 0
        lock.unlock()
    }

    /// Take the recent peak and reset it to zero.
    func takePeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let value = recentPeak
        recentPeak = 0
        return value
    }

    // MARK: - Writing

    /// Write a buffer that arrived from the source.
    /// When the channel counts differ, a mono source is duplicated across
    /// channels and a wider one is mapped from its first channels.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let sourceChannels = Int(buffer.format.channelCount)

        lock.lock()
        defer { lock.unlock() }

        var peak: Float = 0
        for frame in 0..<frames {
            let slot = (writePosition + frame) % capacityFrames
            for channel in 0..<channelCount {
                // Mono fans out to every channel; wider sources map from the front.
                let sourceChannel = sourceChannels == 1 ? 0 : min(channel, sourceChannels - 1)
                let value = data[sourceChannel][frame]
                storage[channel * capacityFrames + slot] = value
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
            }
        }

        writePosition = (writePosition + frames) % capacityFrames
        if filledFrames + frames > capacityFrames { overrunCount += 1 }
        filledFrames = min(filledFrames + frames, capacityFrames)
        if peak > recentPeak { recentPeak = peak }
    }

    /// Write planar samples directly. Used to fan a finished mix out to extra
    /// outputs without wrapping it in an AVAudioPCMBuffer first.
    func write(_ source: [UnsafePointer<Float>], frameCount frames: Int) {
        guard frames > 0, !source.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var peak: Float = 0
        for frame in 0..<frames {
            let slot = (writePosition + frame) % capacityFrames
            for channel in 0..<channelCount {
                let value = channel < source.count ? source[channel][frame] : 0
                storage[channel * capacityFrames + slot] = value
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
            }
        }
        writePosition = (writePosition + frames) % capacityFrames
        if filledFrames + frames > capacityFrames { overrunCount += 1 }
        filledFrames = min(filledFrames + frames, capacityFrames)
        if peak > recentPeak { recentPeak = peak }
    }

    // MARK: - Reading

    /// Add into the output buffer. The mixer calls this once per source.
    /// Whatever is not yet buffered contributes nothing, leaving silence.
    ///
    /// - Parameter channelOffset: the output channel this source's first
    ///   channel lands on. This is what lets several sources share one
    ///   multichannel device without being mixed together — a microphone on
    ///   channels 1–2 and system audio on 3–4, say.
    func mixInto(_ destination: [UnsafeMutablePointer<Float>],
                 frameCount: Int,
                 gain: Float,
                 channelOffset: Int = 0) {
        guard gain != 0 else { consume(frameCount); return }

        lock.lock()
        defer { lock.unlock() }

        // Hold everything back until the cushion is full; partial reads just
        // produce a run of gaps.
        if !isPrimed {
            guard filledFrames >= primeFrames else { return }
            isPrimed = true
        }

        let usable = min(frameCount, filledFrames)
        guard usable > 0 else {
            isPrimed = false
            underrunCount += 1
            return
        }

        // Reading starts filledFrames behind the write position.
        let readStart = ((writePosition - filledFrames) % capacityFrames + capacityFrames)
                        % capacityFrames

        for sourceChannel in 0..<channelCount {
            let target = channelOffset + sourceChannel
            guard target >= 0, target < destination.count else { continue }
            let output = destination[target]
            let base = sourceChannel * capacityFrames
            for frame in 0..<usable {
                let slot = (readStart + frame) % capacityFrames
                output[frame] += storage[base + slot] * gain
            }
        }
        filledFrames -= usable
    }

    /// Advance a muted source so latency does not accumulate behind it.
    private func consume(_ frameCount: Int) {
        lock.lock()
        filledFrames = max(0, filledFrames - frameCount)
        lock.unlock()
    }

    var underruns: Int {
        lock.lock(); defer { lock.unlock() }
        return underrunCount
    }

    var overruns: Int {
        lock.lock(); defer { lock.unlock() }
        return overrunCount
    }

    /// Frames currently buffered, as a rough measure of latency.
    var fill: Int {
        lock.lock(); defer { lock.unlock() }
        return filledFrames
    }
}
