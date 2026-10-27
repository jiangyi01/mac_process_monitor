import AppKit

/// Live Dock icon: the app icon's dark squircle with CPU and memory bars, so
/// the state is visible without opening the window.
final class DockTileView: NSView {
    var sample: SystemSample?

    override func draw(_ dirtyRect: NSRect) {
        let s = bounds.width
        let inset = s * 0.098
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
        IconStyle.background.draw(in: bg, angle: -90)

        guard let sample else {
            IconStyle.drawPulse(in: rect)
            return
        }
        let memColor: NSColor = switch sample.pressure {
        case .normal: IconStyle.green
        case .warning: IconStyle.orange
        case .critical: IconStyle.red
        }
        let pad = rect.width * 0.13
        let barH = rect.height * 0.12
        let labelH = rect.height * 0.16
        let w = rect.width - 2 * pad
        drawBar(label: "CPU", value: sample.cpu, color: IconStyle.blue,
                origin: CGPoint(x: rect.minX + pad, y: rect.midY + rect.height * 0.06), width: w, barH: barH, labelH: labelH)
        drawBar(label: "内存", value: sample.memFraction, color: memColor,
                origin: CGPoint(x: rect.minX + pad, y: rect.minY + rect.height * 0.14), width: w, barH: barH, labelH: labelH)
    }

    private func drawBar(label: String, value: Double, color: NSColor, origin: CGPoint,
                         width: CGFloat, barH: CGFloat, labelH: CGFloat) {
        let font = NSFont.systemFont(ofSize: labelH * 0.95, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.85)]
        let pct = String(format: "%.0f%%", min(max(value, 0), 1) * 100)
        let labelY = origin.y + barH + labelH * 0.12
        (label as NSString).draw(at: CGPoint(x: origin.x, y: labelY), withAttributes: attrs)
        let pctSize = (pct as NSString).size(withAttributes: attrs)
        (pct as NSString).draw(at: CGPoint(x: origin.x + width - pctSize.width, y: labelY), withAttributes: attrs)

        let track = NSBezierPath(roundedRect: CGRect(x: origin.x, y: origin.y, width: width, height: barH),
                                 xRadius: barH / 2, yRadius: barH / 2)
        NSColor(white: 1, alpha: 0.14).setFill()
        track.fill()
        let fw = max(barH, width * CGFloat(min(max(value, 0), 1)))
        let fill = NSBezierPath(roundedRect: CGRect(x: origin.x, y: origin.y, width: fw, height: barH),
                                xRadius: barH / 2, yRadius: barH / 2)
        color.setFill()
        fill.fill()
    }
}

/// Shared with tools/make_icon.swift's look (kept in sync by hand).
enum IconStyle {
    static let background = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.10, alpha: 1),
    ])!
    static let green = NSColor(calibratedRed: 0.22, green: 0.80, blue: 0.40, alpha: 1)
    static let orange = NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)
    static let red = NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)
    static let blue = NSColor(calibratedRed: 0.25, green: 0.60, blue: 1.00, alpha: 1)

    /// A heartbeat line across the squircle.
    static func drawPulse(in rect: CGRect) {
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
        green.setStroke()
        path.stroke()
    }
}
