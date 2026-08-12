//
//  zhz_appTests.swift
//  zhz-appTests
//

import Testing
@testable import zhz_app

struct zhz_appTests {
    @Test func networkRateUsesActualElapsedTime() {
        let rate = MetricsMath.bytesPerSecond(
            current: 5_120,
            previous: 1_024,
            elapsed: 2
        )

        #expect(rate == 2_048)
    }

    @Test func networkCounterResetInvalidatesCurrentSample() {
        let rate = MetricsMath.bytesPerSecond(
            current: 100,
            previous: 1_000,
            elapsed: 2
        )

        #expect(rate == nil)
    }

    @Test func networkRateContinuesPastLegacy32BitLimit() {
        let legacyMaximum = UInt64(UInt32.max)
        let rate = MetricsMath.bytesPerSecond(
            current: legacyMaximum + 1_537,
            previous: legacyMaximum - 511,
            elapsed: 2
        )

        #expect(rate == 1_024)
    }

    @Test func cpuUsageUsesTickDeltas() {
        let previous = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let current = CPUTicks(user: 200, system: 100, idle: 1_700, nice: 0)

        let usage = MetricsMath.cpuUsage(current: current, previous: previous)

        #expect(abs(usage - 15) < 0.000_1)
    }

    @Test func cpuCounterWrapIsHandled() {
        let maximum = UInt64(UInt32.max)
        let delta = MetricsMath.wrappingDelta(
            current: 4,
            previous: maximum - 5,
            maximum: maximum
        )

        #expect(delta == 10)
    }

    @Test func speedFormattingUsesBinaryUnits() {
        #expect(MetricsFormatter.speed(0) == "0B/s")
        #expect(MetricsFormatter.speed(1_024) == "1.0KB/s")
        #expect(MetricsFormatter.speed(1_024 * 1_024) == "1.0MB/s")
    }

    @Test func statusTitleUsesCompactTwoLineLayout() {
        let metrics = SystemMetrics(
            uploadBytesPerSecond: 1_536,
            downloadBytesPerSecond: 6_144,
            cpuUsage: 20
        )

        #expect(MetricsFormatter.statusTitle(metrics) == "↑1.5K CPU\n↓6.0K 20%")
    }

    @Test func hiddenStatusItemDoesNotResumeMonitoringAfterWake() {
        var reasons: MonitoringSuspensionReasons = [.systemSleeping]
        reasons.remove(.systemSleeping)

        #expect(
            !MonitoringPolicy.shouldMonitor(
                statusItemIsVisible: false,
                suspensionReasons: reasons
            )
        )
    }

    @Test func monitoringResumesOnlyAfterEverySuspensionEnds() {
        var reasons: MonitoringSuspensionReasons = [.screenSleeping, .systemSleeping]
        reasons.remove(.systemSleeping)

        #expect(
            !MonitoringPolicy.shouldMonitor(
                statusItemIsVisible: true,
                suspensionReasons: reasons
            )
        )

        reasons.remove(.screenSleeping)
        #expect(
            MonitoringPolicy.shouldMonitor(
                statusItemIsVisible: true,
                suspensionReasons: reasons
            )
        )
    }
}
