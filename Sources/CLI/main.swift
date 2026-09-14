import AVFoundation
import CoreAudio
import Foundation

// tapproof — a command line harness for checking that the audio engine works.
// It uses Tapdeck's own engine (Sources/Engine) unchanged.


// MARK: - Logging

// Standard output is discarded when launched through LaunchServices (`open`),
// which is the only way to get a TCC prompt to appear. So results are also
// written to a .log next to the output file.
final class Log {
    static var fileURL: URL?
    private static let lock = NSLock()

    static func setDestination(besideOutput url: URL) {
        let log = url.deletingPathExtension().appendingPathExtension("log")
        fileURL = log
        try? "".write(to: log, atomically: true, encoding: .utf8)
    }

    static func line(_ text: String) {
        print(text)
        guard let fileURL else { return }
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        }
    }
}

func usage() -> Never {
    print("""
    Usage:
      tapproof list
          List the processes Core Audio knows about (marked with a note if playing)

      tapproof rec <pid or app name> <seconds> [out.wav]
          Record only the audio of that application

      tapproof rec-system <seconds> [out.wav]
          Record all system audio, excluding this process

      tapproof devices
          List the audio devices

      tapproof virtual [name[:channels] ...]
          Show the virtual devices, or replace them with the given names

      tapproof mix <seconds> <output[,output...]> <pid or name>@<channel> ...
          Mix applications onto a Tapdeck device, each on its own channel pair
          (@1 means channels 1-2, @3 means channels 3-4)

      tapproof capture <device name> <seconds> [out.wav]
          Record every input channel of a device through the app's own path

      tapproof loopback <seconds> [out.wav]
          Send 440 Hz into a Tapdeck device's output and check it can be
          read back from the same device's input
    """)
    exit(1)
}

func peakAndRMS(_ buffer: AVAudioPCMBuffer) -> (peak: Float, sumSquares: Double, count: Int) {
    guard let data = buffer.floatChannelData else { return (0, 0, 0) }
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    var peak: Float = 0
    var sum: Double = 0
    var count = 0

    if buffer.format.isInterleaved {
        // When interleaved, every channel sits in floatChannelData[0]
        let p = data[0]
        for i in 0..<(frames * channels) {
            let v = abs(p[i]); if v > peak { peak = v }
            sum += Double(v) * Double(v); count += 1
        }
    } else {
        for ch in 0..<channels {
            let p = data[ch]
            for i in 0..<frames {
                let v = abs(p[i]); if v > peak { peak = v }
                sum += Double(v) * Double(v); count += 1
            }
        }
    }
    return (peak, sum, count)
}

func db(_ x: Double) -> String {
    x <= 0 ? "-inf dB" : String(format: "%.1f dB", 20 * log10(x))
}

// MARK: - list

func runList() throws {
    let procs = try AudioProcess.all()
    print("PID     Playing  Name                          Bundle ID")
    print(String(repeating: "─", count: 88))
    for p in procs {
        let mark = p.isPlayingAudio ? " ♪  " : "    "
        let name = p.name.padding(toLength: min(28, max(p.name.count, 28)),
                                  withPad: " ", startingAt: 0)
        print(String(format: "%-7d %@  %@  %@", p.pid, mark, name, p.bundleID ?? "—"))
    }
    print("\n\(procs.count) processes, \(procs.filter(\.isPlayingAudio).count) playing")
}

// MARK: - record

func runRecord(mode: ProcessTap.Mode, label: String, seconds: Double, output: URL) throws {
    let tap = ProcessTap()

    var file: AVAudioFile?
    var peak: Float = 0
    var sumSquares: Double = 0
    var totalSamples = 0
    var callbacks = 0
    var writeError: String?
    let lock = NSLock()

    print("Target : \(label)")
    print("Output : \(output.path)")
    print("Length : \(seconds)s …")

    try tap.start(mode: mode) { buffer in
        lock.lock()
        defer { lock.unlock() }

        if file == nil {
            let fmt = buffer.format
            do {
                // Match the processing format to the tap's exactly. Any
                // mismatch makes write(from:) throw on every buffer.
                file = try AVAudioFile(forWriting: output,
                                       settings: fmt.settings,
                                       commonFormat: fmt.commonFormat,
                                       interleaved: fmt.isInterleaved)
            } catch {
                if writeError == nil { writeError = "creating the file: \(error)" }
            }
        }
        do {
            try file?.write(from: buffer)
        } catch {
            if writeError == nil { writeError = "writing: \(error)" }
        }

        let m = peakAndRMS(buffer)
        if m.peak > peak { peak = m.peak }
        sumSquares += m.sumSquares
        totalSamples += m.count
        callbacks += 1
    }

    guard let fmt = tap.format else { throw CoreAudioError.missing("the tap format") }
    print("Format : \(Int(fmt.sampleRate)) Hz / \(fmt.channelCount) ch / "
          + "\(fmt.commonFormat == .pcmFormatFloat32 ? "Float32" : "other") / "
          + (fmt.isInterleaved ? "interleaved" : "non-interleaved"))

    if let c = tap.sampleRateCorrection {
        print("Fixed  : tap reported \(Int(c.declared)) Hz, real rate is \(Int(c.actual)) Hz")
    }

    Thread.sleep(forTimeInterval: seconds)
    tap.stop()

    lock.lock()
    file = nil
    let finalPeak = peak, finalSum = sumSquares, n = totalSamples, cb = callbacks
    let err = writeError
    lock.unlock()

    if let err { print("!  Write error: \(err)") }
    let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
    print("File size           : \(size) bytes")

    print("\n-- Result --")
    print("IOProc calls        : \(cb)")
    print("Samples captured    : \(n)")
    guard n > 0 else {
        print("!  Not a single sample arrived.")
        exit(2)
    }
    let rms = (finalSum / Double(n)).squareRoot()
    print("Peak                : \(db(Double(finalPeak)))")
    print("RMS                 : \(db(rms))")
    if finalPeak < 1e-6 {
        print("!  Complete silence. The tap works, but the target may not be playing.")
    } else {
        print("OK: audio captured.")
    }
}


/// Ask for microphone access, spinning the main run loop until an answer comes.
///
/// Blocking the main thread on a semaphore does not work: the TCC prompt is
/// presented through the process's main run loop, so stopping it means the
/// prompt never appears. requestAccess returns false immediately and the
/// authorisation status stays undetermined.
func requestMicrophoneAccessSync(timeout: TimeInterval) -> Bool {
    var result: Bool?
    AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { result = granted }
    }

    let deadline = Date().addingTimeInterval(timeout)
    while result == nil, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }

    guard let result else {
        Log.line("   (no answer to the prompt)")
        return false
    }
    return result
}

/// Wait the given number of seconds while spinning the run loop. Audio
/// callbacks run on their own threads, but stopping main drops system events.
func waitSpinningRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
}

// MARK: - loopback: checking a virtual device

func runLoopback(seconds: Double, output: URL) throws {
    Log.setDestination(besideOutput: output)
    guard let device = try AudioDevice.tapdeck() else {
        Log.line("No Tapdeck virtual device. Is the driver installed?")
        Log.line("  sudo cp -R build/Tapdeck.driver /Library/Audio/Plug-Ins/HAL/")
        Log.line("  sudo killall coreaudiod")
        exit(1)
    }
    Log.line("Device : \(device.name) (\(device.uid))")
    Log.line("         in \(device.inputChannels)ch / out \(device.outputChannels)ch / \(Int(device.sampleRate)) Hz")

    // Reading an input device needs microphone permission, and TCC cannot show
    // a prompt for a bare command line tool, so check the state first.
    let auth = AVCaptureDevice.authorizationStatus(for: .audio)
    if auth != .authorized {
        Log.line("Microphone : not granted (status \(auth.rawValue)) — requesting …")
        let granted = requestMicrophoneAccessSync(timeout: 60)
        guard granted else {
            Log.line("FAILED: microphone access denied; input devices cannot be read.")
            exit(1)
        }
        Log.line("Microphone : granted")
    }

    // -- Input side: read back from the virtual device --
    let input = try DeviceInput(device: device)
    var file: AVAudioFile?
    var peak: Float = 0
    var sumSquares: Double = 0
    var total = 0
    var writeError: String?
    let lock = NSLock()

    try input.start { buffer, _ in
        lock.lock(); defer { lock.unlock() }
        if file == nil {
            do {
                file = try AVAudioFile(forWriting: output,
                                       settings: buffer.format.settings,
                                       commonFormat: buffer.format.commonFormat,
                                       interleaved: buffer.format.isInterleaved)
            } catch { if writeError == nil { writeError = "\(error)" } }
        }
        do { try file?.write(from: buffer) }
        catch { if writeError == nil { writeError = "\(error)" } }

        let m = peakAndRMS(buffer)
        if m.peak > peak { peak = m.peak }
        sumSquares += m.sumSquares
        total += m.count
    }
    Log.line("Input  : \(Int(input.format.sampleRate)) Hz / \(input.format.channelCount) ch")

    // -- Output side: send 440 Hz into the virtual device --
    let out = try DeviceOutput(device: device)
    let rate = out.sampleRate
    var phase = 0.0
    let increment = 2.0 * Double.pi * 440.0 / rate

    try out.start { channels, frameCount in
        for frame in 0..<frameCount {
            let value = Float(sin(phase) * 0.25)
            phase += increment
            if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
            for channel in channels { channel[frame] = value }
        }
    }
    Log.line("Output : \(Int(rate)) Hz / \(out.channelCount) ch — sending 440 Hz")
    Log.line("Length : \(seconds)s …")

    waitSpinningRunLoop(seconds)
    out.stop()
    input.stop()

    lock.lock()
    file = nil
    let finalPeak = peak, finalSum = sumSquares, n = total, err = writeError
    lock.unlock()

    Log.line("\n-- Result --")
    if let err { print("!  Write error: \(err)") }
    Log.line("Samples captured    : \(n)")
    guard n > 0 else {
        Log.line("!  Nothing reached the input side.")
        exit(2)
    }
    let rms = (finalSum / Double(n)).squareRoot()
    Log.line("Peak                : \(db(Double(finalPeak)))")
    Log.line("RMS                 : \(db(rms))")
    if finalPeak < 1e-5 {
        Log.line("FAILED: silence. The loopback is not connected.")
        exit(2)
    }
    Log.line("OK: the audio sent to the output was read back from the input.")
}


// MARK: - mix: checking the mixer

func runMix(seconds: Double, deviceName: String, placements: [String]) throws {
    // Several outputs may be given, comma separated. The first is the primary.
    let all = try AudioDevice.all()
    let mixer = Mixer()
    for name in deviceName.split(separator: ",").map(String.init) {
        guard let device = all.first(where: { $0.name == name && $0.canOutput }) else {
            print("No output device named \(name)."); exit(1)
        }
        mixer.addOutput(uid: device.uid, name: device.name)
    }
    var entries: [(Mixer.Source, String)] = []
    for placement in placements {
        // "<pid or name>@<first channel>", e.g. "1234@3" puts it on channels 3-4.
        let parts = placement.split(separator: "@", maxSplits: 1).map(String.init)
        let needle = parts[0]
        let firstChannel = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
        let process = try pid_t(needle).flatMap { try AudioProcess.find(pid: $0) }
            ?? AudioProcess.find(matching: needle)
        guard let process else { print("No process matches \"\(needle)\"."); exit(1) }

        let entry = mixer.add(.application(bundleID: process.bundleID, name: process.name,
                                           pid: process.pid))
        entry.channelOffset = max(0, firstChannel - 1)
        entries.append((entry, "\(process.name) (pid \(process.pid))"))
    }

    if let value = ProcessInfo.processInfo.environment["TAPDECK_MASTER"].flatMap(Float.init) {
        MasterVolume.shared.volume = value
        print("Master : \(value)")
    }
    if ProcessInfo.processInfo.environment["TAPDECK_REPLACE"] == "1" {
        for source in mixer.sources { source.replacesOriginal = true }
        print("Replace: original sound silenced while mixing")
    }
    // "Monitor=300,Tapdeck=0" sets output delays in milliseconds.
    if let spec = ProcessInfo.processInfo.environment["TAPDECK_OUTPUT_DELAYS"] {
        for pair in spec.split(separator: ",") {
            let parts = pair.split(separator: "=").map(String.init)
            guard parts.count == 2, let ms = Double(parts[1]),
                  let output = mixer.outputs.first(where: { $0.deviceName == parts[0] }) else { continue }
            output.delayMilliseconds = ms
            print("Delay  : \(parts[0]) \(ms) ms")
        }
    }
    if ProcessInfo.processInfo.environment["TAPDECK_LOUDNESS"] == "1" {
        mixer.normalizesLoudness = true
        print("Loudness: evened out to \(LoudnessTuning.shared.values.target) LUFS")
    }
    if let value = ProcessInfo.processInfo.environment["TAPDECK_MIX_VOLUME"].flatMap(Float.init) {
        mixer.volume = value
        print("Volume : \(value)")
    }
    try mixer.start()
    for output in mixer.outputs {
        print("Output : \(output.deviceName) — \(output.channelCount)ch at \(Int(output.sampleRate)) Hz"
              + (output.isPrimary ? "  (primary)" : "")
              + (output.detachReason.map { "  [\($0)]" } ?? ""))
    }
    for (entry, label) in entries {
        print("  \(label) -> channels \(entry.channelOffset + 1)-\(entry.channelOffset + 2)"
              + "  [\(entry.formatDescription)]")
    }

    Thread.sleep(forTimeInterval: 1)
    if let output = mixer.output {
        print("AUHAL  : \(output.describeFormats())")
        print("Render : \(output.observedLayout)")
    }
    let steps = max(1, Int(seconds) - 1)
    for second in 1...steps {
        Thread.sleep(forTimeInterval: 1)
        // Rate diagnostics: what the tap assumes, what arrives, and the clock.
        let clock = (try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice,
                                                     as: AudioDeviceID.self))
        let clockRate = clock.flatMap { try? AudioObjectID($0).read(kAudioDevicePropertyNominalSampleRate,
                                                                     as: Float64.self) } ?? 0
        for (entry, label) in entries {
            guard let tap = entry.tapForDiagnostics else { continue }
            print(String(format: "  %2ds %@: tap %.0f Hz, measured %.0f Hz, clock %.0f Hz, changes tap %d / source %d",
                         second + 1, label, tap.format?.sampleRate ?? 0, tap.measuredSampleRate, clockRate,
                         tap.sampleRateChanges, entry.sampleRateChanges))
        }
    }
    mixer.stop()
    print("Stopped.")
}

/// Record every input channel of one or more devices, reading them through our
/// own AUHAL path. ffmpeg's avfoundation capture is not trustworthy for this: it
/// drops blocks, and its multichannel handling cannot be relied on either.
///
/// Several devices are captured by one process, and the host time of each
/// file's first frame is printed, so recordings can be lined up in time.
func runCapture(deviceNames: [String], seconds: Double, output: URL) throws {
    final class Recording {
        let name: String
        let input: DeviceInput
        let url: URL
        let lock = NSLock()
        var file: AVAudioFile?
        var frames = 0
        var firstHostTime: UInt64 = 0
        init(name: String, input: DeviceInput, url: URL) { self.name = name; self.input = input; self.url = url }
    }

    let all = try AudioDevice.all()
    var recordings: [Recording] = []
    for name in deviceNames {
        guard let device = all.first(where: { $0.name == name }) else {
            print("No device named \(name)."); exit(1)
        }
        // One device keeps the given name; several get "<name>-<device>.wav".
        let url = deviceNames.count == 1
            ? output
            : output.deletingLastPathComponent().appendingPathComponent(
                "\(output.deletingPathExtension().lastPathComponent)-\(name).wav")
        recordings.append(Recording(name: name, input: try DeviceInput(device: device), url: url))
    }

    for recording in recordings {
        try recording.input.start { buffer, timeStamp in
            recording.lock.lock(); defer { recording.lock.unlock() }
            if recording.file == nil {
                recording.firstHostTime = timeStamp.mHostTime
                recording.file = try? AVAudioFile(forWriting: recording.url,
                                                  settings: buffer.format.settings,
                                                  commonFormat: buffer.format.commonFormat,
                                                  interleaved: buffer.format.isInterleaved)
            }
            try? recording.file?.write(from: buffer)
            recording.frames += Int(buffer.frameLength)
        }
    }
    Thread.sleep(forTimeInterval: seconds)

    var timebase = mach_timebase_info()
    mach_timebase_info(&timebase)
    for recording in recordings {
        recording.input.stop()
        recording.lock.lock()
        recording.file = nil
        let seconds = Double(recording.firstHostTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        print("Captured \(recording.name): \(recording.frames) frames, "
              + "\(Int(recording.input.format.sampleRate)) Hz, first frame at host \(String(format: "%.6f", seconds)) s "
              + "-> \(recording.url.lastPathComponent)")
        recording.lock.unlock()
    }
}


/// Play a tone on exactly one channel of a device, with nothing else involved.
/// Used to tell apart problems in the mixer, the driver and the capture path.
func runTone(deviceName: String, channel: Int, frequency: Double, seconds: Double) throws {
    guard let device = try AudioDevice.all().first(where: { $0.name == deviceName }) else {
        print("No device named \(deviceName)."); exit(1)
    }
    let output = try DeviceOutput(device: device)
    let index = channel - 1
    var phase = 0.0
    let step = 2 * Double.pi * frequency / output.sampleRate
    try output.start { channels, frameCount in
        guard index >= 0, index < channels.count else { return }
        let target = channels[index]
        for frame in 0..<frameCount {
            target[frame] = Float(sin(phase) * 0.25)
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
    }
    print("Tone   : \(Int(frequency)) Hz on channel \(channel) of \(device.name) "
          + "(\(output.channelCount)ch)")
    Thread.sleep(forTimeInterval: 1)
    print("AUHAL  : \(output.describeFormats())")
    print("Render : \(output.observedLayout)")
    Thread.sleep(forTimeInterval: max(0, seconds - 1))
    output.stop()
}


/// Exercise MuxedRecorder offline: synthetic video frames plus a four-channel
/// test signal with 440 Hz on channels 1-2 and 3000 Hz on 3-4. No devices and no
/// screen recording permission are involved, so the splitting into tracks can
/// be checked on its own.
func runMuxTest(output: URL) throws {
    try? FileManager.default.removeItem(at: output)
    let sampleRate = 48000.0
    guard let audioFormat = AVAudioFormat.discrete(sampleRate: sampleRate, channels: 4) else {
        throw CoreAudioError.missing("a four-channel format")
    }
    let recorder = try MuxedRecorder(outputURL: output,
                                     videoSize: CGSize(width: 320, height: 240),
                                     audioFormat: audioFormat)
    recorder.start()
    print("Tracks : \(recorder.audioTrackCount) audio")

    var timebase = mach_timebase_info()
    mach_timebase_info(&timebase)
    func hostTicks(_ seconds: Double) -> UInt64 {
        UInt64(seconds * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }
    let origin = mach_absolute_time()

    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    guard let pixelBuffer else { throw CoreAudioError.missing("a pixel buffer") }
    var videoFormat: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                 formatDescriptionOut: &videoFormat)
    guard let videoFormat else { throw CoreAudioError.missing("a video format") }

    let blockFrames = 480
    let duration = 3.0
    var phaseLow = 0.0, phaseHigh = 0.0
    var nextVideo = 0.0
    var elapsed = 0.0

    while elapsed < duration {
        // Video at 30 fps, stamped on the host clock like ScreenCaptureKit does.
        if elapsed >= nextVideo {
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(origin + hostTicks(nextVideo)),
                decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer,
                                                     formatDescription: videoFormat,
                                                     sampleTiming: &timing,
                                                     sampleBufferOut: &sample)
            if let sample { recorder.appendVideo(sample) }
            nextVideo += 1.0 / 30
        }

        guard let block = AVAudioPCMBuffer(pcmFormat: audioFormat,
                                           frameCapacity: AVAudioFrameCount(blockFrames)),
              let data = block.floatChannelData else { break }
        block.frameLength = AVAudioFrameCount(blockFrames)
        for frame in 0..<blockFrames {
            let low = Float(sin(phaseLow) * 0.25), high = Float(sin(phaseHigh) * 0.25)
            data[0][frame] = low;  data[1][frame] = low
            data[2][frame] = high; data[3][frame] = high
            phaseLow  += 2 * .pi * 440  / sampleRate
            phaseHigh += 2 * .pi * 3000 / sampleRate
        }
        var stamp = AudioTimeStamp()
        stamp.mHostTime = origin + hostTicks(elapsed)
        stamp.mFlags = .hostTimeValid
        recorder.appendAudio(block, at: stamp)

        elapsed += Double(blockFrames) / sampleRate
        Thread.sleep(forTimeInterval: Double(blockFrames) / sampleRate)
    }

    let done = DispatchSemaphore(value: 0)
    Task { await recorder.finish(); done.signal() }
    done.wait()
    if let failure = recorder.failure { print("Failed: \(failure)"); exit(1) }
    print("Wrote \(output.path)")
}


/// Set a device's nominal sample rate. Used to give a virtual device a rate that
/// differs from the rest of the chain, so sample rate conversion can be tested.
func runRate(deviceName: String, rate: Double) throws {
    guard let device = try AudioDevice.all().first(where: { $0.name == deviceName }) else {
        print("No device named \(deviceName)."); exit(1)
    }
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value = rate
    try ca("setting the sample rate") {
        AudioObjectSetPropertyData(device.deviceID, &address, 0, nil,
                                   UInt32(MemoryLayout<Float64>.size), &value)
    }
    Thread.sleep(forTimeInterval: 0.5)
    let now = try AudioDevice.find(uid: device.uid)
    print("\(device.name): \(Int(now?.sampleRate ?? 0)) Hz")
}


/// Finding a saved device again, including under a new UID.
func runDeviceMatchTest() {
    var passed = 0, total = 0
    func report(_ label: String, _ ok: Bool) {
        total += 1; if ok { passed += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(label)")
    }
    func device(_ uid: String, _ name: String, _ transport: AudioDevice.Transport = .other) -> AudioDevice {
        AudioDevice(deviceID: 1, uid: uid, name: name, inputChannels: 0, outputChannels: 2, sampleRate: 44_100,
                    transport: transport)
    }
    let savedAirPlay = "d1c3a716-81a7-4657-bfaa-b6c7ff1538b3-50150987687166-Audio"
    let currentAirPlay = "d1c3a716-81a7-4657-bfaa-b6c7ff1538b3-89446392180958-Audio"
    let speakers = device("BuiltInSpeakerDevice", "MacBook Pro Speakers", .builtIn)
    let airPlay = device(currentAirPlay, "AirPlay", .airPlay)

    report("exact UID still wins", AudioDevice.find(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                                                   in: [speakers, airPlay])?.uid == "BuiltInSpeakerDevice")
    report("AirPlay found under its new UID",
           AudioDevice.find(uid: savedAirPlay, name: "AirPlay", in: [speakers, airPlay])?.uid == currentAirPlay)
    report("not matched when the name differs",
           AudioDevice.find(uid: savedAirPlay, name: "Kitchen", in: [speakers, airPlay]) == nil)
    report("not matched when two candidates look alike",
           AudioDevice.find(uid: savedAirPlay, name: "AirPlay",
                            in: [airPlay, device("d1c3a716-81a7-4657-bfaa-b6c7ff1538b3-11111111111-Audio", "AirPlay")]) == nil)
    report("a UID without long numbers has no fallback",
           AudioDevice.find(uid: "BuiltInHeadphones", name: "MacBook Pro Speakers", in: [speakers]) == nil)
    report("short numbers are part of the identity",
           AudioDevice.stableSignature(of: "AppleUSBAudioEngine:Vendor:Box:1234-2") == "AppleUSBAudioEngine:Vendor:Box:1234-2")
    report("GUID segments are kept", AudioDevice.stableSignature(of: savedAirPlay)
           == "d1c3a716-81a7-4657-bfaa-b6c7ff1538b3-Audio")
    report("typical latencies", AudioDevice.Transport.airPlay.typicalLatencyMilliseconds == 2_000
           && AudioDevice.Transport.bluetooth.typicalLatencyMilliseconds == 150
           && AudioDevice.Transport.builtIn.typicalLatencyMilliseconds == 0)
    print("\(passed)/\(total) passed")
    if passed != total { exit(1) }
}

/// Check RoutingGraph against cases whose answer is known.
func runGraphTest() {
    func check(_ label: String, _ build: (inout RoutingGraph) -> Void, expectLoop: Bool) -> Bool {
        var graph = RoutingGraph()
        build(&graph)
        let loop = graph.firstCycle()
        let ok = (loop != nil) == expectLoop
        print("\(ok ? "PASS" : "FAIL")  \(label)  ->  \(loop?.joined(separator: " → ") ?? "no loop")")
        return ok
    }
    var results: [Bool] = []
    results.append(check("mic -> Tapdeck", { $0.connect(from: ["mic"], to: ["Tapdeck"]) }, expectLoop: false))
    results.append(check("Tapdeck -> Tapdeck (same mix)", { $0.connect(from: ["Tapdeck"], to: ["Tapdeck", "speakers"]) }, expectLoop: true))
    results.append(check("Tapdeck -> speakers (listen)", { $0.connect(from: ["Tapdeck"], to: ["speakers"]) }, expectLoop: false))
    results.append(check("A -> B, B -> A (two mixes)", {
        $0.connect(from: ["Streaming"], to: ["Meetings"])
        $0.connect(from: ["Meetings"], to: ["Streaming"])
    }, expectLoop: true))
    results.append(check("A -> B -> C (chain)", {
        $0.connect(from: ["A"], to: ["B"])
        $0.connect(from: ["B"], to: ["C"])
    }, expectLoop: false))
    results.append(check("A -> B -> C -> A (three mixes)", {
        $0.connect(from: ["A"], to: ["B"])
        $0.connect(from: ["B"], to: ["C"])
        $0.connect(from: ["C"], to: ["A"])
    }, expectLoop: true))
    results.append(check("app sources only (no device edges)", { $0.connect(from: [], to: ["Tapdeck"]) }, expectLoop: false))
    let passed = results.filter { $0 }.count
    print("\(passed)/\(results.count) passed")
    if passed != results.count { exit(1) }
}


/// Check the gain stages without any devices.
func runGainTest() {
    var passed = 0, total = 0
    func report(_ label: String, _ ok: Bool, _ detail: String) {
        total += 1; if ok { passed += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(label.padding(toLength: 46, withPad: " ", startingAt: 0)) \(detail)")
    }

    let frames = 512
    let rate = 48_000.0

    // A 1 kHz sine whose gain changes from 1 to 0.5 at a block boundary.
    func largestStep(ramped: Bool) -> Float {
        var samples = (0..<frames * 2).map { Float(sin(2 * .pi * 1000 * Double($0) / rate)) }
        return samples.withUnsafeMutableBufferPointer { buffer -> Float in
            let first = buffer.baseAddress!, second = buffer.baseAddress! + frames
            var ramp = GainRamp(1)
            if ramped {
                ramp.apply(to: [first], frameCount: frames, target: 1)
                ramp.apply(to: [second], frameCount: frames, target: 0.5)
            } else {
                for i in 0..<frames { second[i] *= 0.5 }
            }
            // A pure 1 kHz sine at 48 kHz never moves more than
            // 2·sin(π·1000/48000) ≈ 0.131 between samples. Anything larger is
            // a discontinuity introduced by the gain change.
            var largest: Float = 0
            for i in 1..<(frames * 2) {
                largest = max(largest, abs(buffer[i] - buffer[i - 1]))
            }
            return largest
        }
    }
    let hard = largestStep(ramped: false), smooth = largestStep(ramped: true)
    let sineSlope = Float(2 * sin(Double.pi * 1000 / rate))
    report("hard gain change leaves a step", hard > sineSlope * 1.2,
           String(format: "largest step %.3f (sine alone %.3f)", hard, sineSlope))
    report("ramped gain change stays within the sine", smooth <= sineSlope * 1.01,
           String(format: "largest step %.3f", smooth))

    var dc = [Float](repeating: 1, count: frames)
    dc.withUnsafeMutableBufferPointer { buffer in
        var ramp = GainRamp(1)
        ramp.apply(to: [buffer.baseAddress!], frameCount: frames, target: 0)
        let monotonic = (1..<frames).allSatisfy { buffer[$0] <= buffer[$0 - 1] }
        report("ramp to silence ends at zero and never rises",
               monotonic && abs(buffer[frames - 1]) < 1e-6,
               String(format: "first %.4f last %.6f", buffer[0], buffer[frames - 1]))
    }

    let master = MasterVolume()
    master.volume = 0.5
    report("master volume gain", master.gain == 0.5, "0.5 -> \(master.gain)")
    master.isMuted = true
    report("master mute", master.gain == 0, "muted -> \(master.gain)")
    master.isMuted = false
    master.volume = -3
    report("master volume never negative", master.gain == 0, "-3 -> \(master.gain)")

    print("\(passed)/\(total) passed")
    if passed != total { exit(1) }
}


/// Check the delay line without any devices.
func runDelayTest() {
    var passed = 0, total = 0
    func report(_ label: String, _ ok: Bool, _ detail: String) {
        total += 1; if ok { passed += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(label.padding(toLength: 48, withPad: " ", startingAt: 0)) \(detail)")
    }
    let rate = 48_000.0
    let block = 512

    /// Feed `input` through the line in blocks and return the output.
    func run(_ input: [Float], delays: (Int) -> Int, maximum: Int = 48_000) -> [Float] {
        let line = DelayLine(channels: 1, maximumFrames: maximum)
        var output = input
        output.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            var blockIndex = 0
            while offset < buffer.count {
                let count = min(block, buffer.count - offset)
                line.process([buffer.baseAddress! + offset], frameCount: count,
                             targetDelay: delays(blockIndex))
                offset += count
                blockIndex += 1
            }
        }
        return output
    }

    // An impulse after a delay set before any audio arrives lands exactly.
    for delay in [0, 1, 480, 12_000, 47_999] {
        var input = [Float](repeating: 0, count: 60_000)
        input[100] = 1
        // Hold the delay from the start by fading in over silence first.
        let line = DelayLine(channels: 1, maximumFrames: 48_000, fadeFrames: 1)
        var output = input
        output.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = min(block, buffer.count - offset)
                line.process([buffer.baseAddress! + offset], frameCount: count, targetDelay: delay)
                offset += count
            }
        }
        let position = output.firstIndex { abs($0) > 0.5 } ?? -1
        report("impulse delayed by \(delay) frames", position == 100 + delay,
               "arrived at \(position), expected \(100 + delay)")
    }

    // Changing the delay mid-stream must not leave a discontinuity.
    let sine = (0..<96_000).map { Float(sin(2 * .pi * 440 * Double($0) / rate)) }
    let changed = run(sine, delays: { $0 < 40 ? 0 : 9_600 })
    let slope = Float(2 * sin(Double.pi * 440 / rate))
    var largest: Float = 0
    for i in 1..<changed.count { largest = max(largest, abs(changed[i] - changed[i - 1])) }
    report("delay change is crossfaded, not stepped", largest <= slope * 1.05,
           String(format: "largest step %.4f (sine alone %.4f)", largest, slope))

    // After the fade, the output is the input exactly 200 ms later. Compare a
    // whole window: a single sample can land on a zero crossing and pass
    // whatever the delay.
    var worst: Float = 0
    var energy: Float = 0
    for i in 80_000..<81_000 {
        worst = max(worst, abs(changed[i] - sine[i - 9_600]))
        energy += changed[i] * changed[i]
    }
    report("after the change the output is 200 ms behind", worst < 1e-5 && energy > 100,
           String(format: "largest error %.2e over 1000 samples (energy %.0f)", worst, energy))
    var wrong: Float = 0
    for i in 80_000..<81_000 { wrong = max(wrong, abs(changed[i] - sine[i - 9_601])) }
    report("and not 199.98 ms (the comparison can fail)", wrong > 1e-3,
           String(format: "error against one frame off %.2e", wrong))

    // Requests beyond the capacity are clamped, not wrapped around.
    let clamped = DelayLine(channels: 1, maximumFrames: 1000)
    var probe: [Float] = [0]
    probe.withUnsafeMutableBufferPointer { clamped.process([$0.baseAddress!], frameCount: 1, targetDelay: 5000) }
    report("delay beyond capacity is clamped", clamped.currentDelay == 1000, "got \(clamped.currentDelay)")

    print("\(passed)/\(total) passed")
    if passed != total { exit(1) }
}

/// Measure each effect against signals whose correct result is known.
func runEffectsTest() {
    let rate = 48_000.0
    let format = AVAudioFormat.discrete(sampleRate: rate, channels: 2)!
    var passed = 0, total = 0

    func report(_ label: String, _ ok: Bool, _ detail: String) {
        total += 1; if ok { passed += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(label.padding(toLength: 44, withPad: " ", startingAt: 0)) \(detail)")
    }

    /// Run a sine of the given level through a chain for `seconds`, and return
    /// the steady-state peak (dBFS) of each output channel over the last 200 ms.
    func sineThrough(_ settings: EffectSettings, frequency: Double, level: Double,
                     seconds: Double = 1.0, rightLevel: Double? = nil) -> (Double, Double) {
        let chain = EffectChain()
        chain.update(settings)
        let block = 512
        let totalFrames = Int(seconds * rate)
        let amplitudeL = pow(10, level / 20), amplitudeR = pow(10, (rightLevel ?? level) / 20)
        var phase = 0.0
        var peakL: Float = 0, peakR: Float = 0
        var done = 0
        while done < totalFrames {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
            buffer.frameLength = AVAudioFrameCount(block)
            let d = buffer.floatChannelData!
            for i in 0..<block {
                d[0][i] = Float(sin(phase) * amplitudeL)
                d[1][i] = Float(sin(phase) * amplitudeR)
                phase += 2 * .pi * frequency / rate
            }
            chain.process(buffer)
            if done >= totalFrames - Int(0.2 * rate) {
                for i in 0..<block { peakL = max(peakL, abs(d[0][i])); peakR = max(peakR, abs(d[1][i])) }
            }
            done += block
        }
        func db(_ x: Float) -> Double { x > 0 ? 20 * log10(Double(x)) : -999 }
        return (db(peakL), db(peakR))
    }

    // Low cut at 100 Hz, 24 dB/octave.
    var lowCut = EffectSettings(); lowCut.lowCutEnabled = true; lowCut.lowCutFrequency = 100
    let lc25 = sineThrough(lowCut, frequency: 25, level: -6).0
    let lc100 = sineThrough(lowCut, frequency: 100, level: -6).0
    let lc1k = sineThrough(lowCut, frequency: 1_000, level: -6).0
    report("low cut 100Hz: 25 Hz (two octaves below)", lc25 < -6 - 40, String(format: "%.1f dB (expect about -54)", lc25))
    report("low cut 100Hz: 100 Hz (corner, -3 dB)", abs(lc100 - (-9)) < 1, String(format: "%.1f dB (expect -9.0)", lc100))
    report("low cut 100Hz: 1 kHz passes", abs(lc1k - (-6)) < 0.2, String(format: "%.1f dB (expect -6.0)", lc1k))

    // High cut at 1 kHz, 24 dB/octave, mirrored.
    var highCut = EffectSettings(); highCut.highCutEnabled = true; highCut.highCutFrequency = 1_000
    let hc4k = sineThrough(highCut, frequency: 4_000, level: -6).0
    let hc1k = sineThrough(highCut, frequency: 1_000, level: -6).0
    let hc100 = sineThrough(highCut, frequency: 100, level: -6).0
    report("high cut 1kHz: 4 kHz (two octaves above)", hc4k < -6 - 40, String(format: "%.1f dB (expect about -54)", hc4k))
    report("high cut 1kHz: 1 kHz (corner, -3 dB)", abs(hc1k - (-9)) < 1, String(format: "%.1f dB (expect -9.0)", hc1k))
    report("high cut 1kHz: 100 Hz passes", abs(hc100 - (-6)) < 0.2, String(format: "%.1f dB (expect -6.0)", hc100))

    // EQ: +6 dB peak at 1 kHz.
    var peak = EffectSettings(); peak.eqEnabled = true; peak.bands[2].gain = 6
    let p1k = sineThrough(peak, frequency: 1_000, level: -12).0
    let p100 = sineThrough(peak, frequency: 100, level: -12).0
    report("EQ +6dB at 1kHz: 1 kHz", abs(p1k - (-6)) < 0.3, String(format: "%.1f dB (expect -6.0)", p1k))
    report("EQ +6dB at 1kHz: 100 Hz untouched", abs(p100 - (-12)) < 0.5, String(format: "%.1f dB (expect -12.0)", p100))

    var shelf = EffectSettings(); shelf.eqEnabled = true; shelf.bands[0].gain = -8
    let s30 = sineThrough(shelf, frequency: 30, level: -12).0
    let s5k = sineThrough(shelf, frequency: 5_000, level: -12).0
    report("low shelf -8dB: 30 Hz", abs(s30 - (-20)) < 0.7, String(format: "%.1f dB (expect about -20)", s30))
    report("low shelf -8dB: 5 kHz untouched", abs(s5k - (-12)) < 0.3, String(format: "%.1f dB (expect -12.0)", s5k))

    // Gate at -40 dBFS.
    var gate = EffectSettings(); gate.gateEnabled = true; gate.gateThreshold = -40
    let quiet = sineThrough(gate, frequency: 440, level: -55).0
    let loud = sineThrough(gate, frequency: 440, level: -20).0
    report("gate -40: signal at -55 is silenced", quiet < -100, String(format: "%.1f dB", quiet))
    report("gate -40: signal at -20 passes", abs(loud - (-20)) < 0.2, String(format: "%.1f dB (expect -20.0)", loud))

    // Compressor: threshold -20, ratio 4, no makeup. Well above the knee a
    // -4 dBFS input is 16 dB over, so 12 dB is removed: -16 dBFS out.
    var comp = EffectSettings(); comp.compressorEnabled = true
    comp.compressorThreshold = -20; comp.compressorRatio = 4; comp.compressorMakeup = 0
    let c4 = sineThrough(comp, frequency: 440, level: -4).0
    let c40 = sineThrough(comp, frequency: 440, level: -40).0
    report("compressor 4:1 at -20: input -4 dBFS", abs(c4 - (-16)) < 0.8, String(format: "%.1f dB (expect -16.0)", c4))
    report("compressor 4:1 at -20: quiet input untouched", abs(c40 - (-40)) < 0.2, String(format: "%.1f dB (expect -40.0)", c40))

    // Limiter: ceiling -3 dBFS, input at 0 dBFS.
    var lim = EffectSettings(); lim.limiterEnabled = true; lim.limiterCeiling = -3
    let l0 = sineThrough(lim, frequency: 440, level: 0).0
    let l12 = sineThrough(lim, frequency: 440, level: -12).0
    report("limiter -3: input 0 dBFS never exceeds -3", l0 <= -3 + 0.01, String(format: "%.2f dB", l0))
    report("limiter -3: input -12 untouched", abs(l12 - (-12)) < 0.1, String(format: "%.1f dB (expect -12.0)", l12))

    // Balance fully left, and mono.
    var bal = EffectSettings(); bal.balance = -1
    let b = sineThrough(bal, frequency: 440, level: -6)
    report("balance fully left: right is silent", b.1 < -100 && abs(b.0 - (-6)) < 0.1, String(format: "L %.1f / R %.1f", b.0, b.1))
    var mono = EffectSettings(); mono.mono = true
    let m = sineThrough(mono, frequency: 440, level: -6, rightLevel: -100)
    report("mono: left-only input lands on both", abs(m.0 - m.1) < 0.01 && abs(m.0 - (-12)) < 0.2,
           String(format: "L %.1f / R %.1f (expect -12 each)", m.0, m.1))

    // Delay: an impulse comes out exactly 100 ms later.
    var delaySettings = EffectSettings(); delaySettings.delay = 100
    let chain = EffectChain(); chain.update(delaySettings)
    var impulseAt = -1, cursor = 0
    for blockIndex in 0..<20 {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buffer.frameLength = 512
        let d = buffer.floatChannelData!
        for i in 0..<512 { d[0][i] = 0; d[1][i] = 0 }
        if blockIndex == 0 { d[0][0] = 1; d[1][0] = 1 }
        chain.process(buffer)
        for i in 0..<512 where d[0][i] > 0.5 && impulseAt < 0 { impulseAt = cursor + i }
        cursor += 512
    }
    report("delay 100 ms: impulse position", impulseAt == 4_800, "sample \(impulseAt) (expect 4800)")

    // Everything off must leave the signal bit-identical.
    let off = sineThrough(EffectSettings(), frequency: 440, level: -9).0
    report("all effects off: untouched", abs(off - (-9)) < 0.01, String(format: "%.2f dB (expect -9.00)", off))

    print("\(passed)/\(total) passed")
    if passed != total { exit(1) }
}

func runLoudnessTest() {
    var passed = 0, total = 0

    func report(_ label: String, _ ok: Bool, _ detail: String) {
        total += 1; if ok { passed += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(label.padding(toLength: 50, withPad: " ", startingAt: 0)) \(detail)")
    }

    /// Momentary loudness of a steady signal, after `seconds` of it.
    func meterReading(rate: Double, seconds: Double, fill: (Int, Int) -> Float, channels: Int) -> Double {
        var meter = LoudnessMeter()
        meter.configure(sampleRate: rate)
        let storage = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 512) }
        defer { storage.forEach { $0.deallocate() } }
        var last = 0.0, cursor = 0
        while cursor < Int(seconds * rate) {
            for channel in 0..<channels { for i in 0..<512 { storage[channel][i] = fill(channel, cursor + i) } }
            var offset = 0
            while offset < 512 {
                let chunk = min(512 - offset, meter.framesUntilBlockEnds)
                if let value = meter.measure(storage, offset: offset, frameCount: chunk) { last = value.momentary }
                offset += chunk
            }
            cursor += 512
        }
        return LoudnessMeter.loudness(meanSquare: last)
    }

    // The standard's calibration: a 0 dBFS 997 Hz sine in one channel of a
    // stereo pair reads -3.01 LUFS, and in both reads 0.
    for rate in [48_000.0, 44_100.0] {
        let sine: (Int, Int) -> Float = { _, i in Float(sin(2 * .pi * 997 * Double(i) / rate)) }
        let left = meterReading(rate: rate, seconds: 2, fill: { c, i in c == 0 ? sine(c, i) : 0 }, channels: 2)
        let both = meterReading(rate: rate, seconds: 2, fill: sine, channels: 2)
        report("meter \(Int(rate)) Hz: 997 Hz 0 dBFS in one channel", abs(left - (-3.01)) < 0.05,
               String(format: "%.2f LUFS (expect -3.01)", left))
        report("meter \(Int(rate)) Hz: same in both channels", abs(both) < 0.05,
               String(format: "%.2f LUFS (expect 0.00)", both))
    }
    // K-weighting's high-pass: deep bass counts for much less.
    let bass = meterReading(rate: 48_000, seconds: 2, fill: { _, i in Float(sin(2 * .pi * 20 * Double(i) / 48_000)) },
                            channels: 2)
    report("meter: 20 Hz counts for much less than 1 kHz", bass < -10, String(format: "%.2f LUFS", bass))

    // Noise, scaled to a given loudness. Uniform white noise from a fixed seed.
    let rate = 48_000.0
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func noise() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: seed >> 11) - (1 << 52)) / Float(1 << 52)
    }
    let unitLoudness = meterReading(rate: rate, seconds: 3, fill: { _, _ in noise() }, channels: 2)

    struct Segment { var lufs: Double; var seconds: Double }
    struct Result { var outputLoudness: Double; var peak: Double; var reading: LoudnessReading; var peakAfter: [Double] }

    /// Play noise segments through `process`, reporting per segment the output
    /// loudness over its last second, its peak, and the reading at its end.
    func play(_ segments: [Segment], process: ([UnsafeMutablePointer<Float>], Int) -> LoudnessReading) -> [Result] {
        let block = 512
        let storage = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        defer { storage.forEach { $0.deallocate() } }
        var results: [Result] = []
        for segment in segments {
            let scale = Float(pow(10, (segment.lufs - unitLoudness) / 20))
            let frames = Int(segment.seconds * rate)
            var energy = 0.0, counted = 0, peak: Float = 0
            var reading = LoudnessReading(loudness: nil, gain: 0)
            var peakAfter: [Double] = []
            var cursor = 0
            var meter = LoudnessMeter()
            meter.configure(sampleRate: rate)
            while cursor < frames {
                for channel in 0..<2 { for i in 0..<block { storage[channel][i] = noise() * scale } }
                reading = process(storage, block)
                for i in 0..<block { peak = max(peak, abs(storage[0][i]), abs(storage[1][i])) }
                if cursor >= frames - Int(rate) {
                    var offset = 0
                    while offset < block {
                        let chunk = min(block - offset, meter.framesUntilBlockEnds)
                        _ = meter.measure(storage, offset: offset, frameCount: chunk)
                        offset += chunk
                    }
                    for channel in 0..<2 { for i in 0..<block { energy += Double(storage[channel][i] * storage[channel][i]) } }
                    counted += block
                }
                cursor += block
                // Momentary gain every 100 ms, for the catch-up check.
                if cursor % 4800 < block { peakAfter.append(reading.gain) }
            }
            // Loudness from the K-weighted meter would need its own accumulator;
            // noise is flat, so plain mean square plus the unit offset is close.
            let meanSquare = energy / Double(max(1, counted))
            let unitMeanSquare = 2.0 / 3.0 // two channels of uniform noise in ±1
            let loudness = unitLoudness + 10 * log10(max(meanSquare, 1e-12) / unitMeanSquare)
            results.append(Result(outputLoudness: loudness, peak: 20 * log10(Double(max(peak, 1e-9))),
                                  reading: reading, peakAfter: peakAfter))
        }
        return results
    }

    func normalizer(_ tuning: LoudnessTuning.Values) -> ([UnsafeMutablePointer<Float>], Int) -> LoudnessReading {
        let n = LoudnessNormalizer()
        return { channels, frames in
            n.process(channels, frameCount: frames, sampleRate: rate, tuning: tuning)
            return n.reading
        }
    }

    var tuning = LoudnessTuning.Values() // -16 LUFS, +12 dB at most, balanced

    // A loud programme is brought down to the target.
    let loud = play([Segment(lufs: -6, seconds: 8)], process: normalizer(tuning))[0]
    report("loud -6 LUFS lands on the -16 target", abs(loud.outputLoudness - (-16)) < 0.5,
           String(format: "%.2f LUFS, gain %+.1f dB", loud.outputLoudness, loud.reading.gain))

    // A quiet one is raised, but no more than the maximum boost.
    let quiet = play([Segment(lufs: -34, seconds: 20)], process: normalizer(tuning))[0]
    report("quiet -34 LUFS raised by the 12 dB maximum", abs(quiet.outputLoudness - (-22)) < 0.5,
           String(format: "%.2f LUFS (expect -22), gain %+.1f dB", quiet.outputLoudness, quiet.reading.gain))
    tuning.maximumBoost = 24
    let quietFull = play([Segment(lufs: -34, seconds: 20)], process: normalizer(tuning))[0]
    report("quiet -34 LUFS with 24 dB allowed reaches -16", abs(quietFull.outputLoudness - (-16)) < 0.5,
           String(format: "%.2f LUFS", quietFull.outputLoudness))
    tuning.maximumBoost = 12

    // Silence does not pull the gain up.
    let silence = play([Segment(lufs: -26, seconds: 8), Segment(lufs: -75, seconds: 10)], process: normalizer(tuning))
    report("silence after -26 LUFS holds the +10 dB gain", abs(silence[1].reading.gain - 10) < 0.5,
           String(format: "%+.2f dB before, %+.2f dB after 10 s of silence",
                  silence[0].reading.gain, silence[1].reading.gain))

    // A short pause is ignored; a lasting drop is followed.
    let pause = play([Segment(lufs: -16, seconds: 8), Segment(lufs: -40, seconds: 1.5)], process: normalizer(tuning))
    report("1.5 s drop of 24 LU is taken for a pause", abs(pause[1].reading.gain - pause[0].reading.gain) < 0.3,
           String(format: "%+.2f dB -> %+.2f dB", pause[0].reading.gain, pause[1].reading.gain))
    let drop = play([Segment(lufs: -16, seconds: 8), Segment(lufs: -32, seconds: 15)], process: normalizer(tuning))
    report("lasting 16 LU drop is followed", drop[1].reading.gain > 12 - 1,
           String(format: "%+.2f dB after 15 s (expect +12, the maximum)", drop[1].reading.gain))

    // A sudden jump: caught within a second, and no peak past the ceiling.
    let jump = play([Segment(lufs: -40, seconds: 10), Segment(lufs: -4, seconds: 3)], process: normalizer(tuning))
    let gainAfterOneSecond = jump[1].peakAfter.count > 10 ? jump[1].peakAfter[10] : 99
    report("jump from -40 to -4 LUFS: gain after 1 s", gainAfterOneSecond < -8,
           String(format: "%+.1f dB (target -12)", gainAfterOneSecond))
    report("jump: no peak above the -1 dBFS ceiling", jump[1].peak <= -1 + 0.01,
           String(format: "peak %.2f dBFS", jump[1].peak))
    let gainAfterAThird = jump[1].peakAfter.count > 3 ? jump[1].peakAfter[3] : 99
    report("jump: most of the way there within 0.4 s", gainAfterAThird < -9,
           String(format: "%+.1f dB (target -12)", gainAfterAThird))

    // The first sound after silence is judged on its own, not averaged with the
    // silence before it.
    let onset = play([Segment(lufs: -75, seconds: 2), Segment(lufs: -6, seconds: 2)], process: normalizer(tuning))
    let onsetGain = onset[1].peakAfter.count > 2 ? onset[1].peakAfter[2] : 99
    report("first sound after silence: gain after 0.3 s", abs(onsetGain - (-10)) < 1,
           String(format: "%+.1f dB (target -10)", onsetGain))

    // Through the effect chain.
    var settings = EffectSettings(); settings.loudnessEnabled = true
    let chain = EffectChain(); chain.update(settings)
    let format = AVAudioFormat.discrete(sampleRate: rate, channels: 2)!
    let chained = play([Segment(lufs: -8, seconds: 8)]) { channels, frames in
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<2 { buffer.floatChannelData![c].update(from: channels[c], count: frames) }
        chain.process(buffer)
        for c in 0..<2 { channels[c].update(from: buffer.floatChannelData![c], count: frames) }
        return chain.loudnessReading
    }[0]
    report("effect chain: -8 LUFS source lands on -16", abs(chained.outputLoudness - (-16)) < 0.5,
           String(format: "%.2f LUFS", chained.outputLoudness))

    // Settings saved before loudness existed still load.
    let old = #"{"lowCutEnabled":true,"lowCutFrequency":120}"#
    let decoded = try? JSONDecoder().decode(EffectSettings.self, from: Data(old.utf8))
    report("older saved effects still decode", decoded?.lowCutFrequency == 120 && decoded?.loudnessEnabled == false,
           decoded.map { "low cut \($0.lowCutFrequency) Hz, loudness \($0.loudnessEnabled)" } ?? "failed to decode")

    print("\(passed)/\(total) passed")
    if passed != total { exit(1) }
}

// MARK: - entry

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

do {
    switch command {
    case "list":
        try runList()

    case "devices":
        let devices = try AudioDevice.all()
        print("   in    out    rate    name                          UID")
        print(String(repeating: "─", count: 92))
        for d in devices {
            let name = d.name.padding(toLength: max(d.name.count, 28), withPad: " ", startingAt: 0)
            print(String(format: "%5d  %5d  %6d Hz  %@  %@",
                         d.inputChannels, d.outputChannels, Int(d.sampleRate), name, d.uid))
        }

    case "rec":
        guard args.count >= 3, let seconds = Double(args[2]) else { usage() }
        let needle = args[1]
        let proc: AudioProcess?
        if let pid = pid_t(needle) {
            proc = try AudioProcess.find(pid: pid)
        } else {
            proc = try AudioProcess.find(matching: needle)
        }
        guard let target = proc else {
            print("No process matches \"\(needle)\". Try: tapproof list")
            exit(1)
        }
        let out = URL(fileURLWithPath: args.count >= 4 ? args[3] : "tapproof-\(target.pid).wav")
        try runRecord(mode: .include([target]),
                      label: "\(target.name) (PID \(target.pid))",
                      seconds: seconds,
                      output: out)

    case "mix":
        guard args.count >= 4, let seconds = Double(args[1]) else { usage() }
        try runMix(seconds: seconds, deviceName: args[2], placements: Array(args.dropFirst(3)))

    case "delaytest":
        runDelayTest()

    case "gaintest":
        runGainTest()

    case "fxtest":
        runEffectsTest()

    case "loudtest":
        runLoudnessTest()

    case "devicetest":
        runDeviceMatchTest()


    case "graphtest":
        runGraphTest()

    case "muxtest":
        try runMuxTest(output: URL(fileURLWithPath: args.count >= 2 ? args[1] : "muxtest.mov"))

    case "rate":
        guard args.count >= 3, let rate = Double(args[2]) else { usage() }
        try runRate(deviceName: args[1], rate: rate)

    case "tone":
        guard args.count >= 5, let channel = Int(args[2]),
              let frequency = Double(args[3]), let seconds = Double(args[4]) else { usage() }
        try runTone(deviceName: args[1], channel: channel, frequency: frequency, seconds: seconds)

    case "capture":
        guard args.count >= 3, let seconds = Double(args[2]) else { usage() }
        let out = URL(fileURLWithPath: args.count >= 4 ? args[3] : "capture.wav")
        try runCapture(deviceNames: args[1].split(separator: ",").map(String.init),
                       seconds: seconds, output: out)

    case "virtual":
        if args.count == 1 {
            let configuration = VirtualDeviceConfiguration.load()
            print("Configured virtual devices:")
            for device in configuration.devices {
                print("  \(device.name)  (\(device.uid), \(device.channelCount)ch)")
            }
            let live = try AudioDevice.all().filter { $0.uid.hasPrefix("TapdeckDevice") }
            print("Virtual devices actually visible:")
            for device in live {
                print("  \(device.name)  (\(device.uid), in \(device.inputChannels)ch / out \(device.outputChannels)ch)")
            }
        } else {
            // Keep each device's UID stable across edits. Apps such as Zoom and
            // OBS remember the chosen device by UID, so renumbering by position
            // would silently move them onto a different device when one in the
            // middle is removed.
            let existing = VirtualDeviceConfiguration.load().devices
            let names = Array(args.dropFirst())
            // "Name" or "Name:channels", e.g. "Podcast:6".
            let devices = names.map { spec -> VirtualDeviceConfiguration.Device in
                let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                let name = parts[0]
                let channels = parts.count > 1 ? (Int(parts[1]) ?? 2) : nil
                if var match = existing.first(where: { $0.name == name }) {
                    if let channels { match.channelCount = channels }
                    return match
                }
                return VirtualDeviceConfiguration.Device(name: name, channelCount: channels ?? 2)
            }
            try VirtualDeviceConfiguration(devices: devices).save()
            print("Sent \(devices.count) device(s).")
            Thread.sleep(forTimeInterval: 1)
            let live = try AudioDevice.all().filter { $0.uid.hasPrefix("TapdeckDevice") }
            print("Virtual devices actually visible:")
            for device in live {
                print("  \(device.name)  (\(device.uid), in \(device.inputChannels)ch / out \(device.outputChannels)ch)")
            }
        }

    case "loopback":
        guard args.count >= 2, let seconds = Double(args[1]) else { usage() }
        let out = URL(fileURLWithPath: args.count >= 3 ? args[2] : "tapproof-loopback.wav")
        try runLoopback(seconds: seconds, output: out)

    case "rec-system":
        guard args.count >= 2, let seconds = Double(args[1]) else { usage() }
        let me = try AudioProcess.find(pid: ProcessInfo.processInfo.processIdentifier)
        let out = URL(fileURLWithPath: args.count >= 3 ? args[2] : "tapproof-system.wav")
        try runRecord(mode: .excluding(me.map { [$0] } ?? []),
                      label: "all system audio",
                      seconds: seconds,
                      output: out)

    default:
        usage()
    }
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
