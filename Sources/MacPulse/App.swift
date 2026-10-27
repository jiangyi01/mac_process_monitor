import AppKit
import SwiftUI

@main
enum MacPulseMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = Monitor()
    private var window: NSWindow!
    private let tile = DockTileView()
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMainMenu()
        let args = CommandLine.arguments
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }

        tile.frame = NSRect(origin: .zero, size: NSApp.dockTile.size)
        NSApp.dockTile.contentView = tile
        monitor.onSample = { [weak self] s in
            guard let self else { return }
            self.tile.sample = s
            NSApp.dockTile.display()
            self.statusBar.render(s)
        }

        makeWindow()
        statusBar = StatusBarController(monitor: monitor) { [weak self] in self?.showWindow() }
        statusBar.onVisibilityChange = { [weak self] in self?.updateDetail() }
        monitor.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        updateDetail()

        // Debug: `--snapshot out.png [--dark]` renders the window and quits.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let out = args[i + 1]
            monitor.detailed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.snapshot(to: out)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon brings the monitor back.
        showWindow()
        return true
    }

    private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    private func makeWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Mac Pulse"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MonitorView(monitor: monitor))
        window.contentMinSize = NSSize(width: 640, height: 640)
        window.center()
        window.setFrameAutosaveName("MacPulseMain")

        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
            nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateDetail() }
            }
        }
    }

    /// Full per-process sampling only while someone can see it.
    private func updateDetail() {
        let windowShown = window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        monitor.detailed = windowShown || (statusBar?.isPopoverShown ?? false)
    }

    private func snapshot(to path: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))

        let tileRep = tile.bitmapImageRepForCachingDisplay(in: tile.bounds)!
        tile.cacheDisplay(in: tile.bounds, to: tileRep)
        let tilePath = (path as NSString).deletingPathExtension + "-dock.png"
        try? tileRep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: tilePath))

        let pop = NSHostingView(rootView: MenuBarPopover(monitor: monitor, openWindow: {}))
        pop.frame = NSRect(origin: .zero, size: pop.fittingSize)
        if let popRep = pop.bitmapImageRepForCachingDisplay(in: pop.bounds) {
            pop.cacheDisplay(in: pop.bounds, to: popRep)
            let popPath = (path as NSString).deletingPathExtension + "-menubar.png"
            try? popRep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: popPath))
        }
    }

    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Mac Pulse", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Mac Pulse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Mac Pulse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = win
        main.addItem(windowItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }
}
