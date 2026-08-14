// make-icon.swift — 生成 DeepSeek Harness Desktop 的 AppIcon.iconset。
//
//   swiftc -O -o make-icon make-icon.swift
//   ./make-icon <输出 iconset 目录>
//
// 设计：macOS 圆角矩形（squircle 近似）+ DeepSeek 蓝渐变 + 白色粗体「DSH」。
// 纯 AppKit 离屏绘制，无第三方依赖，构建机（含 CI macOS runner）直接可跑。
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

  // 图标主体：Apple 网格约 80.5% 占比、圆角约主体 22.37%
  let body = s * 0.805
  let origin = (s - body) / 2
  let rect = CGRect(x: origin, y: origin, width: body, height: body)
  let path = NSBezierPath(roundedRect: rect, xRadius: body * 0.2237, yRadius: body * 0.2237)

  let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.51, blue: 0.98, alpha: 1), // #5C82FA 亮蓝
    NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.78, alpha: 1), // #1A3DC7 深蓝
  ])!
  gradient.draw(in: path, angle: -90)

  // 中央白色粗体 DSH
  let fontSize = body * 0.42
  let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
  let text = "DSH" as NSString
  let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
    .kern: fontSize * 0.02,
  ]
  let textSize = text.size(withAttributes: attrs)
  text.draw(at: NSPoint(x: (s - textSize.width) / 2,
                        y: (s - textSize.height) / 2 - body * 0.01),
            withAttributes: attrs)

  NSGraphicsContext.restoreGraphicsState()
  return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
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
