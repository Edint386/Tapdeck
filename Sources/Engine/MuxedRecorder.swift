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

    /// One writer input per audio track. A multichannel source is split into
    /// stereo pairs, each written as its own track, so an editor sees the
    /// microphone and the system audio (say) as separate tracks rather than one
    /// wide track it may not know how to take apart.
    private let audioInputs: [AVAssetWriterInput]
    private let trackFormat: AVAudioFormat?
    private let sourceChannelCount: Int

    private var audioFormatDescription: CMAudioFormatDescription?

    /// How many audio tracks the file will contain.
    var audioTrackCount: Int { audioInputs.count }
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
            let channels = Int(audioFormat.channelCount)
            sourceChannelCount = channels
            let trackChannels = channels == 1 ? 1 : 2
            let trackCount = channels <= 2 ? 1 : (channels + 1) / 2
            trackFormat = AVAudioFormat.discrete(sampleRate: audioFormat.sampleRate,
                                                 channels: trackChannels)

            var inputs: [AVAssetWriterInput] = []
            for _ in 0..<trackCount {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audioFormat.sampleRate,
                    AVNumberOfChannelsKey: trackChannels,
                    AVEncoderBitRateKey: trackChannels == 1 ? 96_000 : 192_000,
                ])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { break }
                writer.add(input)
                inputs.append(input)
            }
            audioInputs = inputs
        } else {
            sourceChannelCount = 0
            trackFormat = nil
            audioInputs = []
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
        audioInputs.forEach { $0.markAsFinished() }
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

    /// Write a buffer from the AUHAL onto the same timeline as the video,
    /// splitting it into one track per channel pair.
    func appendAudio(_ buffer: AVAudioPCMBuffer, at timeStamp: AudioTimeStamp) {
        lock.lock()
        defer { lock.unlock() }

        guard hasStartedSession, !audioInputs.isEmpty, let trackFormat,
              let source = buffer.floatChannelData else { return }

        // Use the host time the AUHAL supplies. Substituting arrival time
        // introduces jitter.
        let presentationTime: CMTime
        if timeStamp.mFlags.contains(.hostTimeValid) {
            presentationTime = CMClockMakeHostTimeFromSystemUnits(timeStamp.mHostTime)
        } else {
            presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        }

        let frames = Int(buffer.frameLength)
        let available = Int(buffer.format.channelCount)
        let trackChannels = Int(trackFormat.channelCount)

        for (track, input) in audioInputs.enumerated() where input.isReadyForMoreMediaData {
            guard let part = AVAudioPCMBuffer(pcmFormat: trackFormat,
                                              frameCapacity: AVAudioFrameCount(frames)),
                  let target = part.floatChannelData else { continue }
            part.frameLength = AVAudioFrameCount(frames)

            for channel in 0..<trackChannels {
                // An odd channel out at the end is duplicated rather than left
                // silent on one side.
                let from = min(track * 2 + channel, available - 1)
                target[channel].update(from: source[from], count: frames)
            }
            guard let sample = makeSampleBuffer(from: part, at: presentationTime) else { continue }
            input.append(sample)
        }
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
