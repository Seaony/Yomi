// 生成 DMG 窗口背景：浅色渐变、两个图标位置的柔光圈、中间一条渐显的虚线箭头。
// 用法：swift render-background.swift <输出目录> [主色十六进制，默认 0A9BF5]
// 会输出 background.png（660x400）和 background@2x.png，dmgbuild 会自动合成 Retina 背景。
// 尺寸和图标位置必须和 dmg-settings.py 保持一致。

import AppKit

let width: CGFloat = 660
let height: CGFloat = 400
let leftIcon = CGPoint(x: 165, y: 185)
let rightIcon = CGPoint(x: 495, y: 185)

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("用法：swift render-background.swift <输出目录> [主色十六进制]\n".data(using: .utf8)!)
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let accentHex = arguments.count >= 3 ? arguments[2] : "0A9BF5"

func color(hex: String, alpha: CGFloat = 1) -> CGColor {
    let value = UInt32(hex, radix: 16) ?? 0
    return CGColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: alpha
    )
}

func render(scale: CGFloat) -> Data {
    let pixelWidth = Int(width * scale)
    let pixelHeight = Int(height * scale)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // 翻成左上角为原点，和 Finder 的图标坐标一致。
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)

    // 底色：从上到下的浅色渐变，略带一点主色。
    let base = CGGradient(
        colorsSpace: space,
        colors: [color(hex: "FCFCFD"), color(hex: "F1F3F6")] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    let tint = CGGradient(
        colorsSpace: space,
        colors: [color(hex: accentHex, alpha: 0.07), color(hex: accentHex, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        tint, startCenter: CGPoint(x: width / 2, y: -40), startRadius: 0,
        endCenter: CGPoint(x: width / 2, y: -40), endRadius: 420, options: []
    )

    // 图标后面的柔光圈，让两个图标浮起来。
    let glow = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(gray: 1, alpha: 0.95), CGColor(gray: 1, alpha: 0.55), CGColor(gray: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    for center in [leftIcon, rightIcon] {
        context.drawRadialGradient(
            glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 135, options: []
        )
    }

    // 虚线箭头：沿一条微微上拱的曲线排点，越往右越大越深。
    let start = CGPoint(x: leftIcon.x + 100, y: leftIcon.y + 8)
    let end = CGPoint(x: rightIcon.x - 112, y: rightIcon.y - 4)
    let control = CGPoint(x: (start.x + end.x) / 2, y: start.y - 26)
    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }
    let dotCount = 8
    for index in 0..<dotCount {
        // 点只排到 0.86，给箭头尖留出空隙。
        let t = CGFloat(index) / CGFloat(dotCount - 1) * 0.86
        let p = point(t)
        let radius = 1.6 + 1.8 * t
        context.setFillColor(color(hex: accentHex, alpha: 0.22 + 0.65 * t))
        context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
    }

    // 箭头尖：顺着曲线末端的方向画一个圆角折线。
    let tip = point(1)
    let before = point(0.97)
    let angle = atan2(tip.y - before.y, tip.x - before.x)
    let wing: CGFloat = 9
    let spread: CGFloat = .pi / 4.2
    context.setStrokeColor(color(hex: accentHex, alpha: 0.85))
    context.setLineWidth(3)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: tip.x - wing * cos(angle - spread), y: tip.y - wing * sin(angle - spread)))
    context.addLine(to: CGPoint(x: tip.x + 4 * cos(angle), y: tip.y + 4 * sin(angle)))
    context.addLine(to: CGPoint(x: tip.x - wing * cos(angle + spread), y: tip.y - wing * sin(angle + spread)))
    context.strokePath()

    let image = context.makeImage()!
    let bitmap = NSBitmapImageRep(cgImage: image)
    // 标注实际点尺寸，Finder 才会按 1x/2x 正确缩放。
    bitmap.size = NSSize(width: width, height: height)
    return bitmap.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try render(scale: 1).write(to: outputDirectory.appendingPathComponent("background.png"))
try render(scale: 2).write(to: outputDirectory.appendingPathComponent("background@2x.png"))
print("Wrote \(outputDirectory.path)/background.png and background@2x.png")
