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
