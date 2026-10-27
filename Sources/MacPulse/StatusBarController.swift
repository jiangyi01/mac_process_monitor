import AppKit
import SwiftUI

/// Menu bar item: "[cpu] 4% [memorychip] 73%". Left click toggles a compact
/// popover; right click (or ⌃-click) opens a small menu.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let monitor: Monitor
    private let openWindow: () -> Void
    /// Called when the popover shows or hides, so sampling can go detailed.
    var onVisibilityChange: (() -> Void)?
    private var contextMenu: NSMenu?
    /// Timestamp of the mouse-down that made the transient popover close
    /// itself; without this the same click would reopen it.
    private var selfClosedAt: TimeInterval?

    var isPopoverShown: Bool { popover.isShown }

    init(monitor: Monitor, openWindow: @escaping () -> Void) {
        self.monitor = monitor
        self.openWindow = openWindow
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(rootView: MenuBarPopover(monitor: monitor, openWindow: { [weak self] in
            self?.popover.performClose(nil)
            openWindow()
        }))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        render(nil)
    }

    func render(_ s: SystemSample?) {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString()
        // Always give a color: a run without one draws black, which vanishes
        // on a dark menu bar.
        func symbol(_ name: String, _ color: NSColor) {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            img.isTemplate = true
            let a = NSTextAttachment()
            a.image = img
            // Center the glyph on the digits' cap height.
            a.bounds = CGRect(x: 0, y: (font.capHeight - img.size.height) / 2, width: img.size.width, height: img.size.height)
            title.append(NSAttributedString(attachment: a))
            title.addAttribute(.foregroundColor, value: color, range: NSRange(location: title.length - 1, length: 1))
        }
        func text(_ str: String, _ color: NSColor) {
            title.append(NSAttributedString(string: str, attributes: [.font: font, .foregroundColor: color]))
        }
        guard let s else {
            symbol("waveform.path.ecg", .labelColor)
            button.attributedTitle = title
            return
        }
        let memColor: NSColor = switch s.pressure {
        case .normal: .labelColor
        case .warning: .systemOrange
        case .critical: .systemRed
        }
        symbol("cpu", .labelColor)
        text(String(format: " %2.0f%%", s.cpu * 100), .labelColor)
        text("  ", .labelColor)
        symbol("memorychip", memColor)
        text(String(format: " %.0f%%", s.memFraction * 100), memColor)
        button.attributedTitle = title
        button.toolTip = "CPU \(Fmt.percent(s.cpu)) · 内存 \(Fmt.bytes(s.memUsed)) / \(Fmt.bytes(s.memTotal))，压力\(s.pressure.label) · 交换 \(Fmt.bytes(s.swapUsed))"
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else if let closed = selfClosedAt, let t = event?.timestamp, t - closed < 0.3 {
            selfClosedAt = nil
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            onVisibilityChange?()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开 Mac Pulse 窗口", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Mac Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        contextMenu = menu
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach again, or every later left click would open the menu too.
        statusItem.menu = nil
    }

    @objc private func openFromMenu() { openWindow() }

    func popoverDidClose(_ notification: Notification) {
        selfClosedAt = NSApp.currentEvent?.timestamp
        onVisibilityChange?()
    }
}

/// The compact view behind the menu bar item: headline numbers, advice, and
/// the heaviest apps.
struct MenuBarPopover: View {
    @ObservedObject var monitor: Monitor
    let openWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = monitor.sample {
                stats(s).padding(14)
                Divider()
                let advice = monitor.advice
                if !advice.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(advice.prefix(3)) { a in
                            Label {
                                Text(a.text).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: a.symbol).foregroundStyle(a.level == .alert ? Color.red : a.level == .warn ? .orange : .secondary)
                            }
                        }
                    }
                    .font(.caption)
                    .padding(14)
                    Divider()
                }
                topApps(s).padding(.vertical, 6)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            }
            Divider()
            HStack {
                Button("打开完整窗口", action: openWindow)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 340)
    }

    private func stats(_ s: SystemSample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                stat("CPU", Fmt.percent(s.cpu))
                Spacer()
                stat("内存", Fmt.bytes(s.memUsed), color: s.pressure == .normal ? nil : s.pressure == .warning ? .orange : .red)
                Spacer()
                stat("交换", Fmt.bytes(s.swapUsed), color: s.swapUsed >= 2 << 30 ? .orange : nil)
                Spacer()
                stat("负载", String(format: "%.1f", s.load[0]))
            }
            Text("共 \(Fmt.bytes(s.memTotal)) · 压力\(s.pressure.label) · 已开机 \(Fmt.uptime(s.bootTime, now: s.date))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func stat(_ title: String, _ value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(color ?? .primary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func topApps(_ s: SystemSample) -> some View {
        let apps = monitor.apps.sorted { $0.footprint > $1.footprint }.prefix(6)
        return VStack(spacing: 0) {
            if apps.isEmpty {
                ProgressView().controlSize(.small).padding(8)
            }
            ForEach(Array(apps)) { a in
                HStack(spacing: 8) {
                    AppIcon(bundlePath: a.bundlePath).frame(width: 16, height: 16)
                    Text(a.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(Fmt.bytes(a.footprint)).monospacedDigit()
                        .foregroundStyle(a.footprint >= 3 << 30 ? Color.red : a.footprint >= 1 << 30 ? .orange : .primary)
                    Text(String(format: "%.0f%%", a.cpu)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 3)
            }
        }
    }
}
