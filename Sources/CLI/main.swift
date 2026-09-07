import AVFoundation
import CoreAudio
import Foundation

// tapproof — Core Audio Process Tap が実際に動くかを確かめるための検証用CLI。
// Tapdeck 本体のオーディオエンジン (Sources/Engine) をそのまま使う。

func usage() -> Never {
    print("""
    使い方:
      tapproof list
          Core Audio が認識しているプロセスを一覧表示（♪ は現在音を出しているもの）

      tapproof rec <PID または アプリ名> <秒数> [出力.wav]
          指定したアプリの音声だけを録音

      tapproof rec-system <秒数> [出力.wav]
          システム全体の音声を録音（自分自身は除外）
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

// MARK: - entry

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }

do {
    switch command {
    case "list":
        try runList()

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
