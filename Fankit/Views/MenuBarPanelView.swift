import Charts
import SwiftUI

struct MenuBarPanelView: View {
    let store: FanControlStore
    let showMainWindow: () -> Void
    let showSettings: () -> Void
    let quit: () -> Void
    var onPreferredSizeChange: (CGSize) -> Void = { _ in }
    var openAIWorkflow: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Fankit", systemImage: "fan")
                    .font(.headline)
                Spacer()
                Text(verbatim: selectedSchedule.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            HStack(spacing: 8) {
                MenuBarMetric(
                    title: "CPU",
                    value: temperatureText(store.hottestCPUTemperature),
                    systemImage: "cpu"
                )
                MenuBarMetric(
                    title: "GPU",
                    value: temperatureText(store.hottestGPUTemperature),
                    systemImage: "square.stack.3d.up"
                )
                MenuBarMetric(
                    title: "Fan",
                    value: rpmText(store.fastestFanRPM),
                    systemImage: "fan"
                )
            }

            Divider()

            MenuBarScheduleMenu(store: store, openAIWorkflow: openAIWorkflow)

            if store.canControlFans {
                controlSummary
            } else {
                helperNotice
            }

            Spacer(minLength: 0)
            Divider()

            HStack(spacing: 8) {
                Button("Show Main Window", systemImage: "macwindow", action: showMainWindow)
                Spacer()
                Button("Settings", systemImage: "gearshape", action: showSettings)
                Button("Quit", systemImage: "power", action: quit)
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 380, height: preferredHeight)
        .onAppear {
            reportPreferredSize()
        }
        .onChange(of: selectedSchedule) { _, _ in
            reportPreferredSize()
        }
    }

    private var preferredHeight: CGFloat {
        switch selectedSchedule {
        case .customScheduling:
            410
        case .aiScheduling:
            440
        case .systemScheduling, .extremeCooling:
            350
        }
    }

    private var selectedSchedule: MenuBarSchedule {
        MenuBarSchedule(mode: store.selectedMode)
    }

    private func reportPreferredSize() {
        onPreferredSizeChange(CGSize(width: 380, height: preferredHeight))
    }

    @ViewBuilder
    private var controlSummary: some View {
        switch selectedSchedule {
        case .customScheduling:
            customScheduleSummary
        case .systemScheduling, .extremeCooling:
            Label(
                store.selectedMode == .maximum
                    ? "All available fans are running at maximum speed"
                    : "Fan speed is managed by macOS",
                systemImage: store.selectedMode == .maximum ? "fan.fill" : "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        case .aiScheduling:
            if let profile = store.activeAICurve {
                aiScheduleSummary(profile)
            } else {
                Label("Create an AI schedule from a System observation", systemImage: "sparkles")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func aiScheduleSummary(_ profile: ThermalCurveProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Current Preset", systemImage: "sparkles")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Picker("Current Preset", selection: Binding(
                    get: { store.activeAICurveID ?? profile.id },
                    set: store.selectAICurve
                )) {
                    ForEach(store.aiProfiles) { aiProfile in
                        Text(verbatim: aiProfile.aiPresetKind.map { "\($0.title) · \(aiProfile.name)" } ?? aiProfile.localizedName)
                            .tag(aiProfile.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            Text(verbatim: store.curveStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            MenuBarLiveTelemetryChart(samples: store.liveTelemetry)
            .frame(height: 132)
        }
    }

    private var customScheduleSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Current Preset", systemImage: "slider.horizontal.3")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Picker("Current Preset", selection: Binding(
                    get: { store.activeCurveID },
                    set: store.selectCurve
                )) {
                    ForEach(store.curveProfiles.filter { !$0.isAIGenerated }) { profile in
                        Text(verbatim: profile.isBuiltIn ? profile.localizedName : "★ \(profile.name)")
                            .tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }

            MenuBarLiveTelemetryChart(samples: store.liveTelemetry)
            .frame(height: 132)
        }
    }

    private var helperNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.helperStatus.title)
                    .font(.callout.weight(.medium))
                Text(verbatim: store.helperStatus.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(store.helperStatus.actionTitle) {
                store.installOrApproveHelper()
            }
            .disabled(store.isChangingHelper)
        }
        .padding(10)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }

    private func temperatureText(_ value: Double?) -> String {
        value.map { String(format: "%.0f°C", $0) } ?? "--°C"
    }

    private func rpmText(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()).formatted()) RPM" } ?? "-- RPM"
    }
}

private struct MenuBarScheduleMenu: View {
    let store: FanControlStore
    let openAIWorkflow: () -> Void

    private var selectedSchedule: MenuBarSchedule {
        MenuBarSchedule(mode: store.selectedMode)
    }

    var body: some View {
        Menu {
            Section {
                ForEach(MenuBarSchedule.allCases) { schedule in
                    Button {
                        if schedule == .aiScheduling && !store.hasAISchedule {
                            openAIWorkflow()
                        } else if let mode = schedule.fanControlMode {
                            store.selectMode(mode)
                        }
                    } label: {
                        HStack {
                            Label {
                                Text(verbatim: schedule.title)
                            } icon: {
                                Image(systemName: schedule.systemImage)
                            }
                            Spacer()
                            if schedule == selectedSchedule {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(
                        !schedule.isAvailable
                            || (schedule == .aiScheduling
                                ? (store.hasAISchedule && !store.canControlFans)
                                : !store.canControlFans)
                    )
                }
            } header: {
                Text(verbatim: L10n.string("Scheduling"))
            }
        } label: {
            HStack(spacing: 8) {
                Label {
                    Text(verbatim: selectedSchedule.title)
                } icon: {
                    Image(systemName: selectedSchedule.systemImage)
                }
                .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help(L10n.string("Choose a scheduling mode"))
    }
}

private struct MenuBarLiveTelemetryChart: View {
    let samples: [LiveTelemetrySample]

    private let fanColors: [Color] = [.blue, .teal, .purple, .pink, .indigo]

    private var latestSample: LiveTelemetrySample? {
        samples.last
    }

    private var latestFans: [FanSnapshot] {
        latestSample?.fans ?? []
    }

    private var temperatureDomain: ClosedRange<Double> {
        guard let minimum = samples.map(\.temperature).min(),
              let maximum = samples.map(\.temperature).max()
        else {
            return 35...100
        }

        let lower = max(0, floor(minimum - 3))
        let upper = min(125, ceil(maximum + 3))
        if upper - lower < 10 {
            let midpoint = (lower + upper) / 2
            return max(0, midpoint - 5)...min(125, midpoint + 5)
        }
        return lower...upper
    }

    private var fanDomain: ClosedRange<Double> {
        let maximum = samples
            .flatMap(\.fans)
            .map(\.maximumRPM)
            .max() ?? 1
        return 0...max(maximum, 1)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            telemetryCard(
                title: "Temperature",
                value: latestSample.map { "\(Int($0.temperature.rounded()))°C" } ?? "--°C"
            ) {
                Chart {
                    ForEach(samples) { sample in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Temperature", sample.temperature)
                        )
                        .foregroundStyle(.orange)
                        .lineStyle(.init(lineWidth: 1.5))

                        if sample.id == latestSample?.id {
                            PointMark(
                                x: .value("Time", sample.timestamp),
                                y: .value("Temperature", sample.temperature)
                            )
                            .foregroundStyle(.orange)
                            .symbolSize(28)
                        }
                    }
                }
                .chartYScale(domain: temperatureDomain)
            }

            fanTelemetryCard
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Monitoring"))
        .accessibilityValue(Text(verbatim: accessibilitySummary))
    }

    private func telemetryCard<Content: View>(
        title: LocalizedStringKey,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                Text(verbatim: value)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            content()
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .frame(height: 84)
                .chartPlotStyle { plot in
                    plot
                        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 6))
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fanTelemetryCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Fan Speed (RPM)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                Text(verbatim: latestFans.map(\.currentRPM).max().map { "\(Int($0.rounded()).formatted())" } ?? "--")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
            }

            Chart {
                ForEach(samples) { sample in
                    ForEach(sample.fans) { fan in
                        LineMark(
                            x: .value("Time", sample.timestamp),
                            y: .value("Fan Speed (RPM)", fan.currentRPM),
                            series: .value("Fan", fan.name)
                        )
                        .foregroundStyle(color(for: fan.index))
                        .lineStyle(.init(lineWidth: 1.5))

                        if sample.id == latestSample?.id {
                            PointMark(
                                x: .value("Time", sample.timestamp),
                                y: .value("Fan Speed (RPM)", fan.currentRPM)
                            )
                            .foregroundStyle(color(for: fan.index))
                            .symbolSize(24)
                        }
                    }
                }
            }
            .chartYScale(domain: fanDomain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 72)
            .chartPlotStyle { plot in
                plot
                    .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 6) {
                ForEach(latestFans) { fan in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(color(for: fan.index))
                            .frame(width: 5, height: 5)
                        Text(verbatim: fan.name)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(for fanIndex: Int) -> Color {
        fanColors[fanIndex % fanColors.count]
    }

    private var accessibilitySummary: String {
        guard let latestSample else { return L10n.string("Monitoring") }
        let fans = latestSample.fans.map { "\($0.name) \(Int($0.currentRPM.rounded())) RPM" }
        return "\(Int(latestSample.temperature.rounded()))°C · " + fans.joined(separator: " · ")
    }
}

private struct MenuBarMetric: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}
