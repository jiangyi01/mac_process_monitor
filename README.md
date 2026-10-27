# Mac Pulse

English | [中文](README.zh-CN.md)

A lightweight performance monitor for macOS that lives in the **Dock** and the **menu bar**. It answers "why is my Mac slow?" at a glance: CPU, memory pressure, swap, and which apps are holding the memory.

> The interface is currently in Chinese.

## Features

- **Menu bar item**: shows CPU and memory usage as percentages. The memory figure turns orange when memory pressure is elevated and red when it is critical. Left-click opens a compact popover with the key numbers, top advice, and the 6 apps using the most memory; right-click opens a menu.
- **Live Dock icon**: draws CPU and memory bars, with the memory bar colored by memory pressure. Click it to open the full window.
- **Full window**:
  - Six tiles: CPU (user / system), memory (app / wired / compressed, same split as Activity Monitor), swap, load average, network throughput, free disk space, plus the thermal state.
  - CPU and memory history for the last 5 minutes.
  - Automatic advice: high memory pressure, heavy swap use, long uptime, system services that look like memory leaks (e.g. a system process holding several GB), overheating, low disk space.
  - Per-app or per-process list, sortable by memory or CPU, with search. Helper processes are summed into their app (all of Chrome's renderers count as Chrome). Hover an app to quit it gracefully, the same as ⌘Q, after a confirmation.

## Low overhead

- System-wide counters are read every 2 s (microseconds of work) to update the menu bar and Dock.
- The per-process scan runs only while the window or the popover is on screen.
- Processes owned by root or system users (WindowServer, kernel_task, …) can't be inspected without privileges, so their numbers come from the system's setuid `top`, every 10 s, also only while the window or popover is visible. Each `top` run is finite, so a crash can't leave an orphaned sampler behind.
- `build_app.sh` compiles at low priority (`nice -n 10`, `-j 4`) so a rebuild doesn't slow down the Mac it monitors.

## Requirements

- macOS 14 or later (developed on macOS 26, Apple Silicon)
- Command Line Tools for Xcode (`xcode-select --install`); the full Xcode is **not** required

## Build and install

```bash
git clone https://github.com/jiangyi01/mac_process_monitor.git
cd mac_process_monitor
./build_app.sh --run
```

This builds a release binary with SwiftPM, bundles it into `~/Applications/MacPulse.app`, signs it ad hoc, and launches it. To keep it in the Dock, right-click its Dock icon and choose **Options ▸ Keep in Dock**. To start it at login, add it under **System Settings ▸ General ▸ Login Items**.

Other commands:

```bash
swift tools/make_icon.swift                           # regenerate Resources/AppIcon.icns
.build/release/MacPulse --snapshot out.png [--dark]   # render the window, Dock icon and popover to PNGs offline
```

## How the numbers are measured

| Metric | Source |
|---|---|
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)` tick deltas |
| Memory used | `host_statistics64(HOST_VM_INFO64)`: app (internal − purgeable) + wired + compressed |
| Memory pressure | `sysctl kern.memorystatus_vm_pressure_level` |
| Swap | `sysctl vm.swapusage` |
| Network | `getifaddrs` byte counters on physical `en*` interfaces |
| Per-process memory / CPU | `proc_pid_rusage` (physical footprint, CPU time); `top` for privileged processes |

## License

[MIT](LICENSE)
