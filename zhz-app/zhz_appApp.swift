//
//  zhz_appApp.swift
//  zhz-app
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
    private let samplingQueue = DispatchQueue(
        label: "zhzGitHub123.zhz-app.metrics",
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
        let item = NSStatusBar.system.statusItem(withLength: AppConfiguration.minimumStatusItemWidth)
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
        setStatusTitle(title, on: button, item: item)
        button.toolTip = "实时网络速度与 CPU 占用"

        item.menu = makeMenu()
        statusItem = item
        lastTitle = title
    }

    private func setStatusTitle(_ title: String, on button: NSButton, item: NSStatusItem) {
        let rendered = makeStatusImage(title)
        button.title = ""
        button.image = rendered.image
        button.setAccessibilityLabel(title.replacingOccurrences(of: "\n", with: "，"))
        if abs(item.length - rendered.itemWidth) >= 0.5 {
            item.length = rendered.itemWidth
        }
    }

    private func makeStatusImage(_ title: String) -> (image: NSImage, itemWidth: CGFloat) {
        let lines = title.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        let measuredLines = lines.prefix(2).map { line in
            let text = line as NSString
            return (text: text, size: text.size(withAttributes: attributes))
        }
        let contentWidth = measuredLines.map { $0.size.width }.max() ?? 0
        let imageWidth = ceil(contentWidth) + AppConfiguration.imageHorizontalPadding
        let imageSize = NSSize(width: imageWidth, height: AppConfiguration.statusImageHeight)
        let image = NSImage(size: imageSize, flipped: true) { bounds in
            let lineHeight = bounds.height / CGFloat(max(lines.count, 1))

            for (index, measuredLine) in measuredLines.enumerated() {
                let origin = NSPoint(
                    x: floor((bounds.width - measuredLine.size.width) / 2),
                    y: floor(
                        CGFloat(index) * lineHeight
                            + (lineHeight - measuredLine.size.height) / 2
                    )
                )
                measuredLine.text.draw(at: origin, withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        return (
            image,
            max(
                AppConfiguration.minimumStatusItemWidth,
                imageWidth + AppConfiguration.buttonHorizontalPadding
            )
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
                      self.monitoringGeneration == generation,
                      self.lastTitle != title else {
                    return
                }

                if let item = self.statusItem,
                   let button = item.button {
                    self.setStatusTitle(title, on: button, item: item)
                }
                self.lastTitle = title
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
