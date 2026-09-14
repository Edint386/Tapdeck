import Foundation

// MARK: - Tuning

/// How loudness normalisation behaves everywhere in the app: the loudness it
/// aims for and how quickly it follows a change.
///
/// Set from Settings on the main thread and read by every normaliser once per
/// buffer from its own real-time thread, so it sits behind an unfair lock.
final class LoudnessTuning: @unchecked Sendable {
    static let shared = LoudnessTuning()

    struct Values: Equatable {
        /// Loudness to aim for, in LUFS.
        var target: Double = -16
        /// The most a quiet programme is raised, in dB. Loud programmes can
        /// always be brought down.
        var maximumBoost: Double = 12
        var speed: Speed = .balanced
    }

    /// How closely the level follows the programme. Faster evens out more but
    /// also flattens the quiet and loud passages inside a song or a film.
    enum Speed: String, CaseIterable, Codable, Identifiable {
        case gentle, balanced, fast

        var id: String { rawValue }

        /// Time constant, in seconds, for following a rise in loudness.
        var rise: Double {
            switch self {
            case .gentle:   return 2
            case .balanced: return 1
            case .fast:     return 0.4
            }
        }

        /// Time constant, in seconds, for following a fall. Slower than a
        /// rise: turning something down too late hurts, turning it up late
        /// does not.
        var fall: Double {
            switch self {
            case .gentle:   return 12
            case .balanced: return 5
            case .fast:     return 2
            }
        }
    }

    private var lock = os_unfair_lock()
    private var stored = Values()

    var values: Values {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return stored }
        set { os_unfair_lock_lock(&lock); stored = newValue; os_unfair_lock_unlock(&lock) }
    }
}

/// What a normaliser is doing, for display.
struct LoudnessReading: Equatable {
    /// The programme's loudness as the normaliser currently estimates it, in
    /// LUFS. Nil until it has heard anything above silence.
    var loudness: Double?
    /// Gain being applied, in dB.
    var gain: Double
}

// MARK: - Meter

/// Loudness measurement as ITU-R BS.1770 defines it: each channel is
/// K-weighted — a high shelf for the head's effect and a high-pass for the
/// ear's insensitivity to deep bass — then squared and averaged.
///
/// Mean square is gathered in 100 ms blocks and reported over the last four,
/// which is the standard's 400 ms momentary loudness. Every channel has a
/// weight of 1: the channel layout of a device is unknown, and for stereo that
/// is exactly what the standard specifies.
struct LoudnessMeter {
    static let blockSeconds = 0.1
    static let momentaryBlocks = 4
    static let maximumChannels = 64

    private var shelf = Biquad()
    private var highPass = Biquad()
    private var shelfState: [Double]
    private var highPassState: [Double]

    private(set) var blockLength = 4800
    private var blockEnergy: Double = 0
    private var blockFrames = 0

    private var blocks = [Double](repeating: 0, count: LoudnessMeter.momentaryBlocks)
    private var nextBlock = 0
    private var filledBlocks = 0

    init() {
        shelfState = [Double](repeating: 0, count: 2 * Self.maximumChannels)
        highPassState = [Double](repeating: 0, count: 2 * Self.maximumChannels)
        configure(sampleRate: 48_000)
    }

    /// Filter parameters from BS.1770, turned into coefficients for any rate.
    /// At 48 kHz they reproduce the standard's published coefficients.
    mutating func configure(sampleRate: Double) {
        do {
            let f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196
            let k = tan(Double.pi * f0 / sampleRate)
            let vh = pow(10, gain / 20)
            let vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0,
                           b1: 2 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0,
                           a2: (1 - k / q + k * k) / a0)
        }
        do {
            let f0 = 38.13547087602444, q = 0.5003270373238773
            let k = tan(Double.pi * f0 / sampleRate)
            let a0 = 1 + k / q + k * k
            highPass = Biquad(b0: 1, b1: -2, b2: 1,
                              a1: 2 * (k * k - 1) / a0,
                              a2: (1 - k / q + k * k) / a0)
        }
        blockLength = max(1, Int((Self.blockSeconds * sampleRate).rounded()))
        reset()
    }

    mutating func reset() {
        for index in shelfState.indices { shelfState[index] = 0; highPassState[index] = 0 }
        blockEnergy = 0
        blockFrames = 0
        filledBlocks = 0
        nextBlock = 0
    }

    /// Frames still needed to complete the current block.
    var framesUntilBlockEnds: Int { blockLength - blockFrames }

    /// Measure `frameCount` frames starting at `offset`, which must not run
    /// past the end of the current block. Returns the momentary mean square
    /// when this completes a block, otherwise nil.
    mutating func measure(_ channels: [UnsafeMutablePointer<Float>], offset: Int, frameCount: Int) -> Double? {
        let width = min(channels.count, Self.maximumChannels)
        let s = shelf, h = highPass
        var energy: Double = 0

        for index in 0..<width {
            let samples = channels[index]
            var s1 = shelfState[2 * index], s2 = shelfState[2 * index + 1]
            var h1 = highPassState[2 * index], h2 = highPassState[2 * index + 1]
            for frame in offset..<(offset + frameCount) {
                let x = Double(samples[frame])
                let y = s.b0 * x + s1
                s1 = s.b1 * x - s.a1 * y + s2
                s2 = s.b2 * x - s.a2 * y
                let z = h.b0 * y + h1
                h1 = h.b1 * y - h.a1 * z + h2
                h2 = h.b2 * y - h.a2 * z
                energy += z * z
            }
            shelfState[2 * index] = s1; shelfState[2 * index + 1] = s2
            highPassState[2 * index] = h1; highPassState[2 * index + 1] = h2
        }

        blockEnergy += energy
        blockFrames += frameCount
        guard blockFrames >= blockLength else { return nil }

        blocks[nextBlock] = blockEnergy / Double(blockFrames)
        nextBlock = (nextBlock + 1) % Self.momentaryBlocks
        filledBlocks = min(filledBlocks + 1, Self.momentaryBlocks)
        blockEnergy = 0
        blockFrames = 0

        var sum: Double = 0
        for index in 0..<filledBlocks { sum += blocks[index] }
        return sum / Double(filledBlocks)
    }

    /// Mean square to loudness in LUFS.
    static func loudness(meanSquare: Double) -> Double {
        -0.691 + 10 * log10(max(meanSquare, 1e-12))
    }
}

// MARK: - Normaliser

/// Brings whatever plays to about the same loudness — a quiet video and a loud
/// advert, one site and the next.
///
/// It keeps a running estimate of the programme's loudness from the momentary
/// measurement and applies the gain that moves the estimate to the target.
/// There is no look-ahead, so a sudden jump is heard briefly before the gain
/// catches up; a big jump is followed much faster than the chosen speed, and a
/// limiter stops any peak from going past the ceiling in the meantime.
///
/// Silence is not measured. Otherwise a pause would slowly raise the gain until
/// background noise filled it, and the next sound would arrive far too loud.
final class LoudnessNormalizer: @unchecked Sendable {
    /// Below this, audio counts as silence and the gain holds, in LUFS.
    static let silenceThreshold: Double = -50
    /// A rise this far above the estimate is followed quickly whatever the
    /// speed, in LU.
    static let jumpThreshold: Double = 10
    static let jumpTimeConstant: Double = 0.25
    /// A drop this far below the estimate is taken for a pause at first and
    /// only followed once it has lasted `pauseSeconds`.
    static let pauseThreshold: Double = 20
    static let pauseSeconds: Double = 2
    /// The most a loud programme is turned down, in dB.
    static let maximumCut: Double = 30
    /// Peaks never go above this, in dBFS.
    static let ceiling: Double = -1

    // Touched only by the processing thread.
    private var meter = LoudnessMeter()
    private var sampleRate: Double = 0
    private var estimate: Double?
    private var pausedBlocks = 0
    private var catchingUp = false
    private var targetGain: Double = 1
    private var gain: Double = 1
    private var smoothing: Double = 0
    private var limiter = PeakLimiter()
    private var limiterRelease: Double = 0

    private var readingLock = os_unfair_lock()
    private var storedReading = LoudnessReading(loudness: nil, gain: 0)

    /// The latest estimate and gain. Safe to read from any thread.
    var reading: LoudnessReading {
        os_unfair_lock_lock(&readingLock); defer { os_unfair_lock_unlock(&readingLock) }
        return storedReading
    }

    /// Forget everything heard so far. Call from the processing thread, when
    /// normalisation is switched on or playback starts afresh.
    func reset() {
        meter.reset()
        estimate = nil
        pausedBlocks = 0
        catchingUp = false
        targetGain = 1
        gain = 1
        limiter.reset()
        publish()
    }

    /// Normalise the channels in place. Runs on a real-time thread.
    func process(_ channels: [UnsafeMutablePointer<Float>], frameCount: Int, sampleRate rate: Double,
                 tuning: LoudnessTuning.Values = LoudnessTuning.shared.values) {
        guard frameCount > 0, !channels.isEmpty, rate > 0 else { return }
        if rate != sampleRate {
            sampleRate = rate
            meter.configure(sampleRate: rate)
            smoothing = exp(-1 / (0.05 * rate))
            limiterRelease = exp(-1 / (0.08 * rate))
            reset()
        }

        var offset = 0
        while offset < frameCount {
            let chunk = min(frameCount - offset, meter.framesUntilBlockEnds)
            if let momentary = meter.measure(channels, offset: offset, frameCount: chunk) {
                follow(momentary, tuning: tuning)
            }

            let target = targetGain
            var current = gain
            let pole = smoothing
            for frame in offset..<(offset + chunk) {
                current = target + (current - target) * pole
                let value = Float(current)
                for channel in channels { channel[frame] *= value }
            }
            gain = current
            offset += chunk
        }

        limiter.process(channels, frameCount: frameCount,
                        ceiling: pow(10, Self.ceiling / 20), release: limiterRelease)
    }

    /// Move the estimate toward one new block's momentary loudness.
    private func follow(_ momentary: Double, tuning: LoudnessTuning.Values) {
        let loudness = LoudnessMeter.loudness(meanSquare: momentary)

        if loudness > Self.silenceThreshold {
            if let current = estimate {
                var follows = true
                if loudness < current - Self.pauseThreshold {
                    pausedBlocks += 1
                    follows = Double(pausedBlocks) * LoudnessMeter.blockSeconds >= Self.pauseSeconds
                } else {
                    pausedBlocks = 0
                }

                if follows {
                    // Once a jump starts, keep following it quickly until the
                    // estimate has actually arrived, not just come within range.
                    if loudness > current + Self.jumpThreshold {
                        catchingUp = true
                    } else if loudness < current + 1 {
                        catchingUp = false
                    }
                    let timeConstant: Double
                    if catchingUp {
                        timeConstant = min(tuning.speed.rise, Self.jumpTimeConstant)
                    } else {
                        timeConstant = loudness > current ? tuning.speed.rise : tuning.speed.fall
                    }
                    let alpha = 1 - exp(-LoudnessMeter.blockSeconds / timeConstant)
                    estimate = current + alpha * (loudness - current)
                }
            } else {
                estimate = loudness
            }
        }

        if let estimate {
            let decibels = min(max(tuning.target - estimate, -Self.maximumCut), max(0, tuning.maximumBoost))
            targetGain = pow(10, decibels / 20)
        }
        publish()
    }

    private func publish() {
        let reading = LoudnessReading(loudness: estimate, gain: 20 * log10(max(targetGain, 1e-9)))
        os_unfair_lock_lock(&readingLock)
        storedReading = reading
        os_unfair_lock_unlock(&readingLock)
    }
}
