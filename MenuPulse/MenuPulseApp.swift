//
//  MenuPulseApp.swift
//  MenuPulse
//

import AppKit
import Foundation

private enum AppConfiguration {
    static let minimumStatusItemWidth: CGFloat = 50
    static let statusImageHeight: CGFloat = 20
    static let imageHorizontalPadding: CGFloat = 4
    /// 速度列与 CPU 列之间的间距。等宽字体下一个空格约 5pt，这里按点数给，
    /// 才能调到比一个字符更窄。
    static let columnSpacing: CGFloat = 4
    static let buttonHorizontalPadding: CGFloat = 6
    /// 采样周期。每次刷新状态项的固定成本约 10.4 ms CPU，远高于采样本身的 0.7 ms，
    /// 因此周期长度直接决定常驻能耗；3 秒是在读数跟手感与耗电之间取的平衡点。
    static let samplingInterval: DispatchTimeInterval = .seconds(3)
    static let samplingLeeway: DispatchTimeInterval = .milliseconds(600)
    /// 闲置时的采样节奏：更长的间隔配更大的余量，便于系统合并唤醒。
    static let idleSamplingInterval: DispatchTimeInterval = .seconds(8)
    static let idleSamplingLeeway: DispatchTimeInterval = .seconds(2)
}

struct MonitoringSuspensionReasons: OptionSet, Sendable {
    let rawValue: UInt8

    static let screenSleeping = Self(rawValue: 0b001)
    static let sessionInactive = Self(rawValue: 0b010)
    static let systemSleeping = Self(rawValue: 0b100)
}

enum MonitoringPolicy {
    static func shouldMonitor(
        statusItemIsVisible: Bool,
        suspensionReasons: MonitoringSuspensionReasons
    ) -> Bool {
        statusItemIsVisible && suspensionReasons.isEmpty
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let sampler = SystemSampler()
    private let statusTextAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular),
        .foregroundColor: NSColor.black
    ]
    private let samplingQueue = DispatchQueue(
        label: "io.github.zhzgithub123.MenuPulse.metrics",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    private var statusItem: NSStatusItem?
    private var samplingTimer: DispatchSourceTimer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var visibilityObservation: NSKeyValueObservation?
    private var monitoringGeneration = 0
    private var lastTitle = ""
    private var suspensionReasons: MonitoringSuspensionReasons = []
    private var idleStreak = 0
    private var isUsingIdleCadence = false
    /// 当前显示在菜单栏上的那次采样，作为判断后续变化是否值得刷新的基准。
    private var displayedMetrics: SystemMetrics?
    private var suppressedUpdates = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerWorkspaceObservers()
        observeStatusItemVisibility()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopMonitoring()
        visibilityObservation?.invalidate()
        visibilityObservation = nil

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()

        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: fixedStatusItemLength)
        guard let button = item.button else { return }

        let initialMetrics = SystemMetrics(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            cpuUsage: 0
        )
        button.alignment = .center
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        let title = MetricsFormatter.statusTitle(initialMetrics)
        setStatusTitle(title, metrics: initialMetrics, on: button)
        button.toolTip = "实时网络速度与 CPU 占用（上行在上，下行在下）"

        item.menu = makeMenu()
        statusItem = item
        lastTitle = title
        displayedMetrics = initialMetrics
    }

    private func setStatusTitle(
        _ title: String,
        metrics: SystemMetrics,
        on button: NSButton
    ) {
        button.title = ""
        button.image = makeStatusImage(title)
        button.setAccessibilityLabel(MetricsFormatter.accessibilityLabel(metrics))
    }

    /// 两列各自的恒定宽度，按排版可能达到的最宽内容测量一次后缓存。
    ///
    /// 一次性算出宽度是刻意的：只要 `NSStatusItem.length` 不再变化，菜单栏就不会重排，
    /// 也不会向 ControlCenter 发送尺寸同步的 XPC 消息。
    private lazy var columnLayout: (left: CGFloat, right: CGFloat, imageWidth: CGFloat) = {
        let attributes = statusTextAttributes
        var left: CGFloat = 0
        var right: CGFloat = 0

        for line in MetricsFormatter.widestTitle.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let columns = MetricsFormatter.columns(of: line)
            left = max(left, (columns.left as NSString).size(withAttributes: attributes).width)
            right = max(right, (columns.right as NSString).size(withAttributes: attributes).width)
        }

        left = ceil(left)
        right = ceil(right)
        return (
            left,
            right,
            left + AppConfiguration.columnSpacing + right
                + AppConfiguration.imageHorizontalPadding
        )
    }()

    private func makeStatusImage(_ title: String) -> NSImage {
        let lines = title.split(separator: "\n", omittingEmptySubsequences: false)
        let attributes = statusTextAttributes
        let layout = columnLayout
        let imageSize = NSSize(
            width: layout.imageWidth,
            height: AppConfiguration.statusImageHeight
        )
        let contentOrigin = AppConfiguration.imageHorizontalPadding / 2
        let leftColumnEdge = contentOrigin + layout.left
        let rightColumnEdge = leftColumnEdge + AppConfiguration.columnSpacing + layout.right

        // 立即光栅化，而不是交给 NSImage 的 drawingHandler。
        //
        // drawingHandler 产生的是惰性的 NSCustomImageRep：AppKit 每次显示状态项都要回调
        // 重新绘制，并额外走一遍挑选最佳表示的通用路径。这里一次性画进位图，
        // 之后菜单栏拿到的就是现成的像素。
        let image = NSImage(size: imageSize)
        image.lockFocusFlipped(true)
        let lineHeight = imageSize.height / CGFloat(max(lines.count, 1))
        for (index, line) in lines.prefix(2).enumerated() {
            let columns = MetricsFormatter.columns(of: line)
            let lineTop = CGFloat(index) * lineHeight
            drawRightAligned(
                columns.left,
                rightEdge: leftColumnEdge,
                lineTop: lineTop,
                lineHeight: lineHeight,
                attributes: attributes
            )
            drawRightAligned(
                columns.right,
                rightEdge: rightColumnEdge,
                lineTop: lineTop,
                lineHeight: lineHeight,
                attributes: attributes
            )
        }
        image.unlockFocus()

        image.isTemplate = true
        return image
    }

    /// 两列都靠各自的右边缘对齐：速度的个位、CPU 的百分号因此始终停在同一条竖线上，
    /// 数值位数变化时读数不会左右横跳。
    private func drawRightAligned(
        _ text: String,
        rightEdge: CGFloat,
        lineTop: CGFloat,
        lineHeight: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard !text.isEmpty else { return }

        let content = text as NSString
        let size = content.size(withAttributes: attributes)
        let origin = NSPoint(
            x: floor(rightEdge - size.width),
            y: floor(lineTop + (lineHeight - size.height) / 2)
        )
        content.draw(at: origin, withAttributes: attributes)
    }

    private var fixedStatusItemLength: CGFloat {
        max(
            AppConfiguration.minimumStatusItemWidth,
            columnLayout.imageWidth + AppConfiguration.buttonHorizontalPadding
        )
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        menu.addItem(quitItem)
        return menu
    }

    private func startMonitoring() {
        guard samplingTimer == nil else { return }

        monitoringGeneration &+= 1
        let generation = monitoringGeneration
        samplingQueue.async { [sampler] in
            sampler.reset()
        }

        idleStreak = 0
        isUsingIdleCadence = false

        let timer = DispatchSource.makeTimerSource(queue: samplingQueue)
        timer.schedule(
            deadline: .now(),
            repeating: AppConfiguration.samplingInterval,
            leeway: AppConfiguration.samplingLeeway
        )
        timer.setEventHandler { [weak self] in
            guard let self,
                  let metrics = self.sampler.sample() else {
                return
            }

            let title = MetricsFormatter.statusTitle(metrics)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.monitoringGeneration == generation else {
                    return
                }

                self.applySample(title: title, metrics: metrics)
            }
        }

        samplingTimer = timer
        timer.activate()
    }

    private func stopMonitoring() {
        guard samplingTimer != nil else { return }

        monitoringGeneration &+= 1
        samplingTimer?.cancel()
        samplingTimer = nil
    }

    /// 在主线程消费一次采样：先按需刷新状态项，再决定下一段采样节奏。
    private func applySample(title: String, metrics: SystemMetrics) {
        if shouldRefreshDisplay(for: metrics) {
            if lastTitle != title,
               let button = statusItem?.button {
                setStatusTitle(title, metrics: metrics, on: button)
                lastTitle = title
            }
            displayedMetrics = metrics
            suppressedUpdates = 0
        } else {
            suppressedUpdates += 1
        }

        updateSamplingCadence(for: metrics)
    }

    /// 刷新状态项是常驻能耗的绝对大头，因此只有变化足够明显时才值得付这笔开销；
    /// 连续抑制到上限后强制放行一次，避免读数长期停在旧值上。
    private func shouldRefreshDisplay(for metrics: SystemMetrics) -> Bool {
        guard let displayedMetrics else { return true }
        guard suppressedUpdates < DisplayPolicy.maxSuppressedUpdates else { return true }
        return DisplayPolicy.isSignificantChange(from: displayedMetrics, to: metrics)
    }

    private func updateSamplingCadence(for metrics: SystemMetrics) {
        idleStreak = SamplingPolicy.nextIdleStreak(
            current: idleStreak,
            isIdle: SamplingPolicy.isIdle(metrics)
        )

        let useIdleCadence = SamplingPolicy.shouldUseIdleCadence(idleStreak: idleStreak)
        guard useIdleCadence != isUsingIdleCadence,
              let timer = samplingTimer else {
            return
        }

        isUsingIdleCadence = useIdleCadence
        let interval = useIdleCadence
            ? AppConfiguration.idleSamplingInterval
            : AppConfiguration.samplingInterval
        let leeway = useIdleCadence
            ? AppConfiguration.idleSamplingLeeway
            : AppConfiguration.samplingLeeway
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: leeway)
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let transitions: [(
            suspend: Notification.Name,
            resume: Notification.Name,
            reason: MonitoringSuspensionReasons
        )] = [
            (
                NSWorkspace.screensDidSleepNotification,
                NSWorkspace.screensDidWakeNotification,
                .screenSleeping
            ),
            (
                NSWorkspace.sessionDidResignActiveNotification,
                NSWorkspace.sessionDidBecomeActiveNotification,
                .sessionInactive
            ),
            (
                NSWorkspace.willSleepNotification,
                NSWorkspace.didWakeNotification,
                .systemSleeping
            )
        ]

        for transition in transitions {
            workspaceObservers.append(
                center.addObserver(
                    forName: transition.suspend,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.setSuspended(true, for: transition.reason)
                }
            )
            workspaceObservers.append(
                center.addObserver(
                    forName: transition.resume,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.setSuspended(false, for: transition.reason)
                }
            )
        }
    }

    private func setSuspended(
        _ suspended: Bool,
        for reason: MonitoringSuspensionReasons
    ) {
        if suspended {
            suspensionReasons.insert(reason)
        } else {
            suspensionReasons.remove(reason)
        }
        reconcileMonitoring()
    }

    private func reconcileMonitoring() {
        let shouldMonitor = MonitoringPolicy.shouldMonitor(
            statusItemIsVisible: statusItem?.isVisible == true,
            suspensionReasons: suspensionReasons
        )
        if shouldMonitor {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    private func observeStatusItemVisibility() {
        visibilityObservation = statusItem?.observe(\.isVisible, options: [.initial, .new]) {
            [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.reconcileMonitoring()
            }
        }
    }
}

@main
enum ApplicationMain {
    private static let delegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        application.run()
    }
}
