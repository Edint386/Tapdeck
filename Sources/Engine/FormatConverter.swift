import AVFoundation
import Foundation

/// 音源と出力先のフォーマットが食い違うときに挟む変換器。
///
/// ミキサーの各ソースは別々のクロックで動く。特に Process Tap は
/// 「既定の出力デバイス」のクロックに従うため、出力先が別のデバイス
/// （例: Tapdeck 仮想デバイスの 48000 Hz）だとサンプルレートがずれる。
///
/// 変換しないとリングバッファが枯れたり溢れたりして、波形に隙間が入る。
/// 音量は合っているのに特定の周波数成分だけが激しく落ちる、という形で現れる
/// （実測: 440Hz の正弦波が全体ピーク -21.1 dB に対し 440Hz 成分 -52.8 dB）。
final class FormatConverter: @unchecked Sendable {

    private let converter: AVAudioConverter
    private let targetFormat: AVAudioFormat
    let sourceFormat: AVAudioFormat

    /// フォーマットが同一なら nil を返す（変換不要）。
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
