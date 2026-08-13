//
//  MenuPulseApp.swift
//  MenuPulse
//

import AppKit
import Foundation

private enum AppConfiguration {
    /// 状态项按最宽内容一次性定宽，避免读数变化触发菜单栏重排和 XPC 尺寸同步。
    static let minimumStatusItemWidth: CGFloat = 38
    static let widestStatusTitle = "1023G\tCPU\n1023G\t100%"
    static let statusImageHeight: CGFloat = 20
    static let imageHorizontalPadding: CGFloat = 4
    /// 速度列与 CPU 列之间的间距。等宽字体下一个空格约 5pt，这里按点数给，
    /// 才能调到比一个字符更窄。
    static let columnSpacing: CGFloat = 1
    static let buttonHorizontalPadding: CGFloat = 6
    /// 采样周期。每次刷新状态项的固定成本约 10.4 ms CPU，远高于采样本身的 0.7 ms，
    /// 因此周期长度直接决定常驻能耗；3 秒是在读数跟手感与耗电之间取的平衡点。
    static let samplingInterval: DispatchTimeInterval = .seconds(3)
    static let samplingLeeway: DispatchTimeInterval = .milliseconds(600)
    /// 闲置时的采样节奏：更长的间隔配更大的余量，便于系统合并唤醒。
    static let idleSamplingInterval: DispatchTimeInterval = .seconds(8)
    static let idleSamplingLeeway: DispatchTimeInterval = .seconds(2)
}

/// 按钮内的纯绘制层：不接管点击，也不周期修改 `NSStatusBarButton` 的内容属性。
private final class StatusMetricsView: NSView {
    var drawingHandler: (() -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawingHandler?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
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
        .foregroundColor: NSColor.labelColor
    ]
    private let samplingQueue = DispatchQueue(
        label: "io.github.zhzgithub123.MenuPulse.metrics",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )

    private var statusImageTitle = ""
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

    /// 两列与状态项只测量一次。周期刷新不再修改 `NSStatusItem.length`。
    private lazy var fixedColumnLayout: (
        leftWidth: CGFloat,
        rightWidth: CGFloat,
        imageSize: NSSize,
        itemWidth: CGFloat
    ) = {
        let attributes = statusTextAttributes
        var leftWidth: CGFloat = 0
        var rightWidth: CGFloat = 0

        for line in AppConfiguration.widestStatusTitle.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let columns = MetricsFormatter.columns(of: line)
            leftWidth = max(
                leftWidth,
                (columns.left as NSString).size(withAttributes: attributes).width
            )
            rightWidth = max(
                rightWidth,
                (columns.right as NSString).size(withAttributes: attributes).width
            )
        }

        leftWidth = ceil(leftWidth)
        rightWidth = ceil(rightWidth)
        let imageSize = NSSize(
            width: leftWidth + AppConfiguration.columnSpacing + rightWidth
                + AppConfiguration.imageHorizontalPadding,
            height: AppConfiguration.statusImageHeight
        )
        return (
            leftWidth,
            rightWidth,
            imageSize,
            max(
                AppConfiguration.minimumStatusItemWidth,
                imageSize.width + AppConfiguration.buttonHorizontalPadding
            )
        )
    }()

    /// 只加入按钮一次。后续更新仅重绘这个子视图，完全避开 NSImage 路径。
    private lazy var statusView: StatusMetricsView = {
        let view = StatusMetricsView(
            frame: NSRect(origin: .zero, size: fixedColumnLayout.imageSize)
        )
        view.drawingHandler = { [weak self] in
            self?.drawCurrentStatusContent()
        }
        return view
    }()

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
        let item = NSStatusBar.system.statusItem(
            withLength: fixedColumnLayout.itemWidth
        )
        guard let button = item.button else { return }

        let initialMetrics = SystemMetrics(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            cpuUsage: 0
        )
        button.alignment = .center
        button.title = ""
        let title = MetricsFormatter.statusTitle(initialMetrics)
        updateStatusImageTitle(title)
        statusView.frame.origin = NSPoint(
            x: floor((button.bounds.width - statusView.frame.width) / 2),
            y: floor((button.bounds.height - statusView.frame.height) / 2)
        )
        statusView.autoresizingMask = [
            .minXMargin,
            .maxXMargin,
            .minYMargin,
            .maxYMargin
        ]
        button.addSubview(statusView)
        button.setAccessibilityLabel(MetricsFormatter.accessibilityLabel(initialMetrics))
        button.toolTip = "实时网络速度与 CPU 占用（上行在上，下行在下）"

        item.menu = makeMenu()
        statusItem = item
        lastTitle = title
        displayedMetrics = initialMetrics
    }

    private func setStatusTitle(
        _ title: String,
        metrics: SystemMetrics,
        on item: NSStatusItem
    ) {
        guard let button = item.button else { return }

        updateStatusImageTitle(title)
        statusView.needsDisplay = true
        if NSWorkspace.shared.isVoiceOverEnabled {
            button.setAccessibilityLabel(MetricsFormatter.accessibilityLabel(metrics))
        }
    }

    private func updateStatusImageTitle(_ title: String) {
        statusImageTitle = title
    }

    private func drawCurrentStatusContent() {
        let title = statusImageTitle

        let attributes = statusTextAttributes
        let layout = fixedColumnLayout
        let measured = title
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(2)
            .map { line -> (left: NSString, right: NSString, leftSize: NSSize, rightSize: NSSize) in
                let columns = MetricsFormatter.columns(of: line)
                let left = columns.left as NSString
                let right = columns.right as NSString
                return (
                    left,
                    right,
                    left.size(withAttributes: attributes),
                    right.size(withAttributes: attributes)
                )
            }

        let contentOrigin = AppConfiguration.imageHorizontalPadding / 2
        let leftColumnEdge = contentOrigin + layout.leftWidth
        let rightColumnEdge = leftColumnEdge
            + AppConfiguration.columnSpacing
            + layout.rightWidth
        let lineHeight = layout.imageSize.height / CGFloat(max(measured.count, 1))
        for (index, line) in measured.enumerated() {
            let lineTop = CGFloat(index) * lineHeight
            draw(
                line.left,
                size: line.leftSize,
                rightEdge: leftColumnEdge,
                lineTop: lineTop,
                lineHeight: lineHeight,
                attributes: attributes
            )
            draw(
                line.right,
                size: line.rightSize,
                rightEdge: rightColumnEdge,
                lineTop: lineTop,
                lineHeight: lineHeight,
                attributes: attributes
            )
        }
    }

    /// 两列都靠各自的右边缘对齐：速度的个位、CPU 的百分号因此停在同一条竖线上，
    /// 两行之间不会因为位数不同而错开。
    private func draw(
        _ content: NSString,
        size: NSSize,
        rightEdge: CGFloat,
        lineTop: CGFloat,
        lineHeight: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) {
        guard content.length > 0 else { return }

        let origin = NSPoint(
            x: floor(rightEdge - size.width),
            y: floor(lineTop + (lineHeight - size.height) / 2)
        )
        content.draw(at: origin, withAttributes: attributes)
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
               let item = statusItem {
                setStatusTitle(title, metrics: metrics, on: item)
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
