import AppKit
import Foundation

struct HistoryPoint: Identifiable {
    let date: Date
    let cpu: Double          // 0...100
    let mem: Double          // 0...100
    var id: Date { date }
}

struct Advice: Identifiable {
    enum Level { case info, warn, alert }
    let id: String
    let level: Level
    let symbol: String
    let text: String
}

/// Owns the sampling loop: every 2 s, for the menu bar and Dock icon. The
/// system counters cost microseconds; the per-process scan and `top` only
/// run while the window or the menu bar popover is on screen.
@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var sample: SystemSample?
    @Published private(set) var history: [HistoryPoint] = []
    @Published private(set) var processes: [ProcInfo] = []
    @Published private(set) var apps: [AppGroup] = []
    @Published private(set) var hasPrivileged = false

    var onSample: ((SystemSample) -> Void)?

    var detailed = false {
        didSet {
            guard detailed != oldValue else { return }
            if detailed { top.start() } else { top.stop() }
            schedule()
        }
    }

    static let historySpan: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.yijiang.macpulse.sampler", qos: .utility)
    private let system = SystemSampler()
    private nonisolated let scanner = ProcessScanner()
    private let top = TopFeed()
    private var timer: Timer?

    init() {
        top.onSnapshot = { [weak self] rows in
            guard let self else { return }
            let scanner = self.scanner
            self.queue.async { scanner.privileged.merge(rows) { $1 } }
            Task { @MainActor in self.hasPrivileged = true }
        }
    }

    func start() {
        schedule()
    }

    func stop() {
        timer?.invalidate()
        top.stop()
    }

    private func schedule() {
        timer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = detailed ? 0.2 : 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        let wantProcs = detailed
        queue.async { [system, scanner] in
            let s = system.sample()
            let procs = wantProcs ? scanner.scan() : nil
            let groups = procs.map { scanner.group($0) }
            DispatchQueue.main.async { [weak self] in
                self?.publish(s, procs, groups)
            }
        }
    }

    private func publish(_ s: SystemSample, _ procs: [ProcInfo]?, _ groups: [AppGroup]?) {
        sample = s
        let cutoff = s.date.addingTimeInterval(-Self.historySpan)
        history.removeAll { $0.date < cutoff }
        history.append(HistoryPoint(date: s.date, cpu: s.cpu * 100, mem: s.memFraction * 100))
        if let procs { processes = procs }
        if let groups { apps = groups }
        onSample?(s)
    }

    // MARK: - Advice

    var advice: [Advice] {
        guard let s = sample else { return [] }
        var out: [Advice] = []
        switch s.pressure {
        case .critical:
            out.append(Advice(id: "pressure", level: .alert, symbol: "memorychip",
                              text: "内存压力严重：系统在大量压缩和换页，操作会明显卡顿。先退出不用的大应用。"))
        case .warning:
            out.append(Advice(id: "pressure", level: .warn, symbol: "memorychip",
                              text: "内存压力偏高：可用内存不多了，再开大应用会变慢。"))
        case .normal: break
        }
        let gb: UInt64 = 1 << 30
        if s.swapUsed >= 2 * gb {
            out.append(Advice(id: "swap", level: s.swapUsed >= 6 * gb ? .alert : .warn, symbol: "externaldrive",
                              text: "交换空间已用 \(Fmt.bytes(s.swapUsed))：放不下的内存被写到了硬盘，切回久未使用的窗口会顿一下。"))
        }
        let days = Int(s.date.timeIntervalSince(s.bootTime) / 86_400)
        if days >= 14 {
            out.append(Advice(id: "uptime", level: .warn, symbol: "arrow.clockwise",
                              text: "已经 \(days) 天没重启。系统服务的内存泄漏和交换文件只有重启才能清掉。"))
        }
        // A system service holding gigabytes is almost always a leak.
        let normalHeavy: Set<String> = ["WindowServer", "kernel_task"]
        if let leak = processes
            .filter({ ProcessScanner.outermostBundle($0.path) == nil || $0.path.hasPrefix("/System/") })
            .filter({ !normalHeavy.contains($0.name) && $0.footprint >= 3 * gb / 2 })
            .max(by: { $0.footprint < $1.footprint }) {
            out.append(Advice(id: "leak", level: .warn, symbol: "drop",
                              text: "系统进程 \(leak.name) 占了 \(Fmt.bytes(leak.footprint))，明显偏高，多半是内存泄漏；重启或注销后会恢复。"))
        }
        if let big = apps.filter({ $0.bundlePath != nil }).max(by: { $0.footprint < $1.footprint }),
           big.footprint >= 3 * gb, s.pressure != .normal || s.swapUsed >= 2 * gb {
            out.append(Advice(id: "bigapp", level: .info, symbol: "app.badge",
                              text: "\(big.name) 占用最多（\(Fmt.bytes(big.footprint))），暂时不用可以退出。"))
        }
        switch s.thermal {
        case .serious, .critical:
            out.append(Advice(id: "thermal", level: .alert, symbol: "thermometer.high",
                              text: "机器过热，系统正在降频。"))
        case .fair:
            out.append(Advice(id: "thermal", level: .info, symbol: "thermometer.medium",
                              text: "机器有点热，持续高负载可能会降频。"))
        default: break
        }
        if s.cpu > 0.85 {
            out.append(Advice(id: "cpu", level: .warn, symbol: "cpu",
                              text: "CPU 几乎满载，看下面按 CPU 排序找是谁。"))
        }
        if s.diskTotal > 0, Double(s.diskFree) / Double(s.diskTotal) < 0.1 {
            out.append(Advice(id: "disk", level: .warn, symbol: "internaldrive",
                              text: "磁盘只剩 \(Fmt.bytes(UInt64(s.diskFree)))，空间太少会拖慢交换和系统更新。"))
        }
        return out
    }
}

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        let v = Double(b), gb = 1_073_741_824.0, mb = 1_048_576.0
        if v >= gb { return String(format: v >= 100 * gb ? "%.0f GB" : "%.1f GB", v / gb) }
        if v >= mb { return String(format: "%.0f MB", v / mb) }
        return String(format: "%.0f KB", v / 1024)
    }

    static func rate(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        if bps >= 1024 { return String(format: "%.0f KB/s", bps / 1024) }
        return String(format: "%.0f B/s", bps)
    }

    static func percent(_ f: Double) -> String { String(format: "%.0f%%", f * 100) }

    static func uptime(_ since: Date, now: Date) -> String {
        let t = Int(now.timeIntervalSince(since))
        let d = t / 86_400, h = (t % 86_400) / 3600, m = (t % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分钟"
    }
}
