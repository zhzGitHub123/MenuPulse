//
//  MenuPulseTests.swift
//  MenuPulseTests
//

import Testing
@testable import MenuPulse

struct MenuPulseTests {
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

    @Test func statusTitleUsesCompactTwoLineLayout() {
        let metrics = SystemMetrics(
            uploadBytesPerSecond: 1_536,
            downloadBytesPerSecond: 6_144,
            cpuUsage: 20
        )

        #expect(MetricsFormatter.statusTitle(metrics) == "↑1.5K CPU\n↓6.0K 20%")
    }

    @Test func statusTitleSwitchesToWholeNumbersAboveTen() {
        let metrics = SystemMetrics(
            uploadBytesPerSecond: 12 * 1_024,
            downloadBytesPerSecond: 3.5 * 1_024 * 1_024,
            cpuUsage: 7
        )

        #expect(MetricsFormatter.statusTitle(metrics) == "↑12K CPU\n↓3.5M 7%")
    }

    @Test func statusTitleCoversByteAndGigabyteEnds() {
        let metrics = SystemMetrics(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 2 * 1_024 * 1_024 * 1_024,
            cpuUsage: 100
        )

        #expect(MetricsFormatter.statusTitle(metrics) == "↑0B CPU\n↓2.0G 100%")
    }

    @Test func idleDetectionRequiresQuietNetworkAndLowCPU() {
        let quiet = SystemMetrics(
            uploadBytesPerSecond: 200,
            downloadBytesPerSecond: 300,
            cpuUsage: 4
        )
        #expect(SamplingPolicy.isIdle(quiet))

        let busyNetwork = SystemMetrics(
            uploadBytesPerSecond: 200,
            downloadBytesPerSecond: 8_192,
            cpuUsage: 4
        )
        #expect(!SamplingPolicy.isIdle(busyNetwork))

        let busyCPU = SystemMetrics(
            uploadBytesPerSecond: 200,
            downloadBytesPerSecond: 300,
            cpuUsage: 45
        )
        #expect(!SamplingPolicy.isIdle(busyCPU))
    }

    @Test func idleCadenceEngagesOnlyAfterSustainedIdleness() {
        var streak = 0

        for _ in 0..<(SamplingPolicy.idleStreakThreshold - 1) {
            streak = SamplingPolicy.nextIdleStreak(current: streak, isIdle: true)
            #expect(!SamplingPolicy.shouldUseIdleCadence(idleStreak: streak))
        }

        streak = SamplingPolicy.nextIdleStreak(current: streak, isIdle: true)
        #expect(SamplingPolicy.shouldUseIdleCadence(idleStreak: streak))
    }

    @Test func activitySampleRestoresHighFrequencyImmediately() {
        let streak = SamplingPolicy.nextIdleStreak(
            current: SamplingPolicy.idleStreakThreshold,
            isIdle: false
        )

        #expect(streak == 0)
        #expect(!SamplingPolicy.shouldUseIdleCadence(idleStreak: streak))
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
