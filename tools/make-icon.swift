import AppKit
import CoreGraphics
import Foundation

// Tapdeck のアプリアイコンを生成する。
// 外部ツールに依存せず CoreGraphics で直接描き、iconutil 用の .iconset を出力する。
//
// 図案: ミキサーのフェーダー3本。小さいサイズでも「音を混ぜる道具」と分かる形にする。

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/Tapdeck.iconset"

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func drawIcon(into context: CGContext, size: CGFloat) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS のアイコンは周囲に余白を持つ。実体は約 82% の領域。
    let inset = size * 0.09
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.2237   // Big Sur 以降の角丸比

    // ── 背景（斜めのグラデーション）──
    let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(shape)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(46, 196, 182), color(29, 78, 137), color(23, 34, 66)] as CFArray,
        locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: body.minX, y: body.maxY),
                               end: CGPoint(x: body.maxX, y: body.minY),
                               options: [])

    // 上端のわずかな光沢
    let gloss = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(255, 255, 255, 0.22), color(255, 255, 255, 0)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(gloss,
                               start: CGPoint(x: body.midX, y: body.maxY),
                               end: CGPoint(x: body.midX, y: body.midY),
                               options: [])
    context.restoreGState()

    // ── 図案: 3つの音源が1つにまとまり、波形として出ていく ──
    //
    // 「複数の入力を束ねて1本の出力にする」という Tapdeck の役割そのもの。
    // フェーダーの絵は汎用的すぎて「設定」に見えるため採らない。

    let unit = body.width
    let inputX = body.minX + unit * 0.175
    let junctionX = body.midX - unit * 0.045
    let outputEndX = body.maxX - unit * 0.135
    let centerY = body.midY

    let inputOffsets: [CGFloat] = [-unit * 0.205, 0, unit * 0.205]
    let lineWidth = unit * 0.068
    let inputDotRadius = unit * 0.058

    context.setLineCap(.round)
    context.setLineJoin(.round)

    // 入力3本 → 合流点
    context.setStrokeColor(color(255, 255, 255, 0.95))
    context.setLineWidth(lineWidth)
    for offset in inputOffsets {
        let y = centerY + offset
        context.move(to: CGPoint(x: inputX, y: y))
        if offset == 0 {
            context.addLine(to: CGPoint(x: junctionX, y: centerY))
        } else {
            // 合流点の手前でなめらかに曲げる
            let bendX = inputX + (junctionX - inputX) * 0.45
            context.addLine(to: CGPoint(x: bendX, y: y))
            context.addCurve(to: CGPoint(x: junctionX, y: centerY),
                             control1: CGPoint(x: bendX + (junctionX - bendX) * 0.55, y: y),
                             control2: CGPoint(x: junctionX - (junctionX - bendX) * 0.3, y: centerY))
        }
        context.strokePath()
    }

    // 入力端の点
    context.setFillColor(color(255, 255, 255, 0.92))
    for offset in inputOffsets {
        let y = centerY + offset
        context.fillEllipse(in: CGRect(x: inputX - inputDotRadius, y: y - inputDotRadius,
                                       width: inputDotRadius * 2, height: inputDotRadius * 2))
    }

    // 出力: 合流点から波形として伸びる
    context.setStrokeColor(color(255, 255, 255, 1))
    context.setLineWidth(lineWidth * 1.15)
    let waveStart = junctionX
    let waveLength = outputEndX - waveStart
    let amplitude = unit * 0.155
    context.move(to: CGPoint(x: waveStart, y: centerY))
    let steps = 96
    for step in 1...steps {
        let t = CGFloat(step) / CGFloat(steps)
        let x = waveStart + waveLength * t
        // 合流点では振幅0から始め、進むにつれて開く
        // 合流点では振幅0から始め、開いてから終端でまた閉じる。
        // 途中で切れた線に見えないようにするため。
        let envelope = min(1, t * 2.6) * min(1, (1 - t) * 3.4 + 0.25)
        let y = centerY + sin(t * .pi * 3) * amplitude * envelope
        context.addLine(to: CGPoint(x: x, y: y))
    }
    context.strokePath()

    // 合流点の結節
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.006),
                      blur: size * 0.015, color: color(0, 0, 0, 0.4))
    context.setFillColor(color(255, 255, 255, 1))
    let nodeRadius = unit * 0.078
    context.fillEllipse(in: CGRect(x: junctionX - nodeRadius, y: centerY - nodeRadius,
                                   width: nodeRadius * 2, height: nodeRadius * 2))
    context.restoreGState()
}

func writePNG(size: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "icon", code: 1)
    }
    drawIcon(into: context, size: CGFloat(size))
    guard let image = context.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 3)
    }
    try data.write(to: url)
}

let directory = URL(fileURLWithPath: outputDirectory)
try? FileManager.default.removeItem(at: directory)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

// .icns に必要な組み合わせ
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",    32),
    ("icon_32x32",      32), ("icon_32x32@2x",    64),
    ("icon_128x128",   128), ("icon_128x128@2x", 256),
    ("icon_256x256",   256), ("icon_256x256@2x", 512),
    ("icon_512x512",   512), ("icon_512x512@2x",1024),
]

for variant in variants {
    try writePNG(size: variant.pixels,
                 to: directory.appendingPathComponent("\(variant.name).png"))
}
print("✓ \(outputDirectory) に \(variants.count) 枚を書き出しました")
