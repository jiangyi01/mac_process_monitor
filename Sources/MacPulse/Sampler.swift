import Darwin
import Foundation

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: return "正常"
        case .warning: return "偏高"
        case .critical: return "严重"
        }
    }
}

struct SystemSample {
    var date = Date()
    var cpuUser: Double = 0          // 0...1 across all cores
    var cpuSystem: Double = 0
    var memTotal: UInt64 = 0
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0
    var pressure = MemoryPressure.normal
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var load: [Double] = [0, 0, 0]
    var thermal = ProcessInfo.ThermalState.nominal
    var netIn: Double = 0            // bytes/s
    var netOut: Double = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var bootTime = Date()

    var cpu: Double { cpuUser + cpuSystem }
    /// Same definition as Activity Monitor's "Memory Used".
    var memUsed: UInt64 { memApp + memWired + memCompressed }
    var memFraction: Double { memTotal == 0 ? 0 : Double(memUsed) / Double(memTotal) }
}

enum Machine {
    static let cores = ProcessInfo.processInfo.processorCount
    static let memory = ProcessInfo.processInfo.physicalMemory
    static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let s = String(cString: buf)
        return s.isEmpty ? "Mac" : s
    }()
}

func sysctlValue<T>(_ name: String, _ initial: T) -> T? {
    var v = initial
    var size = MemoryLayout<T>.size
    let rc = withUnsafeMutableBytes(of: &v) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
    return rc == 0 ? v : nil
}

/// System-wide counters. Everything here is readable without privileges.
/// Not thread-safe: call from one queue.
final class SystemSampler: @unchecked Sendable {
    // mach_host_self() hands out a new send right on every call; keep one.
    private let host = mach_host_self()
    private let pageSize = UInt64(vm_kernel_page_size)
    private var lastTicks: [UInt32]?
    private var lastNet: [String: (UInt32, UInt32)] = [:]
    private var lastNetTime: Date?

    func sample() -> SystemSample {
        var s = SystemSample()
        s.memTotal = Machine.memory
        readCPU(&s)
        readMemory(&s)
        if let sw = sysctlValue("vm.swapusage", xsw_usage()) {
            s.swapUsed = sw.xsu_used
            s.swapTotal = sw.xsu_total
        }
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { s.load = load }
        s.thermal = ProcessInfo.processInfo.thermalState
        readNetwork(&s)
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ]) {
            s.diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
            s.diskTotal = Int64(v.volumeTotalCapacity ?? 0)
        }
        if let tv = sysctlValue("kern.boottime", timeval()) {
            s.bootTime = Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
        }
        return s
    }

    private func readCPU(_ s: inout SystemSample) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let t = info.cpu_ticks
        let ticks = [t.0, t.1, t.2, t.3]   // user, system, idle, nice
        defer { lastTicks = ticks }
        guard let last = lastTicks else { return }
        // 32-bit tick counters wrap after a few weeks of uptime.
        let d = zip(ticks, last).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        guard total > 0 else { return }
        s.cpuUser = (d[0] + d[3]) / total
        s.cpuSystem = d[1] / total
    }

    private func readMemory(_ s: inout SystemSample) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let anon = UInt64(vm.internal_page_count)
        let purgeable = UInt64(vm.purgeable_count)
        s.memApp = (anon > purgeable ? anon - purgeable : 0) * pageSize
        s.memWired = UInt64(vm.wire_count) * pageSize
        s.memCompressed = UInt64(vm.compressor_page_count) * pageSize
        s.memCached = (UInt64(vm.external_page_count) + purgeable) * pageSize
        if let level = sysctlValue("kern.memorystatus_vm_pressure_level", Int32(1)) {
            s.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
    }

    private func readNetwork(_ s: inout SystemSample) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return }
        defer { freeifaddrs(ifap) }
        var current: [String: (UInt32, UInt32)] = [:]
        var p = ifap
        while let ifa = p?.pointee {
            p = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.ifa_data else { continue }
            // Physical interfaces only: VPN tunnels (utun) carry the same
            // bytes a second time.
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (d.ifi_ibytes, d.ifi_obytes)
        }
        let now = Date()
        defer { lastNet = current; lastNetTime = now }
        guard let lastTime = lastNetTime else { return }
        let dt = now.timeIntervalSince(lastTime)
        guard dt > 0 else { return }
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        for (name, v) in current {
            guard let o = lastNet[name] else { continue }
            // if_data counters are 32-bit and wrap every 4 GB.
            inBytes += UInt64(v.0 &- o.0)
            outBytes += UInt64(v.1 &- o.1)
        }
        s.netIn = Double(inBytes) / dt
        s.netOut = Double(outBytes) / dt
    }
}
