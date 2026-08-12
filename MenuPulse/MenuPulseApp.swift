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
    static let buttonHorizontalPadding: CGFloat = 6
    static let samplingInterval: DispatchTimeInterval = .seconds(2)
    static let samplingLeeway: DispatchTimeInterval = .milliseconds(400)
    /// 闲置时的采样节奏：更长的间隔配更大的余量，便于系统合并唤醒。
    static let idleSamplingInterval: DispatchTimeInterval = .seconds(5)
    static let idleSamplingLeeway: DispatchTimeInterval = .milliseconds(1_500)
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
        setStatusTitle(title, on: button)
        button.toolTip = "实时网络速度与 CPU 占用"

        item.menu = makeMenu()
        statusItem = item
        lastTitle = title
    }

    private func setStatusTitle(_ title: String, on button: NSButton) {
        button.title = ""
        button.image = makeStatusImage(title)
        button.setAccessibilityLabel(title.replacingOccurrences(of: "\n", with: "，"))
    }

    /// 状态项的恒定宽度，按排版可能达到的最宽内容测量一次后缓存。
    ///
    /// 一次性算出宽度是刻意的：只要 `NSStatusItem.length` 不再变化，菜单栏就不会重排，
    /// 也不会向 ControlCenter 发送尺寸同步的 XPC 消息。
    private lazy var fixedImageWidth: CGFloat = {
        let attributes = statusTextAttributes
        let widest = MetricsFormatter.widestTitle
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { (String($0) as NSString).size(withAttributes: attributes).width }
            .max() ?? 0
        return ceil(widest) + AppConfiguration.imageHorizontalPadding
    }()

    private func makeStatusImage(_ title: String) -> NSImage {
        let lines = title.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let attributes = statusTextAttributes
        let measuredLines = lines.prefix(2).map { line in
            let text = line as NSString
            return (text: text, size: text.size(withAttributes: attributes))
        }
        let imageSize = NSSize(
            width: fixedImageWidth,
            height: AppConfiguration.statusImageHeight
        )

        // 立即光栅化，而不是交给 NSImage 的 drawingHandler。
        //
        // drawingHandler 产生的是惰性的 NSCustomImageRep：AppKit 每次显示状态项都要回调
        // 重新绘制，并额外走一遍挑选最佳表示的通用路径。这里一次性画进位图，
        // 之后菜单栏拿到的就是现成的像素。
        let image = NSImage(size: imageSize)
        image.lockFocusFlipped(true)
        let lineHeight = imageSize.height / CGFloat(max(lines.count, 1))
        for (index, measuredLine) in measuredLines.enumerated() {
            let origin = NSPoint(
                x: floor((imageSize.width - measuredLine.size.width) / 2),
                y: floor(
                    CGFloat(index) * lineHeight
                        + (lineHeight - measuredLine.size.height) / 2
                )
            )
            measuredLine.text.draw(at: origin, withAttributes: attributes)
        }
        image.unlockFocus()

        image.isTemplate = true
        return image
    }

    private var fixedStatusItemLength: CGFloat {
        max(
            AppConfiguration.minimumStatusItemWidth,
            fixedImageWidth + AppConfiguration.buttonHorizontalPadding
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
        if lastTitle != title {
            if let button = statusItem?.button {
                setStatusTitle(title, on: button)
            }
            lastTitle = title
        }

        updateSamplingCadence(for: metrics)
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
