# MenuPulse 项目协作规范

## 适用范围

本文件适用于仓库根目录及其全部子目录。后续修改、优化、审查和测试均以本文件为项目级约定。

## 沟通约定

- 使用中文说明思路、改动、验证结果和风险。
- 所有回复以“zhz”开头。
- 先给结论，再补充必要的实现细节。

## 项目定位

- 原生 macOS 菜单栏系统监控应用，最低系统版本为 macOS 15.1。
- 使用 Swift 5、AppKit、Foundation 和 Darwin，不含第三方依赖或 SwiftUI 常驻层。
- 应用以 accessory 模式运行，不提供普通主窗口；单个紧凑宽度菜单栏项展示网络速度和 CPU 占用。
- 仓库目录名仍为 `zhz-app`，但工程、方案和产物均已更名为 `MenuPulse`。
- 主方案为 `MenuPulse`，包含 `MenuPulse` 和 `MenuPulseTests` 两个目标；没有 UI 测试目标。

## 代码地图

- `MenuPulse/SystemMetrics.swift`
  - `SystemSampler`：在串行后台队列通过 `NET_RT_IFLIST2` 读取 `en*` 的 64 位链路层流量，并读取主机 CPU tick。
  - `MetricsMath`：按真实经过时间计算速率，并处理 CPU 计数器回绕。
  - `MetricsFormatter`：生成紧凑双行状态栏文本，是纯函数并由单元测试覆盖。
- `MenuPulse/MenuPulseApp.swift`
  - `ApplicationMain`：纯 AppKit 入口，避免 SwiftUI 菜单栏应用的持续渲染开销。
  - `AppDelegate`：维护单个 `NSStatusItem`、退出菜单和一个带余量的 `DispatchSourceTimer`。
  - 统一协调状态项可见性、屏幕休眠、会话状态和系统睡眠；仅在状态项可见且没有暂停原因时采集。
- `MenuPulse.xcodeproj/project.pbxproj`：自动生成主 Info.plist，并通过 `INFOPLIST_KEY_LSUIElement = YES` 声明菜单栏应用。
- `MenuPulse/MenuPulse.entitlements`：仅启用 App Sandbox，未额外声明其他权限。
- `MenuPulseTests`：覆盖网络速率、计数器重置、CPU 差值与回绕、文本格式等纯计算逻辑。

## CodeGraph 工作流

- 项目已经初始化 `.codegraph/`；理解源码、定位符号、查引用和评估影响时优先使用 CodeGraph。
- 查询时传入项目根目录：`/Users/zhz/code/MacOs/zhz-app`。
- CodeGraph 已返回的源码视为已经读取，不要再用其他工具重复读取同一段源码。
- 修改源码后执行 `codegraph sync .` 更新增量索引；索引异常或大规模重构后才执行 `codegraph index .`。
- `.codegraph` 数据库由目录内的 `.gitignore` 排除，不要提交数据库、WAL 或共享内存文件。

## 修改原则

- 默认做最小改动，优先在现有文件和函数内完成需求。
- 不为未来可能的复用提前新增抽象、文件或依赖；确需新增时，先说明原因和影响并取得确认。
- 不覆盖或回退用户已有的未提交改动，修改前后都要检查 Git 变更范围。
- 保持菜单栏应用形态；除非需求明确，不新增 Dock 图标、主窗口或额外菜单栏项。
- 不无故修改 bundle identifier、部署目标、签名权限、沙箱权限或 Xcode 工程结构。
- UI 状态更新必须在主线程完成；定时器和 Mach 内存必须成对清理，避免循环引用、重复释放和泄漏。
- 涉及网络计数器时，应考虑实际采样间隔、计数器回绕、接口重置以及多接口累加溢出。
- 网络流量必须读取 `if_data64`；不得回退到约 4 GiB 即回绕的 `if_data` 32 位字节计数器。
- `SystemSampler` 只能从专用串行采集队列调用；不要为它增加锁或在主线程执行系统采集。
- 保持一个状态栏项和一个采集定时器；新增周期任务前必须证明无法合并，并设置合理余量。
- 只处理本次需求涉及的问题；发现其他风险时单独标注，不擅自扩大改动范围。

## 构建与验证

- Apple 平台工程优先使用项目可用的 Xcode MCP；不可用时再使用 `xcodebuild`。
- 核对工程结构：
  - `xcodebuild -list -project MenuPulse.xcodeproj`
- Debug 构建：
  - `xcodebuild -project MenuPulse.xcodeproj -scheme MenuPulse -configuration Debug -destination 'platform=macOS' build`
- 运行测试：
  - `xcodebuild -project MenuPulse.xcodeproj -scheme MenuPulse -destination 'platform=macOS' test`
- 构建和测试输出应先聚合，只报告成功状态、失败用例、关键错误和必要警告。
- 改动系统指标计算时，优先补充可重复的纯计算测试；如果需要为可测试性新增协议或注入层，先说明再实施。
- Release 常驻性能回归基线：本机 macOS 26.6.1 上 40 秒平均 CPU 约 0.50%、内存约 16MB；相关改动不得明显劣化该基线。

## 当前已知风险

- 流量统计只包含 `en*` 链路层接口，不包含回环、隧道和虚拟网卡；改变统计口径前应先确认产品需求。
- 系统调用和休眠恢复流程已有纯计算测试，但仍需在不同硬件和 macOS 版本上做集成与能耗验证。
- AppIcon 已提供 16–1024 像素完整尺寸；调整生成工具或资源映射后需重新检查资产目录警告。
- 没有 UI 测试目标，菜单栏交互、状态项绘制和系统通知响应没有自动化回归保护；这些逻辑只能靠单元测试覆盖纯计算部分，其余以手动集成验证为准。
