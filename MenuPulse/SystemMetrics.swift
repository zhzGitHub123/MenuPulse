//
//  SystemMetrics.swift
//  MenuPulse
//

import Darwin
import Foundation

struct SystemMetrics: Equatable, Sendable {
    let uploadBytesPerSecond: Double
    let downloadBytesPerSecond: Double
    let cpuUsage: Double
}

struct CPUTicks: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

enum MetricsMath {
    static func bytesPerSecond(
        current: UInt64,
        previous: UInt64,
        elapsed: TimeInterval
    ) -> Double? {
        guard elapsed > 0, current >= previous else { return nil }
        return Double(current - previous) / elapsed
    }

    static func cpuUsage(current: CPUTicks, previous: CPUTicks) -> Double {
        let user = wrappingDelta(current: current.user, previous: previous.user)
        let system = wrappingDelta(current: current.system, previous: previous.system)
        let idle = wrappingDelta(current: current.idle, previous: previous.idle)
        let nice = wrappingDelta(current: current.nice, previous: previous.nice)
        let total = user + system + idle + nice

        guard total > 0 else { return 0 }
        let usage = Double(user + system + nice) / Double(total) * 100
        return min(max(usage, 0), 100)
    }

    static func wrappingDelta(
        current: UInt64,
        previous: UInt64,
        maximum: UInt64 = UInt64(UInt32.max)
    ) -> UInt64 {
        if current >= previous {
            return current - previous
        }
        // 计数器回绕：补上从 previous 走到 maximum 再回到 current 的距离。
        return maximum - previous + current + 1
    }
}

/// 采样节奏策略：系统闲置时拉长采样间隔，降低常驻唤醒带来的能耗。
enum SamplingPolicy {
    /// 上下行都低于该速率时视为网络静默；后台心跳流量不足以算作活跃。
    static let idleNetworkBytesPerSecond: Double = 1_024
    /// CPU 低于该占用率时视为计算闲置。
    static let idleCPUUsage: Double = 10
    /// 连续多少次闲置采样后才退避，避免瞬时静默导致节奏来回抖动。
    static let idleStreakThreshold = 5

    static func isIdle(_ metrics: SystemMetrics) -> Bool {
        metrics.uploadBytesPerSecond < idleNetworkBytesPerSecond
            && metrics.downloadBytesPerSecond < idleNetworkBytesPerSecond
            && metrics.cpuUsage < idleCPUUsage
    }

    /// 闲置一次累加一格，只要出现活跃立刻清零，从而下一次采样即恢复高频。
    static func nextIdleStreak(current: Int, isIdle: Bool) -> Int {
        isIdle ? min(current + 1, idleStreakThreshold) : 0
    }

    static func shouldUseIdleCadence(idleStreak: Int) -> Bool {
        idleStreak >= idleStreakThreshold
    }
}

/// 决定一次采样值得不值得推到菜单栏上。
///
/// 实测每次状态项刷新要花约 10.4 ms CPU（光栅化 + Core Animation 提交 + 发往
/// ControlCenter 的 XPC），而采样本身只要 0.7 ms——常驻能耗几乎全部由刷新次数决定。
/// 因此这里给数值加一段死区：变化不明显就不刷新，让屏幕上的读数稳住。
enum DisplayPolicy {
    /// 低于该绝对变化量一律视为抖动，避免闲置时的零星流量把读数顶得乱跳。
    static let speedNoiseFloor: Double = 512
    /// 超过噪声地板后，还需达到这个相对变化才值得刷新。
    static let relativeSpeedThreshold = 0.15
    /// CPU 百分比的最小可见变化。
    static let cpuThreshold: Double = 3
    /// 连续抑制多少次后无条件刷新一次，确保读数不会长期停在旧值上。
    static let maxSuppressedUpdates = 5

    static func isSignificantChange(from old: SystemMetrics, to new: SystemMetrics) -> Bool {
        speedChanged(old.uploadBytesPerSecond, new.uploadBytesPerSecond)
            || speedChanged(old.downloadBytesPerSecond, new.downloadBytesPerSecond)
            || abs(old.cpuUsage - new.cpuUsage) >= cpuThreshold
    }

    private static func speedChanged(_ old: Double, _ new: Double) -> Bool {
        let delta = abs(new - old)
        guard delta >= speedNoiseFloor else { return false }
        return delta >= max(old, new) * relativeSpeedThreshold
    }
}

enum MetricsFormatter {
    /// 速度与 CPU 字段按固定字符宽度右对齐。
    ///
    /// 这不只是排版偏好：状态项宽度一旦随数值变化，菜单栏就要跑一次 Auto Layout 重排，
    /// 并通过 XPC 把新尺寸同步给 ControlCenter 进程——实测这两项占了常驻 CPU 的绝大部分。
    /// 字段定宽后状态项宽度恒定，这条昂贵的路径彻底不会触发。
    private static let speedFieldWidth = 6
    private static let rightFieldWidth = 4

    /// 排版可能达到的最宽内容，供状态项预先测量出恒定宽度。
    static let widestTitle = "999.9G  CPU\n999.9G 100%"

    /// 上行在上、下行在下是菜单栏监控的通用约定，因此不再绘制箭头：
    /// 省下的字符宽度让两行严格对齐，`CPU` 标签正好落在百分比数值的正上方。
    /// 方向语义由无障碍标签补全，见 `accessibilityLabel(_:)`。
    static func statusTitle(_ metrics: SystemMetrics) -> String {
        let cpu = Int(metrics.cpuUsage.rounded())
        let upload = padded(compactSpeed(metrics.uploadBytesPerSecond), to: speedFieldWidth)
        let download = padded(compactSpeed(metrics.downloadBytesPerSecond), to: speedFieldWidth)
        let label = padded("CPU", to: rightFieldWidth)
        let cpuField = padded("\(cpu)%", to: rightFieldWidth)
        return "\(upload) \(label)\n\(download) \(cpuField)"
    }

    /// 状态项本身不再有方向标记，VoiceOver 的朗读文本必须自己讲清上下行。
    static func accessibilityLabel(_ metrics: SystemMetrics) -> String {
        let cpu = Int(metrics.cpuUsage.rounded())
        let upload = compactSpeed(metrics.uploadBytesPerSecond)
        let download = compactSpeed(metrics.downloadBytesPerSecond)
        return "上传 \(upload) 每秒，下载 \(download) 每秒，CPU 占用 \(cpu)%"
    }

    /// 左侧补空格至指定字符宽度；超长时原样返回，宁可略微超宽也不截断数值。
    private static func padded(_ text: String, to width: Int) -> String {
        let deficit = width - text.count
        guard deficit > 0 else { return text }
        return String(repeating: " ", count: deficit) + text
    }

    private static func compactSpeed(_ bytesPerSecond: Double) -> String {
        let value = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0
        let scaledValue: Double
        let suffix: String

        switch value {
        case ..<1_024:
            return "\(Int(value.rounded()))B"
        case ..<(1_024 * 1_024):
            scaledValue = value / 1_024
            suffix = "K"
        case ..<(1_024 * 1_024 * 1_024):
            scaledValue = value / (1_024 * 1_024)
            suffix = "M"
        default:
            scaledValue = value / (1_024 * 1_024 * 1_024)
            suffix = "G"
        }

        let format = scaledValue < 10 ? "%.1f%@" : "%.0f%@"
        return String(format: format, scaledValue, suffix)
    }
}

final class SystemSampler {
    private static let routeMIB: (Int32, Int32, Int32, Int32, Int32, Int32) = (
        CTL_NET,
        PF_ROUTE,
        0,
        0,
        NET_RT_IFLIST2,
        0
    )
    private static let initialRouteBufferSize = 16 * 1_024
    private static let routeMessagePrefixSize = 4
    private static let linkAddressHeaderSize = 8

    private struct NetworkCounters {
        let sent: UInt64
        let received: UInt64
    }

    private var routeBuffer = [UInt8](
        repeating: 0,
        count: SystemSampler.initialRouteBufferSize
    )
    private var previousNetwork: NetworkCounters?
    private var previousCPU: CPUTicks?
    private var previousUptime: TimeInterval?

    func reset() {
        previousNetwork = nil
        previousCPU = nil
        previousUptime = nil
    }

    func sample() -> SystemMetrics? {
        guard let network = readNetworkCounters(),
              let cpu = readCPUTicks() else {
            return nil
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        defer {
            previousNetwork = network
            previousCPU = cpu
            previousUptime = uptime
        }

        guard let previousNetwork,
              let previousCPU,
              let previousUptime else {
            return nil
        }

        let elapsed = uptime - previousUptime
        guard let uploadBytesPerSecond = MetricsMath.bytesPerSecond(
            current: network.sent,
            previous: previousNetwork.sent,
            elapsed: elapsed
        ),
        let downloadBytesPerSecond = MetricsMath.bytesPerSecond(
            current: network.received,
            previous: previousNetwork.received,
            elapsed: elapsed
        ) else {
            return nil
        }

        return SystemMetrics(
            uploadBytesPerSecond: uploadBytesPerSecond,
            downloadBytesPerSecond: downloadBytesPerSecond,
            cpuUsage: MetricsMath.cpuUsage(current: cpu, previous: previousCPU)
        )
    }

    private func readNetworkCounters() -> NetworkCounters? {
        guard let byteCount = loadRouteMessages() else { return nil }

        var sent: UInt64 = 0
        var received: UInt64 = 0
        var isValid = true
        var foundInterfaceMessage = false

        routeBuffer.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                isValid = false
                return
            }

            var offset = 0
            while offset < byteCount {
                guard byteCount - offset >= Self.routeMessagePrefixSize else {
                    isValid = false
                    break
                }

                var rawMessageLength: UInt16 = 0
                memcpy(
                    &rawMessageLength,
                    baseAddress.advanced(by: offset),
                    MemoryLayout<UInt16>.size
                )
                let messageLength = Int(rawMessageLength)
                guard messageLength >= Self.routeMessagePrefixSize,
                      messageLength <= byteCount - offset else {
                    isValid = false
                    break
                }

                let messageType = baseAddress.load(
                    fromByteOffset: offset + 3,
                    as: UInt8.self
                )
                if Int32(messageType) == RTM_IFINFO2 {
                    foundInterfaceMessage = true
                    guard messageLength
                            >= MemoryLayout<if_msghdr2>.size + Self.linkAddressHeaderSize
                    else {
                        isValid = false
                        break
                    }

                    var message = if_msghdr2()
                    memcpy(
                        &message,
                        baseAddress.advanced(by: offset),
                        MemoryLayout<if_msghdr2>.size
                    )

                    if message.ifm_addrs & RTA_IFP != 0 {
                        let linkAddress = baseAddress.advanced(
                            by: offset + MemoryLayout<if_msghdr2>.size
                        )
                        let addressLength = Int(linkAddress.load(as: UInt8.self))
                        let addressFamily = Int32(
                            linkAddress.load(fromByteOffset: 1, as: UInt8.self)
                        )
                        let nameLength = Int(
                            linkAddress.load(fromByteOffset: 5, as: UInt8.self)
                        )

                        if addressFamily == AF_LINK,
                           addressLength >= Self.linkAddressHeaderSize,
                           MemoryLayout<if_msghdr2>.size + addressLength <= messageLength,
                           nameLength >= 2,
                           Self.linkAddressHeaderSize + nameLength <= addressLength {
                            let name = linkAddress.advanced(by: Self.linkAddressHeaderSize)
                            let isEthernetInterface = name.load(as: UInt8.self) == 0x65
                                && name.load(fromByteOffset: 1, as: UInt8.self) == 0x6E

                            if isEthernetInterface {
                                let nextSent = sent.addingReportingOverflow(
                                    message.ifm_data.ifi_obytes
                                )
                                let nextReceived = received.addingReportingOverflow(
                                    message.ifm_data.ifi_ibytes
                                )
                                guard !nextSent.overflow, !nextReceived.overflow else {
                                    isValid = false
                                    break
                                }
                                sent = nextSent.partialValue
                                received = nextReceived.partialValue
                            }
                        }
                    }
                }

                offset += messageLength
            }
        }

        guard isValid, foundInterfaceMessage else { return nil }
        return NetworkCounters(sent: sent, received: received)
    }

    private func loadRouteMessages() -> Int? {
        for attempt in 0..<2 {
            var byteCount = routeBuffer.count
            if readRouteMessages(byteCount: &byteCount) == 0 {
                return byteCount
            }

            guard errno == ENOMEM,
                  attempt == 0,
                  let requiredSize = requiredRouteBufferSize() else {
                return nil
            }

            routeBuffer = [UInt8](
                repeating: 0,
                count: max(requiredSize, routeBuffer.count * 2)
            )
        }

        return nil
    }

    private func readRouteMessages(byteCount: inout Int) -> Int32 {
        var mib = Self.routeMIB
        return withUnsafeMutablePointer(to: &mib) { tuplePointer in
            let mibPointer = UnsafeMutableRawPointer(tuplePointer)
                .assumingMemoryBound(to: Int32.self)
            return routeBuffer.withUnsafeMutableBytes { bytes in
                sysctl(
                    mibPointer,
                    6,
                    bytes.baseAddress,
                    &byteCount,
                    nil,
                    0
                )
            }
        }
    }

    private func requiredRouteBufferSize() -> Int? {
        var mib = Self.routeMIB
        var requiredSize = 0
        let result = withUnsafeMutablePointer(to: &mib) { tuplePointer in
            let mibPointer = UnsafeMutableRawPointer(tuplePointer)
                .assumingMemoryBound(to: Int32.self)
            return sysctl(mibPointer, 6, nil, &requiredSize, nil, 0)
        }
        return result == 0 && requiredSize > 0 ? requiredSize : nil
    }

    private func readCPUTicks() -> CPUTicks? {
        var load = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(
            user: UInt64(load.cpu_ticks.0),
            system: UInt64(load.cpu_ticks.1),
            idle: UInt64(load.cpu_ticks.2),
            nice: UInt64(load.cpu_ticks.3)
        )
    }
}
