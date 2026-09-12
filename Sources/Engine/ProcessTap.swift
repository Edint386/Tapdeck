import AVFoundation
import CoreAudio
import Foundation

/// Wrapper around Core Audio's process tap API (macOS 14.2+).
///
/// This is the heart of what makes a Loopback-style tool possible: it pulls out
/// the audio of one chosen app, with no virtual audio driver and no kernel
/// extension involved.
///
/// How it works:
///   1. Declare which processes are wanted with a CATapDescription, and create
///      the tap.
///   2. A tap cannot be read on its own, so build a private aggregate device
///      that contains the tap as a sub-device.
///   3. Attach an IOProc to that aggregate device to receive the audio.
final class ProcessTap {

    enum Mode {
        /// Capture only the audio of the given processes.
        case include([AudioProcess])
        /// Capture all system audio except the given processes.
        case excluding([AudioProcess])
    }

    /// Format of the buffers handed to the callback.
    /// A tap's own format is interleaved, but buffers are always normalised to
    /// non-interleaved Float32 here because that is what the mixer wants.
    private(set) var format: AVAudioFormat?
    private(set) var isRunning = false

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var handler: ((AVAudioPCMBuffer) -> Void)?

    private let queue = DispatchQueue(label: "dev.kosuke.Tapdeck.ProcessTap",
                                      qos: .userInitiated)

    deinit { stop() }

    // MARK: - Starting

    /// - Parameter clock: the device to clock the aggregate from. Defaults to
    ///   the default output device.
    ///
    ///   Note that pointing the clock at some other device stops the tap from
    ///   hearing audio that is not flowing there — measured as complete
    ///   silence — so this is left at the default in practice.
    func start(mode: Mode,
               clock: AudioDevice? = nil,
               mute: CATapMuteBehavior = .unmuted,
               onAudio: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard !isRunning else { return }
        handler = onAudio

        do {
            try createTap(mode: mode, mute: mute)
            // Create the aggregate first: the real format has to be read from
            // it rather than from the tap. See resolveFormat below.
            try createAggregateDevice(clockUID: clock?.uid)
            let fmt = try resolveFormat()
            try attachIOProc(format: fmt)
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    private func createTap(mode: Mode, mute: CATapMuteBehavior) throws {
        let description: CATapDescription
        switch mode {
        case .include(let procs):
            description = CATapDescription(
                stereoMixdownOfProcesses: procs.map(\.objectID))
        case .excluding(let procs):
            description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: procs.map(\.objectID))
        }
        description.name = "Tapdeck"
        description.uuid = UUID()
        description.muteBehavior = mute

        try ca("creating the process tap") {
            AudioHardwareCreateProcessTap(description, &tapID)
        }
        guard tapID != 0 else { throw CoreAudioError.missing("the created tap") }
    }

    private func resolveFormat() throws -> AVAudioFormat {
        var asbd: AudioStreamBasicDescription = try AudioObjectID(tapID)
            .read(kAudioTapPropertyFormat, label: "reading the tap format")

        // This is the trap. What actually reaches the IOProc is the aggregate
        // device's input stream, and the aggregate follows the clock of its
        // main sub-device — the default output device. So the rate the tap
        // reports can disagree with the rate the audio arrives at.
        //
        // Measured: the built-in speakers ran at 44100 Hz while
        // kAudioTapPropertyFormat reported 48000 Hz. Trusting the tap shifts
        // every recording by 48000/44100 = 8.8%, turning a 440 Hz tone into
        // 479 Hz.
        if let deviceRate: Float64 = try? AudioObjectID(aggregateID)
            .read(kAudioDevicePropertyNominalSampleRate,
                  label: "reading the aggregate sample rate"),
           deviceRate > 0,
           abs(deviceRate - asbd.mSampleRate) > 1 {
            sampleRateCorrection = (declared: asbd.mSampleRate, actual: deviceRate)
            asbd.mSampleRate = deviceRate
        }

        guard let raw = AVAudioFormat(streamDescription: &asbd) else {
            throw CoreAudioError.missing("the tap format")
        }
        rawFormat = raw

        guard let normalized = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: raw.sampleRate,
                                             channels: raw.channelCount,
                                             interleaved: false) else {
            throw CoreAudioError.missing("the normalised format")
        }
        format = normalized
        return raw
    }

    /// Records a disagreement between the tap's reported rate and the real one.
    private(set) var sampleRateCorrection: (declared: Float64, actual: Float64)?

    /// How often the sample times handed to the IOProc were discontinuous.
    /// If this climbs, audio is being dropped before it reaches the mixer.
    private(set) var discontinuityCount = 0
    private var lastEndSampleTime: Float64?

    /// The format the tap actually produces (interleaved), for diagnostics.
    private(set) var rawFormat: AVAudioFormat?

    /// Split an interleaved buffer into one plane per channel.
    /// Taps always arrive interleaved while AVAudioFile and AVAudioEngine both
    /// expect the opposite, so they are reconciled here.
    private func normalize(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let outFormat = format else { return nil }
        guard src.format.isInterleaved else { return src }

        guard let dst = AVAudioPCMBuffer(pcmFormat: outFormat,
                                         frameCapacity: src.frameLength),
              let source = src.floatChannelData?[0],
              let target = dst.floatChannelData else { return nil }

        let frames = Int(src.frameLength)
        let channels = Int(src.format.channelCount)
        for frame in 0..<frames {
            let base = frame * channels
            for channel in 0..<channels {
                target[channel][frame] = source[base + channel]
            }
        }
        dst.frameLength = src.frameLength
        return dst
    }

    /// Build a private aggregate device containing the tap.
    /// It needs a clock, so the default output device is always included as a
    /// sub-device.
    private func createAggregateDevice(clockUID: String? = nil) throws {
        guard let tapUID = AudioObjectID(tapID).readString(kAudioTapPropertyUID) else {
            throw CoreAudioError.missing("the tap UID")
        }
        let outputUID = try clockUID ?? defaultOutputDeviceUID()

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tapdeck Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID,
                ]
            ],
        ]

        try ca("creating the aggregate device") {
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        }
    }

    private func attachIOProc(format rawFmt: AVAudioFormat) throws {
        try ca("creating the IOProc") {
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) {
                [weak self] _, inInputData, inInputTime, _, _ in
                guard let self, let handler = self.handler else { return }
                guard let raw = AVAudioPCMBuffer(pcmFormat: rawFmt,
                                                 bufferListNoCopy: inInputData),
                      let buffer = self.normalize(raw) else { return }

                // Check the sample times run continuously. If this block does
                // not start where the last one ended, audio was already
                // dropped upstream of us.
                let start = inInputTime.pointee.mSampleTime
                if let previousEnd = self.lastEndSampleTime,
                   abs(start - previousEnd) > 0.5 {
                    self.discontinuityCount += 1
                }
                self.lastEndSampleTime = start + Float64(buffer.frameLength)

                handler(buffer)
            }
        }
        try ca("starting the aggregate device") { AudioDeviceStart(aggregateID, ioProcID) }
    }

    // MARK: - Stopping

    func stop() {
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
        handler = nil
        isRunning = false
        lastEndSampleTime = nil
    }
}
