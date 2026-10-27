# Mac Pulse

[English](README.md) | 中文

Dock 和菜单栏里的性能监视器。

- **菜单栏**：显示 CPU 和内存占用百分比，内存压力偏高时变橙、严重时变红。左键点开小弹窗（关键数字、建议、最占内存的 6 个应用），右键是菜单。
- **Dock 图标**：实时显示 CPU 和内存两根条（内存条颜色表示内存压力），点图标打开完整窗口：

- 6 个指标：CPU、内存（应用 / 联动 / 压缩）、交换空间、负载、网络、磁盘，另有温度状态
- 最近 5 分钟的 CPU 和内存曲线
- 自动建议：内存压力、交换空间、太久没重启、疑似泄漏的系统进程、过热、磁盘快满
- 按应用或按进程排序（内存 / CPU）、搜索；鼠标悬停在应用上可以正常退出它（和 ⌘Q 一样）

## 省电

- 每 2 秒读一次系统总数（只要几微秒），用来更新菜单栏和 Dock。
- 逐个进程的扫描只在窗口或菜单栏弹窗打开时运行。
- root 和系统用户的进程（WindowServer、kernel_task 等）读不了，改用系统自带的 `top` 读取，每 10 秒一次，同样只在窗口或弹窗可见时运行。

## 构建

```bash
./build_app.sh --run        # 构建并安装到 ~/Applications/MacPulse.app
swift tools/make_icon.swift # 重新生成图标
.build/release/MacPulse --snapshot out.png [--dark]   # 离线渲染窗口、Dock 图标和菜单栏弹窗
```

只需要 Command Line Tools，不需要 Xcode。
