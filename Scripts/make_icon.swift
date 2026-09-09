import AppKit

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetSizes: [Int: [String]] = [
    16: ["icon_16x16.png"],
    32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"],
    128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"],
    1024: ["icon_512x512@2x.png"],
]

func renderIcon(pixels: Int) -> NSBitmapImageRep? {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = context
    let ctx = context.cgContext

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedRed: 0.13, green: 0.08, blue: 0.36, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.43, green: 0.22, blue: 0.88, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.07, green: 0.50, blue: 0.74, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.white.withAlphaComponent(0.32).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    let center = CGPoint(x: size * 0.5, y: size * 0.58)
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: size * 0.55, options: [])

    let heights: [CGFloat] = [0.32, 0.56, 0.88, 0.56, 0.32]
    let barWidth = size * 0.088
    let gap = size * 0.052
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = (size - totalWidth) / 2
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    for relativeHeight in heights {
        let barHeight = size * relativeHeight
        let barRect = CGRect(x: x, y: (size - barHeight) / 2, width: barWidth, height: barHeight)
        let path = CGPath(roundedRect: barRect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outputURL = URL(fileURLWithPath: outputDir)
for (pixels, names) in iconsetSizes.sorted(by: { $0.key < $1.key }) {
    guard let rep = renderIcon(pixels: pixels), let data = rep.representation(using: .png, properties: [:]) else {
        continue
    }
    for name in names {
        try! data.write(to: outputURL.appendingPathComponent(name))
    }
}
print("iconset written to \(outputDir)")
