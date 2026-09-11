import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// 画面の映像と、任意のオーディオデバイスの音声を1つのファイルにまとめる。
///
/// ScreenCaptureKit の SCRecordingOutput は音声も内部で面倒を見てくれるが、
/// 音源は「システム音声」と「マイク」に固定される。ミキサーで組んだ音を
/// 収録に乗せるには、映像と音声を自前で多重化するしかない。
///
///     SCStream (映像)        ┐
///                            ├→ AVAssetWriter → .mov
///     DeviceInput (音声)     ┘
final class MuxedRecorder: NSObject, @unchecked Sendable {

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?

    private var audioFormatDescription: CMAudioFormatDescription?
    private var hasStartedSession = false
    private let lock = NSLock()

    private(set) var outputURL: URL

    init(outputURL: URL, videoSize: CGSize, audioFormat: AVAudioFormat?) throws {
        self.outputURL = outputURL
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw CoreAudioError.missing("映像トラック")
        }
        writer.add(videoInput)

        if let audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audioFormat.sampleRate,
                AVNumberOfChannelsKey: audioFormat.channelCount,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }
    }

    func start() {
        writer.startWriting()
    }

    func finish() async {
        // ロックは同期の内側で閉じる。await を跨いで保持してはいけない。
        markInputsFinished()
        await writer.finishWriting()
    }

    private func markInputsFinished() {
        lock.lock()
        defer { lock.unlock() }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
    }

    var failure: Error? { writer.error }

    // MARK: - 映像

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.lock()
        defer { lock.unlock() }

        // 最初の映像フレームで時間軸の原点を決める。
        // 音声が先に来ても捨てるだけにして、原点は必ず映像に合わせる。
        if !hasStartedSession {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            hasStartedSession = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)
    }

    // MARK: - 音声

    /// AUHAL から受け取ったバッファを、映像と同じ時間軸に載せて書き込む。
    func appendAudio(_ buffer: AVAudioPCMBuffer, at timeStamp: AudioTimeStamp) {
        lock.lock()
        defer { lock.unlock() }

        guard hasStartedSession, let audioInput, audioInput.isReadyForMoreMediaData else { return }

        // 時刻は AUHAL が渡すホスト時間を使う。到着時刻で代用するとジッタが乗る。
        let presentationTime: CMTime
        if timeStamp.mFlags.contains(.hostTimeValid) {
            presentationTime = CMClockMakeHostTimeFromSystemUnits(timeStamp.mHostTime)
        } else {
            presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        }

        guard let sampleBuffer = makeSampleBuffer(from: buffer, at: presentationTime) else { return }
        audioInput.append(sampleBuffer)
    }

    private func makeSampleBuffer(from buffer: AVAudioPCMBuffer,
                                  at presentationTime: CMTime) -> CMSampleBuffer? {
        if audioFormatDescription == nil {
            var description: CMAudioFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: buffer.format.streamDescription,
                layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description)
            guard status == noErr else { return nil }
            audioFormatDescription = description
        }
        guard let formatDescription = audioFormatDescription else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid)

        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        let attachStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            bufferList: buffer.audioBufferList)
        guard attachStatus == noErr else { return nil }

        return sampleBuffer
    }
}
