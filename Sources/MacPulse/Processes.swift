import Darwin
import Foundation

struct ProcInfo: Identifiable {
    let pid: Int32
    var name: String
    var path: String
    var footprint: UInt64
    var cpu: Double          // percent of one core, like Activity Monitor
    var id: Int32 { pid }
}

struct AppGroup: Identifiable {
    let id: String           // bundle path, or process name for loose binaries
    var name: String
    var bundlePath: String?
    var footprint: UInt64 = 0
    var cpu: Double = 0
    var count = 0
}

/// One row of `top` output, used for processes we can't read ourselves.
struct TopRow {
    var mem: UInt64
    var cpu: Double
    var command: String
}

/// Per-process memory footprint and CPU. Processes owned by our user are read
/// directly with proc_pid_rusage; root and system-user processes
/// (WindowServer, kernel_task, mds…) refuse that call, so their numbers come
/// from the setuid `top` via `TopFeed`. Not thread-safe: call from one queue.
final class ProcessScanner: @unchecked Sendable {
    private struct Prev { var start: UInt64; var cpuTime: UInt64; var at: UInt64 }
    private var prev: [Int32: Prev] = [:]
    private var paths: [Int32: (start: UInt64, path: String)] = [:]
    private var bundleNames: [String: String] = [:]
    /// Latest `top` numbers, keyed by pid; pruned to live pids on each scan.
    var privileged: [Int32: TopRow] = [:]

    func scan() -> [ProcInfo] {
        var pids = [Int32](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        let now = mach_absolute_time()
        var seen = Set<Int32>()
        var out: [ProcInfo] = []
        out.reserveCapacity(n)
        var nextPrev: [Int32: Prev] = [:]

        for pid in pids.prefix(max(n, 0)) where pid > 0 {
            seen.insert(pid)
            var ri = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ri) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            let path = self.path(pid, start: rc == 0 ? ri.ri_proc_start_abstime : 0)
            if rc == 0 {
                // rusage CPU times and mach_absolute_time share a unit (mach
                // ticks on Apple Silicon, ns on Intel), so the ratio needs no
                // timebase conversion.
                let cpuTime = ri.ri_user_time + ri.ri_system_time
                var cpu = 0.0
                if let p = prev[pid], p.start == ri.ri_proc_start_abstime, now > p.at, cpuTime >= p.cpuTime {
                    cpu = Double(cpuTime - p.cpuTime) / Double(now - p.at) * 100
                }
                nextPrev[pid] = Prev(start: ri.ri_proc_start_abstime, cpuTime: cpuTime, at: now)
                out.append(ProcInfo(pid: pid, name: Self.name(pid, path: path), path: path,
                                    footprint: ri.ri_phys_footprint, cpu: cpu))
            } else if let row = privileged[pid] {
                let name = path.isEmpty ? row.command : Self.name(pid, path: path)
                out.append(ProcInfo(pid: pid, name: name, path: path, footprint: row.mem, cpu: row.cpu))
            }
        }
        // kernel_task (pid 0) never shows up in proc_listallpids.
        if let k = privileged[0], !seen.contains(0) {
            out.append(ProcInfo(pid: 0, name: "kernel_task", path: "", footprint: k.mem, cpu: k.cpu))
        }
        prev = nextPrev
        paths = paths.filter { seen.contains($0.key) }
        privileged = privileged.filter { $0.key == 0 || seen.contains($0.key) }
        return out
    }

    func group(_ procs: [ProcInfo]) -> [AppGroup] {
        var groups: [String: AppGroup] = [:]
        for p in procs {
            let bundle = Self.outermostBundle(p.path)
            let key = bundle ?? p.name
            var g = groups[key] ?? AppGroup(id: key, name: bundle.map(bundleName) ?? p.name, bundlePath: bundle)
            g.footprint += p.footprint
            g.cpu += p.cpu
            g.count += 1
            groups[key] = g
        }
        return Array(groups.values)
    }

    private func path(_ pid: Int32, start: UInt64) -> String {
        if let c = paths[pid], c.start == start { return c.path }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        let path = len > 0 ? String(cString: buf) : ""
        paths[pid] = (start, path)
        return path
    }

    private static func name(_ pid: Int32, path: String) -> String {
        if !path.isEmpty { return (path as NSString).lastPathComponent }
        var buf = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buf, UInt32(buf.count))
        let s = String(cString: buf)
        return s.isEmpty ? "pid \(pid)" : s
    }

    /// Chrome's renderers live in Google Chrome.app/…/Helpers/…Helper.app;
    /// the first ".app/" in the path is the app the user actually launched.
    static func outermostBundle(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    private func bundleName(_ bundlePath: String) -> String {
        if let n = bundleNames[bundlePath] { return n }
        let info = Bundle(path: bundlePath)?.localizedInfoDictionary ?? [:]
        let base = Bundle(path: bundlePath)?.infoDictionary ?? [:]
        let n = (info["CFBundleDisplayName"] ?? base["CFBundleDisplayName"] ?? info["CFBundleName"] ?? base["CFBundleName"]) as? String
        let name = (n?.isEmpty == false ? n! : ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension)
        bundleNames[bundlePath] = name
        return name
    }
}

/// Runs the system `top` (setuid root) to see processes we may not inspect.
/// One snapshot costs ~0.6 s of CPU, so it only runs while the window is on
/// screen, every 10 s. Runs are finite (-l 60) so a crash of this app can't
/// leave an orphaned `top` sampling forever; it is restarted when it ends.
final class TopFeed {
    var onSnapshot: (([Int32: TopRow]) -> Void)?
    private var process: Process?
    private var wanted = false
    private var buffer = Data()
    private var batch: [Int32: TopRow]?
    private let lock = NSLock()

    func start() {
        lock.lock(); defer { lock.unlock() }
        wanted = true
        guard process == nil else { return }
        launch()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        wanted = false
        process?.terminate()
        process = nil
    }

    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        p.arguments = ["-l", "60", "-s", "10", "-stats", "pid,mem,cpu,command"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        buffer = Data()
        batch = nil
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(d)
        }
        p.terminationHandler = { [weak self] ended in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.process === ended else { return }
            self.process = nil
            if self.wanted { self.launch() }
        }
        do {
            try p.run()
            process = p
        } catch {
            process = nil
        }
    }

    private func consume(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
        // A sample has no end marker; waiting for the next header would make
        // every number 10 s old. Hand over what we have whenever the pipe
        // drains — the receiver merges, so a partial batch loses nothing.
        if buffer.isEmpty, let b = batch, !b.isEmpty { onSnapshot?(b) }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("Processes:") {
            batch = nil
            return
        }
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        if f.first == "PID" { batch = [:]; return }
        guard batch != nil, f.count >= 4, let pid = Int32(f[0]),
              let mem = Self.bytes(f[1]), let cpu = Double(f[2]) else { return }
        batch?[pid] = TopRow(mem: mem, cpu: cpu, command: f[3...].joined(separator: " "))
    }

    /// "2886M+", "8128K-", "1.5G", "512B" → bytes.
    static func bytes<S: StringProtocol>(_ s: S) -> UInt64? {
        var t = String(s)
        while let c = t.last, c == "+" || c == "-" { t.removeLast() }
        guard let unit = t.last else { return nil }
        let mult: Double
        switch unit {
        case "B": mult = 1
        case "K": mult = 1024
        case "M": mult = 1024 * 1024
        case "G": mult = 1024 * 1024 * 1024
        default: return Double(t).map { UInt64($0) }
        }
        return Double(t.dropLast()).map { UInt64($0 * mult) }
    }
}
