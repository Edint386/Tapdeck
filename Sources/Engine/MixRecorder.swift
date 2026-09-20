import AVFoundation
import Foundation

/// Records what a mix plays to an audio file, with no screen capture involved.
///
/// This is the plain case Audio Hijack covers: keep what you are already
/// routing — a call, a stream, one app's sound — as a file.
///
/// The mix arrives on a real-time thread, where opening or writing a file is
/// forbidden: a blocked audio thread is a dropout. So the audio is copied into
/// a ring buffer there, and a timer on a background queue writes whatever has
/// gathered.
final class MixRecorder: @unchecked Sendable {

    /// What the file holds. AAC keeps recordings small; WAV stays untouched,
    /// which matters when the recording is edited afterwards or has more than
    /// two channels.
    enum FileFormat: String, Codable, CaseIterable, Identifiable {
        case aac, wav

        var id: String { rawValue }
        var fileExtension: String { self == .aac ? "m4a" : "wav" }
        var title: String {
            switch self {
            case .aac: return "AAC (.m4a) — smaller files"
            case .wav: return "WAV — uncompressed"
            }
        }
    }

    let url: URL
    let channelCount: Int
    let sampleRate: Double

    private let ring: AudioRingBuffer
    private let scratch: AVAudioPCMBuffer
    private var file: AVAudioFile?
    private let fileLock = NSLock()

    private let queue = DispatchQueue(label: "dev.kosuke.Tapdeck.MixRecorder", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let started = Date()

    /// How long the recording has been running.
    var elapsed: TimeInterval { Date().timeIntervalSince(started) }

    /// Frames written so far, for showing progress and the file's length.
    private(set) var writtenFrames: Int64 = 0

    init(url: URL, sampleRate: Double, channels: Int, format: FileFormat) throws {
        self.url = url
        self.sampleRate = sampleRate
        channelCount = max(1, channels)

        guard let streamFormat = AVAudioFormat.discrete(sampleRate: sampleRate, channels: channelCount) else {
            throw CoreAudioError.missing("a format for the recording")
        }
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        switch format {
        case .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = channelCount > 2 ? 320_000 : 256_000
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)

        // Four seconds of slack: enough that a busy moment on the writing
        // queue costs nothing, while the memory stays small.
        ring = AudioRingBuffer(channels: channelCount,
                               capacityFrames: Int(sampleRate * 4),
                               primeFrames: 0)
        guard let scratch = AVAudioPCMBuffer(pcmFormat: streamFormat, frameCapacity: 16_384) else {
            throw CoreAudioError.missing("a buffer for the recording")
        }
        self.scratch = scratch
    }

    /// Begin writing. The file exists from here on, even if nothing plays.
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    /// Hand over one block of the mix. Runs on the mix's real-time thread.
    func append(_ channels: [UnsafeMutablePointer<Float>], frameCount: Int) {
        ring.write(channels.map { UnsafePointer($0) }, frameCount: frameCount)
    }

    /// Write what is left and close the file.
    func finish() {
        timer?.cancel()
        timer = nil
        queue.sync { drain() }
        fileLock.lock()
        file = nil
        fileLock.unlock()
    }

    private func drain() {
        guard let data = scratch.floatChannelData else { return }
        let channels = (0..<channelCount).map { data[$0] }
        let capacity = Int(scratch.frameCapacity)

        while true {
            let frames = min(ring.availableFrames, capacity)
            guard frames > 0 else { return }
            for channel in channels { channel.update(repeating: 0, count: frames) }
            ring.mixInto(channels, frameCount: frames, gain: 1)
            scratch.frameLength = AVAudioFrameCount(frames)

            fileLock.lock()
            try? file?.write(from: scratch)
            fileLock.unlock()
            writtenFrames += Int64(frames)
        }
    }
}
