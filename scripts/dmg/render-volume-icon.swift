// 把满版的 App 图标裁成 macOS 标准圆角图标，生成 DMG 卷图标。
// App 图标是满版正方形，系统显示 App 时会自动裁圆角，但磁盘卷图标不会，直接用会是方块。
// 用法：swift render-volume-icon.swift <1024 图标原图> <输出.icns>

import AppKit
import SwiftUI

let arguments = CommandLine.arguments
// 文件里可能有多种尺寸，固定取最大的一张，避免拿到小图放大后发糊。
guard arguments.count == 3,
      let source = NSImage(contentsOfFile: arguments[1])?.representations
          .compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide })?.cgImage
else {
    FileHandle.standardError.write("Usage: swift render-volume-icon.swift <1024 icon image> <output.icns>\n".data(using: .utf8)!)
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2])

// 按 Apple 图标模板：1024 画布里图标本体 824，圆角 185，四周留出投影的位置。
func render(size: Int) -> Data {
    let scale = CGFloat(size) / 1024
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.interpolationQuality = .high

    let body = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = RoundedRectangle(cornerRadius: 185 * scale, style: .continuous).path(in: body).cgPath

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.draw(source, in: body)
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("volume-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try render(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
