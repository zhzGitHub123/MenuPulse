[English](README.md) | **简体中文**

# MenuPulse

一个极简的 macOS 菜单栏监控工具，在状态栏实时显示**网络上下行速度**和 **CPU 占用率**。

```
↑1.2M  CPU
↓15.3M  23%
```

两行等宽字体紧凑排布，只占一小块菜单栏空间。没有主窗口，没有 Dock 图标，装上就忘掉它的存在。

## 特性

- **双指标一屏** — 上传/下载速度与 CPU 占用同时显示，无需点开任何面板
- **自动省电** — 屏幕休眠、用户会话切换、系统睡眠时自动暂停采样，唤醒后恢复
- **闲置节流** — 网络静默且 CPU 空闲时自动拉长采样间隔，减少常驻唤醒
- **自适应外观** — 状态栏图标以 template image 渲染，自动跟随深色/浅色菜单栏
- **宽度自适应** — 数值变长变短时状态栏宽度平滑调整，不会来回抖动
- **无障碍支持** — 为 VoiceOver 提供完整的朗读标签
- **零依赖** — 纯 AppKit 实现，不引入任何第三方库
- **沙盒运行** — 开启 App Sandbox，只申请必要权限

## 系统要求

- macOS 15.1 或更高版本
- 从源码构建需要 Xcode 16 或更高版本

## 安装

### 下载预编译版本

从 [最新 Release](https://github.com/zhzGitHub123/MenuPulse/releases/latest) 下载 `MenuPulse.zip`，解压后把 `MenuPulse.app` 拖进「应用程序」文件夹。

该应用**未经 Apple 公证**，因此首次打开时 macOS 会拒绝启动，提示「无法验证开发者」或「已损坏」。这并非软件损坏，只是没有加入 Apple Developer Program。执行一次下面的命令清除隔离标记即可正常运行：

```bash
xattr -cr /Applications/MenuPulse.app
```

如果你不愿意运行未签名的二进制，源码就在这里，可以自行构建。

### 用 Xcode 构建

```bash
open MenuPulse.xcodeproj
```

选择 `MenuPulse` scheme，按 ⌘R 运行。

### 用命令行构建

```bash
xcodebuild -project MenuPulse.xcodeproj -scheme MenuPulse -configuration Release -derivedDataPath DerivedData build
```

产物位于 `DerivedData/Build/Products/Release/MenuPulse.app`，拖进「应用程序」文件夹即可。

## 使用

启动后应用直接常驻菜单栏，**不会出现在 Dock 或 ⌘Tab 切换器中**（使用 `.accessory` 激活策略）。

点击状态栏项目弹出菜单，目前只有一项：

| 菜单项 | 快捷键 |
| --- | --- |
| 退出 | ⌘Q |

## 实现说明

### 数据采集

| 指标 | 来源 |
| --- | --- |
| 网络速度 | `sysctl` 读取网络接口字节计数器，对相邻两次采样求差分 |
| CPU 占用 | `host_statistics(HOST_CPU_LOAD_INFO)` 读取 tick 计数，按 user/system/nice/idle 增量计算 |

两者都是**增量计算**而非瞬时值，因此首次采样不产生输出，从第二次开始才有数据。

时间差用 `ProcessInfo.systemUptime` 计算，而非墙上时钟，因此用户调整系统时间或时区不会导致速度值异常。

计数器回绕的处理方式两者不同：

- **CPU** —— tick 类型是 32 位的 `natural_t`，回绕后按 `UInt32.max` 补正差值，结果依然可用
- **网络** —— 检测到计数器回退即判定该次采样不可信，**直接丢弃**，等下一个周期重新计算

### 采样策略

- 基础采样周期 **2 秒**，允许 **400ms** 的 leeway 让系统合并唤醒，降低功耗
- 当上下行均低于 **1KB/s** 且 CPU 低于 **10%** 并连续 **5 次**成立时，切换到更长的闲置节奏并放宽 leeway；一旦出现活跃立即清零，下次采样即恢复高频
- 采样在独立的 `utility` QoS 队列上执行，不阻塞主线程
- 仅在标题实际变化时才重绘状态栏，避免无谓的 UI 刷新

### 暂停条件

监控状态由两个因素共同决定：状态栏项目是否可见，以及是否存在任一暂停原因。暂停原因以 `OptionSet` 表示，可以叠加：

| 原因 | 触发通知 |
| --- | --- |
| 屏幕休眠 | `screensDidSleepNotification` |
| 会话失活 | `sessionDidResignActiveNotification` |
| 系统睡眠 | `willSleepNotification` |

三者全部解除且状态栏可见时才恢复采样。重启采样时会递增 generation 计数，丢弃上一轮遗留的回调结果，避免竞态导致的过期数据上屏。

## 工具脚本

`Tools/GenerateAppIcon.swift` 用于生成全尺寸 App 图标资源。

## 许可证

[MIT](LICENSE) © 2026 zhzGitHub123
