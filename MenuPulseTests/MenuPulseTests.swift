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

        #expect(MetricsFormatter.statusTitle(metrics) == "  1.5K  CPU\n  6.0K  20%")
    }

    @Test func statusTitleSwitchesToWholeNumbersAboveTen() {
        let metrics = SystemMetrics(
            uploadBytesPerSecond: 12 * 1_024,
            downloadBytesPerSecond: 3.5 * 1_024 * 1_024,
            cpuUsage: 7
        )

        #expect(MetricsFormatter.statusTitle(metrics) == "   12K  CPU\n  3.5M   7%")
    }

    @Test func statusTitleCoversByteAndGigabyteEnds() {
        let metrics = SystemMetrics(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 2 * 1_024 * 1_024 * 1_024,
            cpuUsage: 100
        )

        #expect(MetricsFormatter.statusTitle(metrics) == "    0B  CPU\n  2.0G 100%")
    }

    /// 去掉方向箭头后，`CPU` 标签必须正好落在百分比数值的正上方，两行才对得齐。
    @Test func statusTitleAlignsLabelAboveCPUValue() {
        let metrics = SystemMetrics(
            uploadBytesPerSecond: 1_536,
            downloadBytesPerSecond: 6_144,
            cpuUsage: 20
        )
        let lines = MetricsFormatter.statusTitle(metrics)
            .split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines.count == 2)
        #expect(lines[0].count == lines[1].count)
    }

    /// 状态项本身没有方向标记，朗读文本必须补足上行、下行的语义。
    @Test func accessibilityLabelSpellsOutDirections() {
        let metrics = SystemMetrics(
            uploadBytesPerSecond: 1_536,
            downloadBytesPerSecond: 6_144,
            cpuUsage: 20
        )
        let label = MetricsFormatter.accessibilityLabel(metrics)

        #expect(label.contains("上传"))
        #expect(label.contains("下载"))
        #expect(label.contains("1.5K"))
        #expect(label.contains("6.0K"))
        #expect(label.contains("20%"))
    }

    @Test func minorFluctuationsDoNotCountAsSignificantChange() {
        let displayed = SystemMetrics(
            uploadBytesPerSecond: 100_000,
            downloadBytesPerSecond: 200_000,
            cpuUsage: 17
        )
        let jitter = SystemMetrics(
            uploadBytesPerSecond: 103_000,
            downloadBytesPerSecond: 205_000,
            cpuUsage: 18
        )

        #expect(DisplayPolicy.isSignificantChange(from: displayed, to: jitter) == false)
    }

    @Test func largeSpeedSwingCountsAsSignificantChange() {
        let displayed = SystemMetrics(
            uploadBytesPerSecond: 100_000,
            downloadBytesPerSecond: 200_000,
            cpuUsage: 17
        )
        let surge = SystemMetrics(
            uploadBytesPerSecond: 100_000,
            downloadBytesPerSecond: 800_000,
            cpuUsage: 17
        )

        #expect(DisplayPolicy.isSignificantChange(from: displayed, to: surge))
    }

    /// 低速区间靠绝对噪声地板兜底：几百字节的零星流量不应把读数顶得乱跳，
    /// 哪怕它在相对比例上是成倍变化。
    @Test func tinyAbsoluteChangesStayBelowNoiseFloor() {
        let quiet = SystemMetrics(
            uploadBytesPerSecond: 40,
            downloadBytesPerSecond: 60,
            cpuUsage: 4
        )
        let stillQuiet = SystemMetrics(
            uploadBytesPerSecond: 300,
            downloadBytesPerSecond: 400,
            cpuUsage: 5
        )

        #expect(DisplayPolicy.isSignificantChange(from: quiet, to: stillQuiet) == false)
    }

    @Test func cpuMovementAloneCanTriggerRefresh() {
        let displayed = SystemMetrics(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            cpuUsage: 10
        )
        let busier = SystemMetrics(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            cpuUsage: 40
        )

        #expect(DisplayPolicy.isSignificantChange(from: displayed, to: busier))
    }

    /// 定宽排版是状态项宽度恒定的前提，宽度恒定又是避免菜单栏重排的前提，
    /// 因此这条不变量需要被测试锁住：任意量级的数值都必须渲染出等长的两行。
    @Test func statusTitleKeepsConstantLineWidthAcrossMagnitudes() {
        let samples = [
            SystemMetrics(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0, cpuUsage: 0),
            SystemMetrics(uploadBytesPerSecond: 999, downloadBytesPerSecond: 1_023, cpuUsage: 5),
            SystemMetrics(
                uploadBytesPerSecond: 1_536,
                downloadBytesPerSecond: 12 * 1_024,
                cpuUsage: 20
            ),
            SystemMetrics(
                uploadBytesPerSecond: 3.5 * 1_024 * 1_024,
                downloadBytesPerSecond: 999 * 1_024 * 1_024,
                cpuUsage: 99
            ),
            SystemMetrics(
                uploadBytesPerSecond: 2 * 1_024 * 1_024 * 1_024,
                downloadBytesPerSecond: 999.9 * 1_024 * 1_024 * 1_024,
                cpuUsage: 100
            )
        ]

        let widths = samples.map { metrics -> [Int] in
            MetricsFormatter.statusTitle(metrics)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(\.count)
        }

        #expect(Set(widths).count == 1, "不同量级的数值渲染出了不同的行宽：\(widths)")
    }

    /// 预测量用的模板必须覆盖真实排版的最大宽度，否则最宽内容会被裁掉。
    @Test func widestTitleTemplateBoundsEveryRenderedLine() {
        let extremes = SystemMetrics(
            uploadBytesPerSecond: 999.9 * 1_024 * 1_024 * 1_024,
            downloadBytesPerSecond: 999.9 * 1_024 * 1_024 * 1_024,
            cpuUsage: 100
        )
        let templateWidth = MetricsFormatter.widestTitle
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count)
            .max() ?? 0
        let renderedWidth = MetricsFormatter.statusTitle(extremes)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count)
            .max() ?? 0

        #expect(renderedWidth <= templateWidth)
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
