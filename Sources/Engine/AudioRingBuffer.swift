import AVFoundation
import Foundation

/// 音源1つぶんのリングバッファ。
///
/// ミキサーの各ソースは互いに独立したクロックで動く（Process Tap は既定出力の
/// クロック、マイクは自分のクロック）。出力側のコールバックとは周期も位相も
/// 揃わないため、間にこれを挟んで速度差を吸収する。
///
/// 溢れたら古いものを捨て、足りなければ無音を返す。音が途切れるより
/// 遅延が溜まり続ける方が体感的に悪いため、この方針を採る。
final class AudioRingBuffer: @unchecked Sendable {

    private let capacityFrames: Int
    private let channelCount: Int
    private var storage: [Float]

    private var writePosition = 0
    private var filledFrames = 0
    private let lock = NSLock()

    /// 読み出しを始める前に溜めておくフレーム数（＝意図的な遅延）。
    ///
    /// 音源と出力先は別クロックで動くため、レートを揃えても位相は揃わない。
    /// 溜めずに読み出すとバッファが常に空寸前になり、わずかな揺らぎのたびに
    /// 波形へ隙間が入る。全体の音量は合っているのに特定の周波数成分だけが
    /// 落ちる、という形で現れる（実測: 440Hz 正弦波が -21.1 dB のはずが -39.2 dB）。
    private let primeFrames: Int

    /// 溜まりきって読み出しを開始したか。枯れたら false に戻して溜め直す。
    private var isPrimed = false

    /// 直近に書き込まれた区間のピーク。メーター表示用。
    private var recentPeak: Float = 0

    init(channels: Int, capacityFrames: Int = 16384, primeFrames: Int = 2048) {
        self.channelCount = max(1, channels)
        self.capacityFrames = max(512, capacityFrames)
        self.primeFrames = min(max(0, primeFrames), self.capacityFrames / 2)
        self.storage = [Float](repeating: 0, count: self.channelCount * self.capacityFrames)
    }

    /// 読み出しが枯れた回数。多いなら primeFrames を増やすべき。
    private(set) var underrunCount = 0

    /// 未読データを上書きしてしまった回数。振幅は保たれたまま位相が飛ぶ原因。
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

    /// 直近のピークを取り出して 0 に戻す。
    func takePeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let value = recentPeak
        recentPeak = 0
        return value
    }

    // MARK: - 書き込み

    /// 音源から届いたバッファを書き込む。
    /// チャンネル数が合わない場合はモノラルを複製、または先頭チャンネルを採用する。
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
                // モノラル音源はそのまま全チャンネルへ。多チャンネルは先頭から対応づける。
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

    // MARK: - 読み出し

    /// 出力先のバッファへ加算する。ミキサーはこれを全ソースぶん呼ぶ。
    /// 溜まっている量が足りない分は何も加算しない（＝その区間は無音）。
    func mixInto(_ destination: [UnsafeMutablePointer<Float>],
                 frameCount: Int,
                 gain: Float) {
        guard gain != 0 else { consume(frameCount); return }

        lock.lock()
        defer { lock.unlock() }

        // 溜まりきるまでは出さない。中途半端に出すと隙間の連続になる。
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

        // filledFrames ぶん遡った位置が読み出し開始点。
        let readStart = ((writePosition - filledFrames) % capacityFrames + capacityFrames)
                        % capacityFrames

        let channels = min(destination.count, channelCount)
        for frame in 0..<usable {
            let slot = (readStart + frame) % capacityFrames
            for channel in 0..<channels {
                destination[channel][frame] += storage[channel * capacityFrames + slot] * gain
            }
        }
        filledFrames -= usable
    }

    /// ミュート中のソースを進めるだけ進める（遅延が溜まらないように）。
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

    /// いま溜まっているフレーム数（遅延の目安）。
    var fill: Int {
        lock.lock(); defer { lock.unlock() }
        return filledFrames
    }
}
