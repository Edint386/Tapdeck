import AVFoundation
import CoreAudio
import Foundation

// tapproof — Core Audio Process Tap が実際に動くかを確かめるための検証用CLI。
// Tapdeck 本体のオーディオエンジン (Sources/Engine) をそのまま使う。


// MARK: - ログ

// LaunchServices (`open`) から起動された場合、標準出力は捨てられる。
// TCC のプロンプトを出すには `open` 経由で起動する必要があるため、
// 出力先ファイルの隣に .log を書いて結果を確認できるようにする。
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
    使い方:
      tapproof list
          Core Audio が認識しているプロセスを一覧表示（♪ は現在音を出しているもの）

      tapproof rec <PID または アプリ名> <秒数> [出力.wav]
          指定したアプリの音声だけを録音

      tapproof rec-system <秒数> [出力.wav]
          システム全体の音声を録音（自分自身は除外）

      tapproof devices
          オーディオデバイスを一覧表示

      tapproof virtual [名前 ...]
          仮想デバイスの一覧表示。名前を並べると、その構成に置き換える。

      tapproof mix <PID または アプリ名> <秒数>
          指定アプリの音を Mixer 経由で Tapdeck 仮想デバイスへ送る
          （検証は別途 ffmpeg -f avfoundation -i ":0" で録音する）

      tapproof loopback <秒数> [出力.wav]
          Tapdeck 仮想デバイスの出力側に 440Hz を流し込み、
          同じデバイスの入力側から読み返せるか検証する
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
        // インターリーブ時は floatChannelData[0] に全chが交互に並ぶ
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
    print("PID     再生中  名前                          バンドルID")
    print(String(repeating: "─", count: 88))
    for p in procs {
        let mark = p.isPlayingAudio ? " ♪  " : "    "
        let name = p.name.padding(toLength: min(28, max(p.name.count, 28)),
                                  withPad: " ", startingAt: 0)
        print(String(format: "%-7d %@  %@  %@", p.pid, mark, name, p.bundleID ?? "—"))
    }
    print("\n計 \(procs.count) プロセス、うち再生中 \(procs.filter(\.isPlayingAudio).count)")
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

    print("対象   : \(label)")
    print("出力   : \(output.path)")
    print("収録   : \(seconds) 秒 …")

    try tap.start(mode: mode) { buffer in
        lock.lock()
        defer { lock.unlock() }

        if file == nil {
            let fmt = buffer.format
            do {
                // 処理フォーマットを Tap の実フォーマットと完全一致させる。
                // 一致していないと write(from:) が投げて1サンプルも書けない。
                file = try AVAudioFile(forWriting: output,
                                       settings: fmt.settings,
                                       commonFormat: fmt.commonFormat,
                                       interleaved: fmt.isInterleaved)
            } catch {
                if writeError == nil { writeError = "ファイル作成: \(error)" }
            }
        }
        do {
            try file?.write(from: buffer)
        } catch {
            if writeError == nil { writeError = "書き込み: \(error)" }
        }

        let m = peakAndRMS(buffer)
        if m.peak > peak { peak = m.peak }
        sumSquares += m.sumSquares
        totalSamples += m.count
        callbacks += 1
    }

    guard let fmt = tap.format else { throw CoreAudioError.missing("Tap のフォーマット") }
    print("形式   : \(Int(fmt.sampleRate)) Hz / \(fmt.channelCount) ch / "
          + "\(fmt.commonFormat == .pcmFormatFloat32 ? "Float32" : "その他") / "
          + (fmt.isInterleaved ? "インターリーブ" : "非インターリーブ"))

    if let c = tap.sampleRateCorrection {
        print("補正   : Tap申告 \(Int(c.declared)) Hz → 実レート \(Int(c.actual)) Hz に補正")
    }

    Thread.sleep(forTimeInterval: seconds)
    tap.stop()

    lock.lock()
    file = nil
    let finalPeak = peak, finalSum = sumSquares, n = totalSamples, cb = callbacks
    let err = writeError
    lock.unlock()

    if let err { print("⚠️  書き出しエラー: \(err)") }
    let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
    print("出力ファイル        : \(size) バイト")

    print("\n── 結果 ──")
    print("IOProc 呼び出し回数 : \(cb)")
    print("取得サンプル数      : \(n)")
    guard n > 0 else {
        print("⚠️  音声が1サンプルも届いていません。")
        exit(2)
    }
    let rms = (finalSum / Double(n)).squareRoot()
    print("ピーク              : \(db(Double(finalPeak)))")
    print("RMS                 : \(db(rms))")
    if finalPeak < 1e-6 {
        print("⚠️  完全な無音です（Tap は動いているが対象が音を出していない可能性）。")
    } else {
        print("✅ 音声を取得できました。")
    }
}


/// マイク許可を要求し、結果が出るまでメインのランループを回しながら待つ。
///
/// セマフォでメインスレッドをブロックしてはいけない。TCC のプロンプトは
/// プロセスのメインランループ経由で提示されるため、止めると永遠に出てこない
/// （requestAccess が即座に false を返し、許可状態も「未決定」のままになる）。
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
        Log.line("   （プロンプトへの応答がありませんでした）")
        return false
    }
    return result
}

/// ランループを回しながら指定秒数待つ。オーディオのコールバックは別スレッドで
/// 動くが、メインを止めるとシステムからの通知を取りこぼすため。
func waitSpinningRunLoop(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
}

// MARK: - loopback: 仮想デバイスの検証

func runLoopback(seconds: Double, output: URL) throws {
    Log.setDestination(besideOutput: output)
    guard let device = try AudioDevice.tapdeck() else {
        Log.line("Tapdeck 仮想デバイスが見つかりません。ドライバをインストールしましたか？")
        Log.line("  sudo cp -R build/Tapdeck.driver /Library/Audio/Plug-Ins/HAL/")
        Log.line("  sudo killall coreaudiod")
        exit(1)
    }
    Log.line("デバイス : \(device.name) (\(device.uid))")
    Log.line("           入力 \(device.inputChannels)ch / 出力 \(device.outputChannels)ch / \(Int(device.sampleRate)) Hz")

    // 入力デバイスの読み取りにはマイク許可が要る。CLI 単体だと TCC が
    // プロンプトを出せず無期限にブロックするので、状態を先に確かめる。
    let auth = AVCaptureDevice.authorizationStatus(for: .audio)
    if auth != .authorized {
        Log.line("マイク許可 : 未取得（状態 \(auth.rawValue)）— 要求します …")
        let granted = requestMicrophoneAccessSync(timeout: 60)
        guard granted else {
            Log.line("❌ マイクの使用が許可されませんでした。入力デバイスは読めません。")
            exit(1)
        }
        Log.line("マイク許可 : 取得しました")
    }

    // ── 入力側: 仮想デバイスから読み返す ──
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
    Log.line("入力形式 : \(Int(input.format.sampleRate)) Hz / \(input.format.channelCount) ch")

    // ── 出力側: 仮想デバイスへ 440Hz を流し込む ──
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
    Log.line("出力形式 : \(Int(rate)) Hz / \(out.outputFormat.channelCount) ch — 440Hz を送出中")
    Log.line("検証     : \(seconds) 秒 …")

    waitSpinningRunLoop(seconds)
    out.stop()
    input.stop()

    lock.lock()
    file = nil
    let finalPeak = peak, finalSum = sumSquares, n = total, err = writeError
    lock.unlock()

    Log.line("\n── 結果 ──")
    if let err { print("⚠️  書き出しエラー: \(err)") }
    Log.line("取得サンプル数      : \(n)")
    guard n > 0 else {
        Log.line("⚠️  入力側に何も届いていません。")
        exit(2)
    }
    let rms = (finalSum / Double(n)).squareRoot()
    Log.line("ピーク              : \(db(Double(finalPeak)))")
    Log.line("RMS                 : \(db(rms))")
    if finalPeak < 1e-5 {
        Log.line("❌ 無音です。ループバックが繋がっていません。")
        exit(2)
    }
    Log.line("✅ 出力側に流した音を入力側から読み返せました。")
}


// MARK: - mix: ミキサーの検証

func runMix(target: String, seconds: Double) throws {
    guard let device = try AudioDevice.tapdeck() else {
        print("Tapdeck 仮想デバイスが見つかりません。"); exit(1)
    }
    let process: AudioProcess?
    if let pid = pid_t(target) { process = try AudioProcess.find(pid: pid) }
    else { process = try AudioProcess.find(matching: target) }
    guard let source = process else {
        print("「\(target)」に一致するプロセスが見つかりません。"); exit(1)
    }

    let mixer = Mixer()
    let entry = mixer.add(.application(bundleID: source.bundleID, name: source.name))
    print("ソース   : \(source.name) (PID \(source.pid))")
    print("出力先   : \(device.name) — \(Int(device.sampleRate)) Hz")

    try mixer.start(to: device)
    print("ソース形式: \(entry.formatDescription)")
    print("送出中   : \(seconds) 秒 …")

    // 1秒ごとにソース側と出力側のピークを出して、どこで切れているかを見る。
    let steps = max(1, Int(seconds))
    for step in 1...steps {
        Thread.sleep(forTimeInterval: 1)
        let sourcePeak = entry.ring.takePeak()
        let masterPeak = mixer.takeMasterPeak()
        print(String(format: "  %2d秒  ソース %@   出力 %@   枯渇 %d  溢れ %d  滞留 %d frames",
                     step, db(Double(sourcePeak)), db(Double(masterPeak)),
                     entry.ring.underruns, entry.ring.overruns, entry.ring.fill))
        if let tap = entry.tapForDiagnostics {
            print("         Tap の時刻飛び: \(tap.discontinuityCount) 回")
        }

    }

    mixer.stop()
    print("停止しました。")
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
        print("入力ch 出力ch  レート    名前                          UID")
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
            print("「\(needle)」に一致するプロセスが見つかりません。tapproof list で確認してください。")
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
            print("設定上の仮想デバイス:")
            for device in configuration.devices {
                print("  \(device.name)  (\(device.uid), \(device.channelCount)ch)")
            }
            let live = try AudioDevice.all().filter { $0.uid.hasPrefix("TapdeckDevice") }
            print("実際に見えている仮想デバイス:")
            for device in live {
                print("  \(device.name)  (\(device.uid), 入力\(device.inputChannels)ch/出力\(device.outputChannels)ch)")
            }
        } else {
            let names = Array(args.dropFirst())
            let devices = names.enumerated().map { index, name in
                VirtualDeviceConfiguration.Device(
                    uid: index == 0 ? "TapdeckDevice" : "TapdeckDevice-\(index)",
                    name: name)
            }
            try VirtualDeviceConfiguration(devices: devices).save()
            print("\(devices.count) 台を送信しました。")
            Thread.sleep(forTimeInterval: 1)
            let live = try AudioDevice.all().filter { $0.uid.hasPrefix("TapdeckDevice") }
            print("実際に見えている仮想デバイス:")
            for device in live {
                print("  \(device.name)  (\(device.uid), 入力\(device.inputChannels)ch/出力\(device.outputChannels)ch)")
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
                      label: "システム全体",
                      seconds: seconds,
                      output: out)

    default:
        usage()
    }
} catch {
    print("エラー: \(error.localizedDescription)")
    exit(1)
}
