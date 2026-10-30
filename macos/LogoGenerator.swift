// LogoGenerator.swift — 生成 AppIcon.iconset（与 ChatGPTWay 的 LogoGenerator 同构）

import AppKit

private let deep = NSColor(calibratedRed: 0.05, green: 0.32, blue: 0.42, alpha: 1)
private let teal = NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.58, alpha: 1)
private let mint = NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.78, alpha: 1)

func render(size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocusFlipped(false)
    let s = CGFloat(size)

    let card = NSRect(x: s * 0.04, y: s * 0.04, width: s * 0.92, height: s * 0.92)
    let path = NSBezierPath(roundedRect: card, xRadius: s * 0.25, yRadius: s * 0.25)
    NSGradient(starting: deep, ending: teal)?.draw(in: path, angle: -35)

    let route = NSBezierPath()
    route.lineWidth = max(2, s * 0.085)
    route.lineCapStyle = .round
    route.move(to: NSPoint(x: s * 0.20, y: s * 0.30))
    route.curve(to: NSPoint(x: s * 0.80, y: s * 0.70),
                controlPoint1: NSPoint(x: s * 0.50, y: s * 0.12),
                controlPoint2: NSPoint(x: s * 0.50, y: s * 0.88))
    mint.setStroke()
    route.stroke()

    let nodes = [NSPoint(x: s * 0.20, y: s * 0.30),
                 NSPoint(x: s * 0.50, y: s * 0.50),
                 NSPoint(x: s * 0.80, y: s * 0.70)]
    for (index, point) in nodes.enumerated() {
        let dotSize = s * (index == 1 ? 0.15 : 0.20)
        let dot = NSBezierPath(ovalIn: NSRect(x: point.x - dotSize / 2, y: point.y - dotSize / 2,
                                              width: dotSize, height: dotSize))
        NSColor.white.setFill()
        dot.fill()
        mint.setStroke()
        dot.lineWidth = max(1, s * 0.04)
        dot.stroke()
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "LocalsocksLogo", code: 1)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
guard args.count == 2 else { fatalError("usage: LogoGenerator <iconset-dir>") }
let directory = args[1]
try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
                      ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
                      ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
                      ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
                      ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)] {
    try writePNG(render(size: size), to: URL(fileURLWithPath: directory).appendingPathComponent(name).path)
}
