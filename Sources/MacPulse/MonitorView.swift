import AppKit
import Charts
import SwiftUI

struct MonitorView: View {
    @ObservedObject var monitor: Monitor
    @State private var mode = Mode.apps
    @State private var sort = Sort.memory
    @State private var query = ""
    @State private var hoveredRow: String?
    @State private var confirmQuit: AppGroup?

    enum Mode: String, CaseIterable { case apps = "按应用", processes = "按进程" }
    enum Sort { case memory, cpu }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let s = monitor.sample {
                header(s)
                Divider()
                tiles(s).padding(14)
                historyChart.padding(.horizontal, 14).padding(.bottom, 10)
                adviceList
                Divider()
                listControls
                Divider()
                list(s)
            } else {
                ProgressView("正在采样…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 640)
        .alert(item: $confirmQuit) { app in
            Alert(
                title: Text("退出 \(app.name)？"),
                message: Text("会像按 ⌘Q 一样正常退出，有未保存的内容时应用会提示你。"),
                primaryButton: .destructive(Text("退出")) { quit(app) },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    // MARK: - Header

    private func header(_ s: SystemSample) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Machine.chip).font(.headline)
                Text("\(Machine.cores) 核 · \(Fmt.bytes(Machine.memory)) 内存 · 已开机 \(Fmt.uptime(s.bootTime, now: s.date))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            thermalBadge(s.thermal)
        }
        .padding(14)
    }

    private func thermalBadge(_ t: ProcessInfo.ThermalState) -> some View {
        let (label, color): (String, Color) = switch t {
        case .nominal: ("温度正常", .green)
        case .fair: ("温度偏高", .yellow)
        case .serious: ("过热降频", .orange)
        case .critical: ("严重过热", .red)
        @unknown default: ("温度未知", .secondary)
        }
        return Label(label, systemImage: "thermometer.medium")
            .font(.caption)
            .foregroundStyle(color)
    }

    // MARK: - Tiles

    private func tiles(_ s: SystemSample) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
        return LazyVGrid(columns: cols, spacing: 10) {
            tile("CPU", Fmt.percent(s.cpu),
                 "用户 \(Fmt.percent(s.cpuUser)) · 系统 \(Fmt.percent(s.cpuSystem))") {
                sparkline(\.cpu, color: .blue)
            }
            tile("内存", "\(Fmt.bytes(s.memUsed))",
                 "共 \(Fmt.bytes(s.memTotal)) · 压力\(s.pressure.label)",
                 detailColor: pressureColor(s.pressure)) {
                memoryBar(s)
            }
            tile("交换空间", Fmt.bytes(s.swapUsed),
                 s.swapTotal > 0 ? "共 \(Fmt.bytes(s.swapTotal))" : "未使用",
                 valueColor: s.swapUsed >= 2 << 30 ? .orange : nil)
            tile("负载", String(format: "%.2f", s.load[0]),
                 String(format: "5 分 %.2f · 15 分 %.2f", s.load[1], s.load[2]),
                 valueColor: s.load[0] > Double(Machine.cores) ? .orange : nil)
            tile("网络", "↓ \(Fmt.rate(s.netIn))", "↑ \(Fmt.rate(s.netOut))")
            tile("磁盘可用", Fmt.bytes(UInt64(max(s.diskFree, 0))),
                 "共 \(Fmt.bytes(UInt64(max(s.diskTotal, 0))))")
        }
    }

    private func tile<Extra: View>(
        _ title: String, _ value: String, _ detail: String,
        valueColor: Color? = nil, detailColor: Color? = nil,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(valueColor ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).font(.caption2.monospacedDigit())
                .foregroundStyle(detailColor ?? .secondary)
                .lineLimit(1)
            extra()
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sparkline(_ key: KeyPath<HistoryPoint, Double>, color: Color) -> some View {
        Chart(monitor.history) { p in
            AreaMark(x: .value("时间", p.date), y: .value("值", p[keyPath: key]))
                .foregroundStyle(color.opacity(0.18))
            LineMark(x: .value("时间", p.date), y: .value("值", p[keyPath: key]))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 16)
    }

    /// App / wired / compressed, the same split Activity Monitor uses.
    private func memoryBar(_ s: SystemSample) -> some View {
        let total = Double(max(s.memTotal, 1))
        let parts: [(String, UInt64, Color)] = [
            ("应用", s.memApp, .blue), ("联动", s.memWired, .orange), ("压缩", s.memCompressed, .purple),
        ]
        return GeometryReader { g in
            HStack(spacing: 1) {
                ForEach(parts, id: \.0) { p in
                    Rectangle().fill(p.2)
                        .frame(width: max(0, g.size.width * Double(p.1) / total - 1))
                        .help("\(p.0) \(Fmt.bytes(p.1))")
                }
                Spacer(minLength: 0)
            }
            .background(Color.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
        .frame(height: 6)
        .padding(.top, 5)
    }

    private func pressureColor(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    // MARK: - History

    private var historyChart: some View {
        Chart {
            ForEach(monitor.history) { p in
                LineMark(x: .value("时间", p.date), y: .value("占用", p.cpu))
                    .foregroundStyle(by: .value("指标", "CPU"))
                LineMark(x: .value("时间", p.date), y: .value("占用", p.mem))
                    .foregroundStyle(by: .value("指标", "内存"))
            }
        }
        .chartForegroundStyleScale(["CPU": Color.blue, "内存": Color.purple])
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { v in
                AxisGridLine()
                AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%").font(.system(size: 9)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                    .font(.system(size: 9))
            }
        }
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 100)
    }

    // MARK: - Advice

    @ViewBuilder
    private var adviceList: some View {
        let items = monitor.advice
        VStack(alignment: .leading, spacing: 5) {
            if items.isEmpty {
                Label("一切正常", systemImage: "checkmark.circle").foregroundStyle(.green)
            } else {
                ForEach(items) { a in
                    Label {
                        Text(a.text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: a.symbol).foregroundStyle(color(a.level))
                    }
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private func color(_ l: Advice.Level) -> Color {
        switch l {
        case .info: return .secondary
        case .warn: return .orange
        case .alert: return .red
        }
    }

    // MARK: - List

    private var listControls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: mode) { hoveredRow = nil }
            TextField("搜索", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
            Spacer()
            if !monitor.hasPrivileged {
                Text("系统进程读取中…").font(.caption).foregroundStyle(.tertiary)
            }
            sortButton("内存", .memory, width: 150)
            sortButton("CPU", .cpu, width: 56)
            Color.clear.frame(width: 18, height: 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func sortButton(_ title: String, _ s: Sort, width: CGFloat) -> some View {
        Button {
            sort = s
        } label: {
            HStack(spacing: 2) {
                Spacer(minLength: 0)
                Text(title)
                if sort == s { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .font(.caption.weight(sort == s ? .semibold : .regular))
            .foregroundStyle(sort == s ? .primary : .secondary)
            .frame(width: width, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)排序")
    }

    private struct Row: Identifiable {
        let id: String
        let name: String
        let subtitle: String?
        let footprint: UInt64
        let cpu: Double
        let bundlePath: String?
        let app: AppGroup?
    }

    private var rows: [Row] {
        var rows: [Row]
        switch mode {
        case .apps:
            rows = monitor.apps.map {
                Row(id: "a:" + $0.id, name: $0.name, subtitle: $0.count > 1 ? "\($0.count) 个进程" : nil,
                    footprint: $0.footprint, cpu: $0.cpu, bundlePath: $0.bundlePath, app: $0)
            }
        case .processes:
            rows = monitor.processes.map {
                Row(id: "p:\($0.pid)", name: $0.name, subtitle: "PID \($0.pid)",
                    footprint: $0.footprint, cpu: $0.cpu,
                    bundlePath: ProcessScanner.outermostBundle($0.path), app: nil)
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { rows = rows.filter { $0.name.localizedCaseInsensitiveContains(q) } }
        switch sort {
        case .memory: rows.sort { ($0.footprint, $0.cpu) > ($1.footprint, $1.cpu) }
        case .cpu: rows.sort { ($0.cpu, $0.footprint) > ($1.cpu, $1.footprint) }
        }
        return Array(rows.prefix(200))
    }

    private func list(_ s: SystemSample) -> some View {
        let rows = self.rows
        let total = Double(max(s.memTotal, 1))
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { r in row(r, total: total) }
            }
            .padding(.vertical, 4)
        }
        .id(mode)
        .overlay {
            if monitor.processes.isEmpty {
                ProgressView().controlSize(.small)
            } else if rows.isEmpty {
                Text("没有匹配的\(mode == .apps ? "应用" : "进程")").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ r: Row, total: Double) -> some View {
        let hovered = hoveredRow == r.id
        // Only the hovered row asks NSWorkspace; 200 rows every 2 s would not.
        let quittable = hovered && r.app.flatMap(runningApp) != nil
        return HStack(spacing: 8) {
            AppIcon(bundlePath: r.bundlePath).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(r.name).lineLimit(1).truncationMode(.middle)
                if let sub = r.subtitle {
                    Text(sub).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.07))
                        Capsule().fill(memColor(r.footprint))
                            .frame(width: max(2, g.size.width * min(1, Double(r.footprint) / total * 4)))
                    }
                }
                .frame(width: 70, height: 5)
                .help("占总内存 \(String(format: "%.1f%%", Double(r.footprint) / total * 100))")
                Text(Fmt.bytes(r.footprint))
                    .font(.callout.monospacedDigit())
                    .frame(width: 74, alignment: .trailing)
            }
            .frame(width: 150, alignment: .trailing)
            Text(String(format: "%.1f", r.cpu))
                .font(.callout.monospacedDigit())
                .foregroundStyle(r.cpu >= 50 ? Color.orange : r.cpu >= 1 ? Color.primary : Color.secondary)
                .frame(width: 56, alignment: .trailing)
            Group {
                if hovered && quittable, let app = r.app {
                    Button { confirmQuit = app } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("退出 \(r.name)")
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: 18)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .background(hovered ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hoveredRow = r.id } else if hoveredRow == r.id { hoveredRow = nil }
        }
    }

    /// The bar is scaled ×4 so a 3 GB app on a 24 GB Mac reads as half full
    /// instead of a sliver; color carries the absolute size.
    private func memColor(_ b: UInt64) -> Color {
        let gb = Double(b) / Double(1 << 30)
        if gb >= 3 { return .red }
        if gb >= 1 { return .orange }
        return .accentColor
    }

    private func runningApp(_ g: AppGroup) -> NSRunningApplication? {
        guard let path = g.bundlePath else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.path == path && $0.activationPolicy == .regular
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    private func quit(_ g: AppGroup) {
        runningApp(g)?.terminate()
    }
}

/// Icons are looked up once per bundle; NSWorkspace hits the disk.
struct AppIcon: View {
    let bundlePath: String?
    @MainActor private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let path = bundlePath {
            Image(nsImage: Self.icon(path)).resizable().interpolation(.high)
        } else {
            Image(systemName: "gearshape").foregroundStyle(.tertiary)
        }
    }

    @MainActor private static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        cache[path] = i
        return i
    }
}
