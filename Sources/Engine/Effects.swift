import AVFoundation
import Foundation

// MARK: - Settings

/// Everything that can be done to one source's sound.
///
/// All effects start off, and with everything off the chain does no work at
/// all, so an untouched source is bit-identical to what was captured.
struct EffectSettings: Codable, Equatable {

    // Filters

    /// Removes rumble, handling noise and hum below the corner. 24 dB/octave.
    var lowCutEnabled = false
    var lowCutFrequency: Double = 80

    /// Removes hiss and harshness above the corner. 24 dB/octave.
    var highCutEnabled = false
    var highCutFrequency: Double = 16_000

    // Equaliser

    struct Band: Codable, Equatable {
        enum Shape: String, Codable { case lowShelf, peak, highShelf }
        var shape: Shape
        var frequency: Double
        /// Boost or cut in dB.
        var gain: Double = 0
        /// Width of a peak band. Ignored by shelves.
        var q: Double = 1
    }

    var eqEnabled = false
    var bands: [Band] = EffectSettings.defaultBands

    static let defaultBands: [Band] = [
        Band(shape: .lowShelf, frequency: 100),
        Band(shape: .peak, frequency: 300),
        Band(shape: .peak, frequency: 1_000),
        Band(shape: .peak, frequency: 3_000),
        Band(shape: .highShelf, frequency: 8_000),
    ]

    // Dynamics

    /// Silences the source while it stays below the threshold — background
    /// noise between words on a microphone.
    var gateEnabled = false
    var gateThreshold: Double = -45

    /// Evens out the difference between loud and quiet passages.
    var compressorEnabled = false
    var compressorThreshold: Double = -18
    var compressorRatio: Double = 3
    /// Gain added after compression, in dB.
    var compressorMakeup: Double = 0

    /// Stops peaks from ever exceeding the ceiling.
    var limiterEnabled = false
    var limiterCeiling: Double = -1

    // Loudness

    /// Brings the source to the loudness set in Settings, however loud or
    /// quiet it plays on its own.
    var loudnessEnabled = false

    // Stereo

    /// -1 is fully left, +1 fully right. Balance, not pan: the centre position
    /// leaves both channels untouched.
    var balance: Double = 0

    /// Fold both channels into one, placed on both sides.
    var mono = false

    // Timing

    /// Holds this source back, in milliseconds — to line a microphone up with
    /// a delayed video, for instance.
    var delay: Double = 0

    static let maximumDelay: Double = 2_000

    /// Whether anything at all is switched on.
    var isActive: Bool {
        lowCutEnabled || highCutEnabled || (eqEnabled && bands.contains { $0.gain != 0 })
            || gateEnabled || compressorEnabled || limiterEnabled || loudnessEnabled
            || balance != 0 || mono || delay > 0
    }
}

extension EffectSettings {
    /// Every key is optional, so settings saved before an effect existed still
    /// load — with that effect off — instead of failing and losing the mix.
    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func load<Value: Decodable>(_ key: CodingKeys, _ value: inout Value) throws {
            if let decoded = try container.decodeIfPresent(Value.self, forKey: key) { value = decoded }
        }
        try load(.lowCutEnabled, &lowCutEnabled)
        try load(.lowCutFrequency, &lowCutFrequency)
        try load(.highCutEnabled, &highCutEnabled)
        try load(.highCutFrequency, &highCutFrequency)
        try load(.eqEnabled, &eqEnabled)
        try load(.bands, &bands)
        try load(.gateEnabled, &gateEnabled)
        try load(.gateThreshold, &gateThreshold)
        try load(.compressorEnabled, &compressorEnabled)
        try load(.compressorThreshold, &compressorThreshold)
        try load(.compressorRatio, &compressorRatio)
        try load(.compressorMakeup, &compressorMakeup)
        try load(.limiterEnabled, &limiterEnabled)
        try load(.limiterCeiling, &limiterCeiling)
        try load(.loudnessEnabled, &loudnessEnabled)
        try load(.balance, &balance)
        try load(.mono, &mono)
        try load(.delay, &delay)
    }
}

extension EffectSettings {
    /// Starting points for the equaliser, as gains for the five default bands.
    struct Preset: Identifiable {
        let id: String
        let gains: [Double]
    }

    static let equaliserPresets: [Preset] = [
        Preset(id: "Flat", gains: [0, 0, 0, 0, 0]),
        Preset(id: "Voice clarity", gains: [-4, -2, 1, 3, 1]),
        Preset(id: "Warm voice", gains: [2, 1, 0, -1, -2]),
        Preset(id: "Bass boost", gains: [6, 2, 0, 0, 0]),
        Preset(id: "Treble boost", gains: [0, 0, 0, 2, 5]),
        Preset(id: "Reduce harshness", gains: [0, 0, 0, -4, -2]),
        Preset(id: "Small speakers", gains: [-6, 2, 1, 1, 0]),
    ]
}

// MARK: - Biquad

/// A second-order filter section, in transposed direct form II.
///
/// Coefficients and state are Double: low-frequency filters at high sample
/// rates have poles very close to the unit circle, where single precision loses
/// enough accuracy to be heard as noise.
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    // Coefficient formulas from Robert Bristow-Johnson's Audio EQ Cookbook.

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let (_, alpha, cosw0) = prewarp(frequency, q, sampleRate)
        return normalised(b0: (1 + cosw0) / 2, b1: -(1 + cosw0), b2: (1 + cosw0) / 2,
                          a0: 1 + alpha, a1: -2 * cosw0, a2: 1 - alpha)
    }

    static func lowPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let (_, alpha, cosw0) = prewarp(frequency, q, sampleRate)
        return normalised(b0: (1 - cosw0) / 2, b1: 1 - cosw0, b2: (1 - cosw0) / 2,
                          a0: 1 + alpha, a1: -2 * cosw0, a2: 1 - alpha)
    }

    static func peak(frequency: Double, q: Double, gain: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gain / 40)
        let (_, alpha, cosw0) = prewarp(frequency, q, sampleRate)
        return normalised(b0: 1 + alpha * a, b1: -2 * cosw0, b2: 1 - alpha * a,
                          a0: 1 + alpha / a, a1: -2 * cosw0, a2: 1 - alpha / a)
    }

    /// Shelves use a slope of 1, the steepest without overshoot.
    static func lowShelf(frequency: Double, gain: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gain / 40)
        let (_, alpha, cosw0) = prewarp(frequency, 1 / 2.0.squareRoot(), sampleRate)
        let s = 2 * a.squareRoot() * alpha
        return normalised(b0: a * ((a + 1) - (a - 1) * cosw0 + s),
                          b1: 2 * a * ((a - 1) - (a + 1) * cosw0),
                          b2: a * ((a + 1) - (a - 1) * cosw0 - s),
                          a0: (a + 1) + (a - 1) * cosw0 + s,
                          a1: -2 * ((a - 1) + (a + 1) * cosw0),
                          a2: (a + 1) + (a - 1) * cosw0 - s)
    }

    static func highShelf(frequency: Double, gain: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gain / 40)
        let (_, alpha, cosw0) = prewarp(frequency, 1 / 2.0.squareRoot(), sampleRate)
        let s = 2 * a.squareRoot() * alpha
        return normalised(b0: a * ((a + 1) + (a - 1) * cosw0 + s),
                          b1: -2 * a * ((a - 1) + (a + 1) * cosw0),
                          b2: a * ((a + 1) + (a - 1) * cosw0 - s),
                          a0: (a + 1) - (a - 1) * cosw0 + s,
                          a1: 2 * ((a - 1) - (a + 1) * cosw0),
                          a2: (a + 1) - (a - 1) * cosw0 - s)
    }

    private static func prewarp(_ frequency: Double, _ q: Double, _ sampleRate: Double)
        -> (w0: Double, alpha: Double, cosw0: Double) {
        // Keep the corner below Nyquist, or the coefficients become unstable.
        let f = min(max(10, frequency), sampleRate * 0.45)
        let w0 = 2 * Double.pi * f / sampleRate
        return (w0, sin(w0) / (2 * max(0.05, q)), cos(w0))
    }

    private static func normalised(b0: Double, b1: Double, b2: Double,
                                   a0: Double, a1: Double, a2: Double) -> Biquad {
        Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

/// One biquad's memory for every channel.
private struct BiquadRun {
    var coefficients = Biquad()
    var z1 = [Double](repeating: 0, count: EffectChain.maximumChannels)
    var z2 = [Double](repeating: 0, count: EffectChain.maximumChannels)

    mutating func process(_ channel: UnsafeMutablePointer<Float>, index: Int, frameCount: Int) {
        let c = coefficients
        var s1 = z1[index], s2 = z2[index]
        for frame in 0..<frameCount {
            let x = Double(channel[frame])
            let y = c.b0 * x + s1
            s1 = c.b1 * x - c.a1 * y + s2
            s2 = c.b2 * x - c.a2 * y
            channel[frame] = Float(y)
        }
        z1[index] = s1
        z2[index] = s2
    }
}

// MARK: - Chain

/// Runs one source's effects over each buffer it captures.
///
/// Settings arrive from the main thread; processing happens on the capture
/// thread. The two meet under a lock that is only held long enough to copy the
/// settings, and coefficients are rebuilt on the capture thread when they
/// change. Filter memory is kept across a change, so moving an EQ slider does
/// not restart the filters.
final class EffectChain: @unchecked Sendable {
    static let maximumChannels = 16

    /// Butterworth sections: two second-order stages with these Qs make a
    /// fourth-order filter that is -3 dB at the corner and 24 dB/octave beyond.
    private static let butterworthQs = [0.54119610, 1.30656296]

    private let lock = NSLock()
    private var pending = EffectSettings()
    private var pendingVersion = 0

    // Everything below is touched only by the processing thread.
    private var settings = EffectSettings()
    private var appliedVersion = -1
    private var sampleRate: Double = 0

    private var lowCut = [BiquadRun(), BiquadRun()]
    private var highCut = [BiquadRun(), BiquadRun()]
    private var bands: [BiquadRun] = []

    private var gateEnvelope: Double = 0
    private var gateGain: Double = 0
    private var gateHold = 0

    private var compressorEnvelope: Double = 0
    private var compressorReduction: Double = 0

    private var limiter = PeakLimiter()
    private let normalizer = LoudnessNormalizer()

    private var delayLine: DelayLine?
    private var delayChannels = 0

    /// What loudness normalisation is doing, when it is on. Safe to read from
    /// any thread.
    var loudnessReading: LoudnessReading { normalizer.reading }

    /// Replace the settings. Safe to call from any thread.
    func update(_ settings: EffectSettings) {
        lock.lock()
        pending = settings
        pendingVersion += 1
        lock.unlock()
    }

    /// Process a buffer in place.
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let count = min(Int(buffer.format.channelCount), Self.maximumChannels)
        guard frames > 0, count > 0 else { return }
        let channels = (0..<count).map { data[$0] }
        process(channels, frameCount: frames, sampleRate: buffer.format.sampleRate)
    }

    func process(_ channels: [UnsafeMutablePointer<Float>], frameCount: Int, sampleRate rate: Double) {
        lock.lock()
        let version = pendingVersion
        let latest = pending
        lock.unlock()

        if version != appliedVersion || rate != sampleRate {
            let rateChanged = rate != sampleRate
            // Start measuring afresh each time normalisation is switched on,
            // rather than from whatever was heard the last time.
            if latest.loudnessEnabled && !settings.loudnessEnabled { normalizer.reset() }
            settings = latest
            sampleRate = rate
            appliedVersion = version
            rebuild(rateChanged: rateChanged, channelCount: channels.count)
        }
        guard settings.isActive else { return }

        if settings.mono && channels.count >= 2 { foldToMono(channels, frameCount) }

        for index in channels.indices {
            let channel = channels[index]
            if settings.lowCutEnabled {
                lowCut[0].process(channel, index: index, frameCount: frameCount)
                lowCut[1].process(channel, index: index, frameCount: frameCount)
            }
            if settings.highCutEnabled {
                highCut[0].process(channel, index: index, frameCount: frameCount)
                highCut[1].process(channel, index: index, frameCount: frameCount)
            }
            if settings.eqEnabled {
                for band in bands.indices where settings.bands[band].gain != 0 {
                    bands[band].process(channel, index: index, frameCount: frameCount)
                }
            }
        }

        if settings.gateEnabled { gate(channels, frameCount) }
        if settings.compressorEnabled { compress(channels, frameCount) }
        if settings.balance != 0 && channels.count >= 2 { applyBalance(channels, frameCount) }
        if settings.loudnessEnabled {
            normalizer.process(channels, frameCount: frameCount, sampleRate: sampleRate)
        }
        if settings.limiterEnabled { limit(channels, frameCount) }

        if settings.delay > 0, let delayLine {
            delayLine.process(channels, frameCount: frameCount,
                              targetDelay: Int((settings.delay / 1000 * sampleRate).rounded()))
        }
    }

    // MARK: Rebuilding

    private func rebuild(rateChanged: Bool, channelCount: Int) {
        let rate = sampleRate
        for (stage, q) in Self.butterworthQs.enumerated() {
            lowCut[stage].coefficients = .highPass(frequency: settings.lowCutFrequency, q: q, sampleRate: rate)
            highCut[stage].coefficients = .lowPass(frequency: settings.highCutFrequency, q: q, sampleRate: rate)
        }

        if bands.count != settings.bands.count {
            bands = Array(repeating: BiquadRun(), count: settings.bands.count)
        }
        for (index, band) in settings.bands.enumerated() {
            switch band.shape {
            case .lowShelf:
                bands[index].coefficients = .lowShelf(frequency: band.frequency, gain: band.gain, sampleRate: rate)
            case .highShelf:
                bands[index].coefficients = .highShelf(frequency: band.frequency, gain: band.gain, sampleRate: rate)
            case .peak:
                bands[index].coefficients = .peak(frequency: band.frequency, q: band.q, gain: band.gain,
                                                  sampleRate: rate)
            }
        }

        // The delay line depends on the rate and the channel count. Its first
        // position is set without a fade: there is no earlier audio to fade from.
        if settings.delay > 0, rateChanged || delayLine == nil || delayChannels != channelCount {
            delayLine = DelayLine(channels: channelCount,
                                  maximumFrames: Int(EffectSettings.maximumDelay / 1000 * rate))
            delayLine?.jump(to: Int((settings.delay / 1000 * rate).rounded()))
            delayChannels = channelCount
        }
    }

    // MARK: Stereo

    private func foldToMono(_ channels: [UnsafeMutablePointer<Float>], _ frameCount: Int) {
        let scale = 1 / Float(channels.count)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in channels { sum += channel[frame] }
            let value = sum * scale
            for channel in channels { channel[frame] = value }
        }
    }

    private func applyBalance(_ channels: [UnsafeMutablePointer<Float>], _ frameCount: Int) {
        let left = Float(min(1, 1 - settings.balance))
        let right = Float(min(1, 1 + settings.balance))
        for frame in 0..<frameCount {
            channels[0][frame] *= left
            channels[1][frame] *= right
        }
    }

    // MARK: Dynamics

    /// Time constant to per-sample smoothing coefficient.
    private func coefficient(milliseconds: Double) -> Double {
        exp(-1 / (milliseconds / 1000 * sampleRate))
    }

    /// Opens quickly when the level rises above the threshold, holds briefly,
    /// then closes along a straight line so it actually reaches silence.
    private func gate(_ channels: [UnsafeMutablePointer<Float>], _ frameCount: Int) {
        let threshold = pow(10, settings.gateThreshold / 20)
        let closeThreshold = threshold * pow(10, -3.0 / 20) // 3 dB of hysteresis
        let envelopeRelease = coefficient(milliseconds: 60)
        let openStep = 1 / (0.002 * sampleRate)
        let closeStep = 1 / (0.100 * sampleRate)
        let holdFrames = Int(0.050 * sampleRate)

        for frame in 0..<frameCount {
            var peak: Double = 0
            for channel in channels { peak = max(peak, Double(abs(channel[frame]))) }
            gateEnvelope = peak > gateEnvelope ? peak : gateEnvelope * envelopeRelease + peak * (1 - envelopeRelease)

            if gateEnvelope >= threshold {
                gateHold = holdFrames
                gateGain = min(1, gateGain + openStep)
            } else if gateHold > 0 {
                gateHold -= 1
            } else if gateEnvelope < closeThreshold {
                gateGain = max(0, gateGain - closeStep)
            }

            let gain = Float(gateGain)
            for channel in channels { channel[frame] *= gain }
        }
    }

    /// A peak-sensing compressor with a soft knee. Peak rather than RMS sensing,
    /// so the threshold refers to the levels the meters show.
    private func compress(_ channels: [UnsafeMutablePointer<Float>], _ frameCount: Int) {
        let threshold = settings.compressorThreshold
        let ratio = max(1, settings.compressorRatio)
        let knee = 6.0
        let makeup = pow(10, settings.compressorMakeup / 20)
        let attack = coefficient(milliseconds: 5)
        let release = coefficient(milliseconds: 120)
        let envelopeRelease = coefficient(milliseconds: 80)

        for frame in 0..<frameCount {
            var peak: Double = 0
            for channel in channels { peak = max(peak, Double(abs(channel[frame]))) }
            compressorEnvelope = peak > compressorEnvelope
                ? peak : compressorEnvelope * envelopeRelease + peak * (1 - envelopeRelease)

            let level = 20 * log10(max(compressorEnvelope, 1e-9))
            let over = level - threshold
            let target: Double
            if over <= -knee / 2 {
                target = 0
            } else if over >= knee / 2 {
                target = over * (1 - 1 / ratio)
            } else {
                let x = over + knee / 2
                target = (1 - 1 / ratio) * x * x / (2 * knee)
            }
            let smoothing = target > compressorReduction ? attack : release
            compressorReduction = target + (compressorReduction - target) * smoothing

            let gain = Float(pow(10, -compressorReduction / 20) * makeup)
            for channel in channels { channel[frame] *= gain }
        }
    }

    private func limit(_ channels: [UnsafeMutablePointer<Float>], _ frameCount: Int) {
        limiter.process(channels, frameCount: frameCount,
                        ceiling: pow(10, settings.limiterCeiling / 20),
                        release: coefficient(milliseconds: 80))
    }
}
