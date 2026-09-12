import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Writes screen video and audio from any device into a single file.
///
/// ScreenCaptureKit's SCRecordingOutput handles audio for you, but only from
/// system audio and the microphone. Putting a mix on the recording means
/// muxing video and audio ourselves.
///
///     SCStream (video)       ┐
///                            ├→ AVAssetWriter → .mov
///     DeviceInput (audio)    ┘
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
            throw CoreAudioError.missing("the video track")
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
        // Close over the lock synchronously; never hold it across an await.
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

    // MARK: - Video

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.lock()
        defer { lock.unlock() }

        // The first video frame sets the origin of the timeline. Audio that
        // arrives earlier is simply dropped so the origin always follows video.
        if !hasStartedSession {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            hasStartedSession = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)
    }

    // MARK: - Audio

    /// Write a buffer from the AUHAL onto the same timeline as the video.
    func appendAudio(_ buffer: AVAudioPCMBuffer, at timeStamp: AudioTimeStamp) {
        lock.lock()
        defer { lock.unlock() }

        guard hasStartedSession, let audioInput, audioInput.isReadyForMoreMediaData else { return }

        // Use the host time the AUHAL supplies. Substituting arrival time
        // introduces jitter.
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
