// Generates Resources/AppIcon.icns — a dark rounded square with a green
// heartbeat line. Run from the package root:
//   swift tools/make_icon.swift
// Requires only Command Line Tools (uses AppKit offscreen drawing + iconutil).
import AppKit

func draw(_ s: CGFloat) {
    // Background squircle (Apple icon grid: ~80% canvas, ~22.5% corner radius)
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1),
    ])!.draw(in: bg, angle: -90)

    // Heartbeat line, same shape as IconStyle.drawPulse in the app
    let pts: [(CGFloat, CGFloat)] = [
        (0.10, 0.50), (0.32, 0.50), (0.40, 0.66), (0.50, 0.24), (0.60, 0.80), (0.68, 0.50), (0.90, 0.50),
    ]
    let path = NSBezierPath()
    for (i, p) in pts.enumerated() {
        let pt = CGPoint(x: rect.minX + rect.width * p.0, y: rect.minY + rect.height * p.1)
        if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
    }
    path.lineWidth = rect.width * 0.07
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor(calibratedRed: 0.22, green: 0.80, blue: 0.40, alpha: 1).setStroke()
    path.stroke()
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in variants {
    try! render(px).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
try? fm.removeItem(atPath: iconset)
print(p.terminationStatus == 0 ? "✅ Resources/AppIcon.icns generated" : "❌ iconutil failed")
