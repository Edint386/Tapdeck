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

      tapproof virtual [name ...]
          Show the virtual devices, or replace them with the given names

      tapproof mix <pid or app name> <seconds>
          Send that application's audio through the mixer to a Tapdeck device

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
    let rate = out.outputFormat.sampleRate
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
    Log.line("Output : \(Int(rate)) Hz / \(out.outputFormat.channelCount) ch — sending 440 Hz")
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

func runMix(target: String, seconds: Double) throws {
    guard let device = try AudioDevice.tapdeck() else {
        print("No Tapdeck virtual device."); exit(1)
    }
    let process: AudioProcess?
    if let pid = pid_t(target) { process = try AudioProcess.find(pid: pid) }
    else { process = try AudioProcess.find(matching: target) }
    guard let source = process else {
        print("No process matches \"\(target)\"."); exit(1)
    }

    let mixer = Mixer()
    let entry = mixer.add(.application(bundleID: source.bundleID, name: source.name))
    print("Source : \(source.name) (pid \(source.pid))")
    print("Output : \(device.name) — \(Int(device.sampleRate)) Hz")

    try mixer.start(to: device)
    print("Format : \(entry.formatDescription)")
    print("Length : \(seconds)s …")

    // Print source and output peaks once a second to see where audio stops.
    let steps = max(1, Int(seconds))
    for step in 1...steps {
        Thread.sleep(forTimeInterval: 1)
        let sourcePeak = entry.ring.takePeak()
        let masterPeak = mixer.takeMasterPeak()
        print(String(format: "  %2ds  source %@   output %@   under %d  over %d  buffered %d frames",
                     step, db(Double(sourcePeak)), db(Double(masterPeak)),
                     entry.ring.underruns, entry.ring.overruns, entry.ring.fill))
        if let tap = entry.tapForDiagnostics {
            print("        tap time discontinuities: \(tap.discontinuityCount)")
        }

    }

    mixer.stop()
    print("Stopped.")
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
        guard args.count >= 3, let seconds = Double(args[2]) else { usage() }
        try runMix(target: args[1], seconds: seconds)

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
            let devices = names.map { name -> VirtualDeviceConfiguration.Device in
                if let match = existing.first(where: { $0.name == name }) {
                    return match
                }
                return VirtualDeviceConfiguration.Device(name: name)
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
