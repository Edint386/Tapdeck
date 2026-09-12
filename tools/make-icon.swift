import AppKit
import CoreGraphics
import Foundation

// Generate Tapdeck's app icon.
// Drawn directly with CoreGraphics so there is no dependency on an external
// tool, and written out as an .iconset for iconutil.

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/Tapdeck.iconset"

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func drawIcon(into context: CGContext, size: CGFloat) {
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS icons carry padding; the artwork fills about 82% of the canvas.
    let inset = size * 0.09
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.2237   // corner ratio used since Big Sur

    // -- Background: a diagonal gradient --
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

    // A faint sheen along the top edge
    let gloss = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(255, 255, 255, 0.22), color(255, 255, 255, 0)] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(gloss,
                               start: CGPoint(x: body.midX, y: body.maxY),
                               end: CGPoint(x: body.midX, y: body.midY),
                               options: [])
    context.restoreGState()

    // -- The motif: three sources merging and leaving as one waveform --
    //
    // That is exactly what Tapdeck does: bundle several inputs into one output.
    // A picture of faders was tried first and read as a Settings icon.

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

    // Three inputs running into the junction
    context.setStrokeColor(color(255, 255, 255, 0.95))
    context.setLineWidth(lineWidth)
    for offset in inputOffsets {
        let y = centerY + offset
        context.move(to: CGPoint(x: inputX, y: y))
        if offset == 0 {
            context.addLine(to: CGPoint(x: junctionX, y: centerY))
        } else {
            // Curve smoothly just before the junction
            let bendX = inputX + (junctionX - inputX) * 0.45
            context.addLine(to: CGPoint(x: bendX, y: y))
            context.addCurve(to: CGPoint(x: junctionX, y: centerY),
                             control1: CGPoint(x: bendX + (junctionX - bendX) * 0.55, y: y),
                             control2: CGPoint(x: junctionX - (junctionX - bendX) * 0.3, y: centerY))
        }
        context.strokePath()
    }

    // Dots at the input ends
    context.setFillColor(color(255, 255, 255, 0.92))
    for offset in inputOffsets {
        let y = centerY + offset
        context.fillEllipse(in: CGRect(x: inputX - inputDotRadius, y: y - inputDotRadius,
                                       width: inputDotRadius * 2, height: inputDotRadius * 2))
    }

    // Output: a waveform leaving the junction
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
        // Start at zero amplitude, open out, then close again at the end so
        // the line does not look cut off.
        let envelope = min(1, t * 2.6) * min(1, (1 - t) * 3.4 + 0.25)
        let y = centerY + sin(t * .pi * 3) * amplitude * envelope
        context.addLine(to: CGPoint(x: x, y: y))
    }
    context.strokePath()

    // The junction node
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

// The sizes an .icns needs
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
print("Wrote \(variants.count) images to \(outputDirectory)")
