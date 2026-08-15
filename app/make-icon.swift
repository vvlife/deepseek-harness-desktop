// make-icon.swift — 生成 DeepSeek Harness Desktop 的 AppIcon.iconset。
//
//   swiftc -O -o make-icon make-icon.swift
//   ./make-icon <输出 iconset 目录> <源 PNG>
//
// 图标源图为 app/icon-src.png（蓝绿渐变圆角矩形 + 白色「D」与星点，四角透明），
// 这里只做高质量缩放输出全部 iconset 尺寸，不再程序绘制。
import AppKit

let sizes: [(name: String, px: Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

guard CommandLine.arguments.count > 2 else {
  fatalError("用法：make-icon <输出 iconset 目录> <源 PNG>")
}
let outDir = CommandLine.arguments[1]
let srcPath = CommandLine.arguments[2]

guard let src = NSImage(contentsOfFile: srcPath) else {
  fatalError("源图标读取失败：\(srcPath)")
}

func render(px: Int) -> NSBitmapImageRep {
  let s = CGFloat(px)
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let ctx = NSGraphicsContext.current!.cgContext
  ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))
  ctx.interpolationQuality = .high
  src.draw(in: CGRect(x: 0, y: 0, width: s, height: s),
           from: .zero, operation: .sourceOver, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for item in sizes {
  let rep = render(px: item.px)
  guard let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 编码失败：\(item.name)")
  }
  try png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(item.name))
  print("  + \(item.name) (\(item.px)px)")
}
print("iconset 完成：\(outDir)")
