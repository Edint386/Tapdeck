import AVFoundation
import Foundation

/// Sits between a source and the output when their formats disagree.
///
/// Every mixer source runs on its own clock. A process tap in particular
/// follows the clock of the default output device, so its sample rate differs
/// whenever the mixer feeds some other device (a Tapdeck virtual device at
/// 48000 Hz, say).
///
/// Without conversion the ring buffer starves or overruns and gaps appear in
/// the waveform. It shows up as the overall level being right while one
/// frequency collapses: a measured 440 Hz sine peaked at -21.1 dB overall but
/// its 440 Hz component sat at -52.8 dB.
final class FormatConverter: @unchecked Sendable {

    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    let sourceFormat: AVAudioFormat

    /// Returns nil when the formats already match and no conversion is needed.
    init?(from source: AVAudioFormat, to target: AVAudioFormat) {
        guard source.sampleRate != target.sampleRate
                || source.channelCount != target.channelCount
                || source.commonFormat != target.commonFormat
                || source.isInterleaved != target.isInterleaved else {
            return nil
        }
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        self.converter = converter
        self.targetFormat = target
        self.sourceFormat = source
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
