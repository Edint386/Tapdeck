import Foundation

/// App-wide volume, applied last on every output of every mix.
///
/// Every running mix reads it from its own real-time thread, so it is kept
/// behind an unfair lock rather than as a bare shared variable.
final class MasterVolume: @unchecked Sendable {
    static let shared = MasterVolume()

    private var lock = os_unfair_lock()
    private var storedVolume: Float = 1
    private var storedMute = false

    var volume: Float {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return storedVolume }
        set { os_unfair_lock_lock(&lock); storedVolume = max(0, newValue); os_unfair_lock_unlock(&lock) }
    }

    var isMuted: Bool {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return storedMute }
        set { os_unfair_lock_lock(&lock); storedMute = newValue; os_unfair_lock_unlock(&lock) }
    }

    /// The multiplier to apply right now.
    var gain: Float {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return storedMute ? 0 : storedVolume
    }
}

/// Applies a gain that may change from one block to the next.
///
/// Jumping straight to a new gain at a block boundary puts a step in the
/// waveform, which is heard as a click or "zipper" noise while a slider moves.
/// The change is spread linearly across the block instead.
struct GainRamp {
    private(set) var current: Float

    init(_ initial: Float = 1) { current = initial }

    /// Multiply every channel by a gain moving from the previous block's value
    /// to `target`.
    mutating func apply(to channels: [UnsafeMutablePointer<Float>], frameCount: Int, target: Float) {
        guard frameCount > 0 else { return }
        let start = current
        defer { current = target }

        if start == target {
            guard target != 1 else { return }
            for channel in channels {
                for frame in 0..<frameCount { channel[frame] *= target }
            }
            return
        }

        let step = (target - start) / Float(frameCount)
        for channel in channels {
            var gain = start
            for frame in 0..<frameCount {
                gain += step
                channel[frame] *= gain
            }
        }
    }

    /// Jump without ramping, for when playback restarts from silence.
    mutating func reset(to value: Float) { current = value }
}

/// Keeps every sample under a ceiling.
///
/// Instant attack, so no sample ever passes the ceiling; smooth release so the
/// gain does not flutter.
struct PeakLimiter {
    private var gain: Double = 1

    /// - Parameters:
    ///   - ceiling: linear amplitude no sample may exceed.
    ///   - release: per-sample smoothing coefficient for recovering gain.
    mutating func process(_ channels: [UnsafeMutablePointer<Float>], frameCount: Int,
                          ceiling: Double, release: Double) {
        let hardCeiling = Float(ceiling)
        var current = gain
        for frame in 0..<frameCount {
            var peak: Double = 0
            for channel in channels { peak = max(peak, Double(abs(channel[frame]))) }
            let needed = peak > ceiling ? ceiling / peak : 1
            current = needed < current ? needed : needed + (current - needed) * release

            let value = Float(current)
            for channel in channels {
                var sample = channel[frame] * value
                // Rounding can leave a sample a hair over; never let it through.
                if sample > hardCeiling { sample = hardCeiling } else if sample < -hardCeiling { sample = -hardCeiling }
                channel[frame] = sample
            }
        }
        gain = current
    }

    mutating func reset() { gain = 1 }
}

/// The last stage of every output: keeps it under the ceiling without cutting
/// samples off.
///
/// Anything over full scale used to be clipped, which is heard as harsh
/// distortion even at low listening levels, because the device's own volume
/// turns the damaged signal down afterwards. This limiter looks a little
/// ahead instead and lowers the gain smoothly before a peak arrives.
///
/// The gain for each sample is the lowest gain any sample needs within the
/// look-ahead window, then averaged over the same window. Averaging only
/// values at or below what a sample needs cannot exceed it, so the ceiling
/// holds exactly, and the average turns the step into a ramp. The signal is
/// delayed by the window length less one sample to line up with its gain.
final class LookaheadLimiter {
    let channelCount: Int
    let lookahead: Int
    private let ceiling: Double
    private let release: Double

    /// The signal is held back by this many samples, one less than the window.
    private let delayLength: Int
    private let delayed: UnsafeMutablePointer<Float>
    private var delayIndex = 0

    // Sliding minimum over the window: a deque of (index, gain), increasing.
    private let minimumIndices: UnsafeMutablePointer<Int>
    private let minimumValues: UnsafeMutablePointer<Double>
    private var dequeHead = 0
    private var dequeCount = 0

    // Moving average of the sliding minimum.
    private let averageRing: UnsafeMutablePointer<Double>
    private var averageIndex = 0
    private var averageSum: Double

    private var released: Double = 1
    private var sampleIndex = 0

    /// - Parameters:
    ///   - ceiling: linear amplitude no sample may exceed.
    ///   - lookaheadSeconds: how far ahead peaks are seen, and how long the
    ///     gain takes to come down.
    ///   - releaseSeconds: time constant for the gain to recover.
    init(channels: Int, sampleRate: Double, ceiling: Double,
         lookaheadSeconds: Double = 0.002, releaseSeconds: Double = 0.1) {
        channelCount = max(1, channels)
        lookahead = max(1, Int((lookaheadSeconds * sampleRate).rounded()))
        self.ceiling = ceiling
        release = exp(-1 / (releaseSeconds * sampleRate))

        delayLength = lookahead - 1
        delayed = .allocate(capacity: max(1, channelCount * delayLength))
        delayed.initialize(repeating: 0, count: max(1, channelCount * delayLength))
        minimumIndices = .allocate(capacity: lookahead + 1)
        minimumValues = .allocate(capacity: lookahead + 1)
        averageRing = .allocate(capacity: lookahead)
        averageRing.initialize(repeating: 1, count: lookahead)
        averageSum = Double(lookahead)
    }

    deinit {
        delayed.deallocate()
        minimumIndices.deallocate()
        minimumValues.deallocate()
        averageRing.deallocate()
    }

    /// Samples of delay this stage adds.
    var latencyFrames: Int { delayLength }

    /// Limit the channels in place and return the lowest gain applied, for
    /// showing when the limiter works. Runs on a real-time thread.
    @discardableResult
    func process(_ channels: [UnsafeMutablePointer<Float>], frameCount: Int) -> Double {
        let width = min(channels.count, channelCount)
        let capacity = lookahead + 1
        let hardCeiling = Float(ceiling)
        var lowest: Double = 1

        for frame in 0..<frameCount {
            var peak: Double = 0
            for channel in 0..<width { peak = max(peak, Double(abs(channels[channel][frame]))) }
            let needed = peak > ceiling ? ceiling / peak : 1

            // Recover slowly, but never above what this sample needs.
            released = needed <= released ? needed : needed + (released - needed) * release

            // Sliding minimum over the last `lookahead` samples.
            while dequeCount > 0 {
                let back = (dequeHead + dequeCount - 1) % capacity
                if minimumValues[back] >= released { dequeCount -= 1 } else { break }
            }
            let slot = (dequeHead + dequeCount) % capacity
            minimumIndices[slot] = sampleIndex
            minimumValues[slot] = released
            dequeCount += 1
            if minimumIndices[dequeHead] <= sampleIndex - lookahead {
                dequeHead = (dequeHead + 1) % capacity
                dequeCount -= 1
            }
            let minimum = minimumValues[dequeHead]

            // Average the minimum over the same window.
            averageSum += minimum - averageRing[averageIndex]
            averageRing[averageIndex] = minimum
            averageIndex += 1
            if averageIndex == lookahead {
                averageIndex = 0
                // Re-add from scratch once per window so rounding never drifts.
                var exact: Double = 0
                for index in 0..<lookahead { exact += averageRing[index] }
                averageSum = exact
            }
            let gain = min(1, averageSum / Double(lookahead))
            if gain < lowest { lowest = gain }

            // Swap the incoming sample for the one leaving the delay, which is
            // the sample this gain was worked out for.
            let value = Float(gain)
            for channel in 0..<width {
                let incoming = channels[channel][frame]
                var outgoing: Float
                if delayLength > 0 {
                    let index = channel * delayLength + delayIndex
                    outgoing = delayed[index] * value
                    delayed[index] = incoming
                } else {
                    outgoing = incoming * value
                }
                // Rounding can leave a sample a hair over; never let it through.
                if outgoing > hardCeiling { outgoing = hardCeiling } else if outgoing < -hardCeiling { outgoing = -hardCeiling }
                channels[channel][frame] = outgoing
            }
            if delayLength > 0 { delayIndex = (delayIndex + 1) % delayLength }
            sampleIndex += 1
        }
        return lowest
    }
}

/// Clamp every sample to ±1 and return the peak, for metering.
@inline(__always)
func clipAndMeasure(_ channels: [UnsafeMutablePointer<Float>], frameCount: Int) -> Float {
    var peak: Float = 0
    for channel in channels {
        for frame in 0..<frameCount {
            var value = channel[frame]
            if value > 1 { value = 1 } else if value < -1 { value = -1 }
            channel[frame] = value
            let magnitude = abs(value)
            if magnitude > peak { peak = magnitude }
        }
    }
    return peak
}
