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
        guard current < previous else { return current - previous }
        return maximum - previous + current + 1
    }
}

enum MetricsFormatter {
    static func speed(_ bytesPerSecond: Double) -> String {
        let value = bytesPerSecond.isFinite ? max(bytesPerSecond, 0) : 0

        switch value {
        case ..<1_024:
            return "\(Int(value.rounded()))B/s"
        case ..<(1_024 * 1_024):
            return String(format: "%.1fKB/s", value / 1_024)
        case ..<(1_024 * 1_024 * 1_024):
            return String(format: "%.1fMB/s", value / (1_024 * 1_024))
        default:
            return String(format: "%.1fGB/s", value / (1_024 * 1_024 * 1_024))
        }
    }

    static func statusTitle(_ metrics: SystemMetrics) -> String {
        let cpu = Int(metrics.cpuUsage.rounded())
        return "↑\(compactSpeed(metrics.uploadBytesPerSecond)) CPU\n↓\(compactSpeed(metrics.downloadBytesPerSecond)) \(cpu)%"
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
