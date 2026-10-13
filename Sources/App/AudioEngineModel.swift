import AVFoundation
import Combine
import CoreAudio
import Foundation

/// Drives the audio engine from the app side.
/// Today that means the device list and the virtual device loopback check.
@MainActor
final class AudioEngineModel: ObservableObject {

    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var tapdeck: AudioDevice?
    @Published private(set) var processes: [AudioProcess] = []

    @Published private(set) var isTesting = false
    @Published private(set) var status: LocalizedStringResource = "Ready"
    @Published private(set) var peakDB: Double = -120
    @Published private(set) var rmsDB: Double = -120
    @Published private(set) var receivedSamples = 0
    @Published private(set) var verdict: Verdict = .unknown
    @Published private(set) var capturedFile: URL?
    @Published private(set) var isMonitoring = false
    @Published private(set) var monitorStatus: LocalizedStringResource?
    @Published private(set) var monitorPeakDB: Double = -120

    // MARK: - Managing virtual devices

    @Published private(set) var virtualDevices: [VirtualDeviceConfiguration.Device] = []
    @Published private(set) var virtualDeviceStatus: LocalizedStringResource?

    enum Verdict {
        case unknown, passed, failed
    }

    private var input: DeviceInput?
    private var output: DeviceOutput?

    /// Metering and recording are written from the audio thread, so they have
    /// to live outside the main actor.
    private let meter = LevelAccumulator()

    /// Where the captured audio is written, so frequency can be checked later
    /// as well as level.
    static var captureURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.kosuke.Tapdeck", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("loopback-test.wav")
    }

    // MARK: - Virtual devices

    func loadVirtualDevices() {
        virtualDevices = VirtualDeviceConfiguration.load().devices
    }

    func addVirtualDevice(name: String, channels: Int = 2) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard virtualDevices.count < 8 else {
            virtualDeviceStatus = "Up to 8 virtual devices"
            return
        }
        virtualDevices.append(.init(name: trimmed, channelCount: channels))
        commitVirtualDevices()
    }

    func renameVirtualDevice(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = virtualDevices.firstIndex(where: { $0.id == id })
        else { return }
        virtualDevices[index].name = trimmed
        commitVirtualDevices()
    }

    func removeVirtualDevice(id: String) {
        guard virtualDevices.count > 1 else {
            virtualDeviceStatus = "Keep at least one device"
            return
        }
        virtualDevices.removeAll { $0.id == id }
        commitVirtualDevices()
    }

    private func commitVirtualDevices() {
        do {
            try VirtualDeviceConfiguration(devices: virtualDevices).save()
            virtualDeviceStatus = "Saved"
            // The driver applies it immediately, but the HAL needs a moment to
            // republish the device list to clients.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                refresh()
                virtualDeviceStatus = nil
            }
        } catch {
            virtualDeviceStatus = "\(L10n.describe(error))"
        }
    }

    // MARK: - Lists

    func refresh() {
        do {
            devices = try AudioDevice.all()
            tapdeck = devices.first { $0.uid == "TapdeckDevice" }
            processes = (try? AudioProcess.all()) ?? []
            loadVirtualDevices()

            if tapdeck == nil {
                status = "No Tapdeck virtual device — the driver is not installed"
                verdict = .failed
            } else if verdict == .unknown {
                // Do not overwrite a finished check.
                status = "Ready"
            }
        } catch {
            status = "Could not read the device list: \(L10n.describe(error))"
        }
    }

    // MARK: - Loopback check

    /// Send 440 Hz into the virtual device's output and read it back from the
    /// same device's input. Getting it back means the driver's ring buffer works.
    func runLoopbackTest(seconds: Double = 4) async {
        guard !isTesting else { return }
        guard let device = tapdeck else {
            status = "No Tapdeck virtual device"
            verdict = .failed
            return
        }

        isTesting = true
        verdict = .unknown
        peakDB = -120
        rmsDB = -120
        receivedSamples = 0
        resetMetrics()

        defer { isTesting = false }

        // Reading an input device needs microphone permission. This is a GUI
        // app, so the prompt appears normally.
        guard await ensureMicrophoneAccess() else {
            status = "Microphone access is not allowed. Check System Settings > Privacy & Security > Microphone."
            verdict = .failed
            return
        }

        do {
            status = "Opening the input side…"
            let deviceInput = try DeviceInput(device: device)
            let url = Self.captureURL
            try? FileManager.default.removeItem(at: url)
            meter.beginWriting(to: url)

            let meter = self.meter
            try deviceInput.start { buffer, _ in
                meter.accumulate(buffer)
            }
            input = deviceInput

            status = "Sending 440 Hz to the output side…"
            let deviceOutput = try DeviceOutput(device: device)
            let rate = deviceOutput.sampleRate
            var phase = 0.0
            let increment = 2.0 * Double.pi * 440.0 / rate

            try deviceOutput.start { channels, frameCount in
                for frame in 0..<frameCount {
                    let value = Float(sin(phase) * 0.25)
                    phase += increment
                    if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
                    for channel in channels { channel[frame] = value }
                }
            }
            output = deviceOutput

            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

            deviceOutput.stop()
            deviceInput.stop()
            output = nil
            input = nil

            finishMeasurement()
        } catch {
            input?.stop(); input = nil
            output?.stop(); output = nil
            status = "Check failed: \(L10n.describe(error))"
            verdict = .failed
        }
    }

    private func ensureMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:             return false
        }
    }

    // MARK: - Monitoring an input

    /// Record the virtual device's input side as-is.
    /// This is how the mixer's output gets checked without an external tool —
    /// ffmpeg's avfoundation capture drops blocks and cannot be measured
    /// against.
    static var monitorURL: URL {
        captureURL.deletingLastPathComponent().appendingPathComponent("monitor.wav")
    }

    func recordInput(seconds: Double = 4) async {
        guard !isMonitoring, !isTesting else { return }
        guard let device = tapdeck else {
            monitorStatus = "No Tapdeck virtual device"
            return
        }
        guard await ensureMicrophoneAccess() else {
            monitorStatus = "Microphone access is not allowed"
            return
        }

        isMonitoring = true
        monitorPeakDB = -120
        defer { isMonitoring = false }

        let monitorMeter = LevelAccumulator()
        let url = Self.monitorURL
        try? FileManager.default.removeItem(at: url)
        monitorMeter.beginWriting(to: url)

        do {
            let input = try DeviceInput(device: device)
            try input.start { buffer, _ in monitorMeter.accumulate(buffer) }
            monitorStatus = "Recording the input of \(device.name)…"
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            input.stop()
            monitorMeter.finishWriting()

            let (peak, _, count) = monitorMeter.snapshot()
            monitorPeakDB = peak > 0 ? 20 * log10(Double(peak)) : -120
            monitorStatus = count > 0
                ? "Recorded \(count) samples, peak \(String(format: "%.1f", monitorPeakDB)) dB"
                : "Nothing arrived"
        } catch {
            monitorMeter.finishWriting()
            monitorStatus = "Recording failed: \(L10n.describe(error))"
        }
    }

    // MARK: - Measurement

    private func resetMetrics() { meter.reset() }

    private func finishMeasurement() {
        meter.finishWriting()
        capturedFile = FileManager.default.fileExists(atPath: Self.captureURL.path)
            ? Self.captureURL : nil
        let (finalPeak, finalSum, n) = meter.snapshot()
        receivedSamples = n
        guard n > 0 else {
            status = "Not a single sample reached the input side."
            verdict = .failed
            return
        }

        let rms = (finalSum / Double(n)).squareRoot()
        peakDB = finalPeak > 0 ? 20 * log10(Double(finalPeak)) : -120
        rmsDB  = rms > 0 ? 20 * log10(rms) : -120

        if finalPeak < 1e-5 {
            status = "Silence — the loopback is not connected."
            verdict = .failed
        } else {
            status = "Read back the audio sent to the output side."
            verdict = .passed
        }
    }
}


/// A level meter that is safe to write from the audio thread.
/// Deliberately not on the main actor.
final class LevelAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var total = 0

    private var file: AVAudioFile?
    private var destination: URL?

    func reset() {
        lock.lock(); peak = 0; sumSquares = 0; total = 0; lock.unlock()
    }

    func beginWriting(to url: URL) {
        lock.lock(); destination = url; file = nil; lock.unlock()
    }

    func finishWriting() {
        lock.lock(); file = nil; destination = nil; lock.unlock()
    }

    func accumulate(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        var localPeak: Float = 0
        var localSum: Double = 0
        var count = 0
        for channel in 0..<channels {
            let pointer = data[channel]
            for frame in 0..<frames {
                let value = abs(pointer[frame])
                if value > localPeak { localPeak = value }
                localSum += Double(value) * Double(value)
                count += 1
            }
        }

        lock.lock()
        if localPeak > peak { peak = localPeak }
        sumSquares += localSum
        total += count

        if file == nil, let destination {
            // Match the processing format to the input exactly. Any mismatch
            // makes every write(from:) fail and leaves a header-only file.
            file = try? AVAudioFile(forWriting: destination,
                                    settings: buffer.format.settings,
                                    commonFormat: buffer.format.commonFormat,
                                    interleaved: buffer.format.isInterleaved)
        }
        try? file?.write(from: buffer)
        lock.unlock()
    }

    func snapshot() -> (peak: Float, sumSquares: Double, count: Int) {
        lock.lock(); defer { lock.unlock() }
        return (peak, sumSquares, total)
    }
}
