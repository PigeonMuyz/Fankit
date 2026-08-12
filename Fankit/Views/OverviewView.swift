import SwiftUI

struct OverviewView: View {
    let store: FanControlStore

    private let columns = [
        GridItem(.adaptive(minimum: 135, maximum: 220), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusHeader

                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    OverviewMetricCard(
                        title: "Processor",
                        value: temperatureText(store.hottestCPUTemperature),
                        detail: "Hottest CPU sensor",
                        systemImage: "cpu",
                        tint: temperatureTint(store.hottestCPUTemperature)
                    )
                    OverviewMetricCard(
                        title: "Graphics",
                        value: temperatureText(store.hottestGPUTemperature),
                        detail: "Hottest GPU sensor",
                        systemImage: "display",
                        tint: temperatureTint(store.hottestGPUTemperature)
                    )
                    OverviewMetricCard(
                        title: "Fan Speed",
                        value: store.fastestFanRPM.map { "\(Int($0.rounded())) RPM" } ?? "—",
                        detail: "Fastest fan",
                        systemImage: "fan",
                        tint: .blue
                    )
                }

                FanSection(store: store, compact: false)

                overviewSection(title: "Thermal Zones", systemImage: "thermometer.medium") {
                    let groups = populatedGroups
                    if groups.isEmpty {
                        emptyRow("No sensors detected")
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                            ForEach(groups) { group in
                                ThermalZoneRow(
                                    group: group,
                                    temperature: maximumTemperature(in: group)
                                )
                            }
                        }
                    }
                }

                if let message = store.errorMessage ?? store.controlMessage {
                    Label {
                        Text(verbatim: message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
                }
            }
            .padding(24)
        }
        .navigationTitle("Overview")
    }

    private var statusHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: statusSymbol)
                .font(.title2)
                .foregroundStyle(statusTint)
                .frame(width: 42, height: 42)
                .background(statusTint.opacity(0.12), in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(statusTitle))
                    .font(.title2.weight(.semibold))
                Text(verbatim: statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Label(store.helperStatus.title, systemImage: store.canControlFans ? "checkmark.shield.fill" : "lock.shield")
                    .foregroundStyle(store.canControlFans ? .green : .secondary)
                if let lastUpdated = store.lastUpdated {
                    Text("Updated \(lastUpdated, format: .dateTime.hour().minute().second())")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding(16)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
    }

    private var statusTitle: String {
        if store.errorMessage != nil { return "Needs Attention" }
        if store.selectedMode == .maximum { return "Maximum Cooling" }
        if store.selectedMode == .autoBoost { return "Automatic Cooling" }
        return "System Cooling"
    }

    private var statusDetail: String {
        switch store.selectedMode {
        case .system:
            L10n.string("Fan speed is managed by macOS")
        case .maximum:
            L10n.string("All available fans are running at maximum speed")
        case .autoBoost:
            "\(store.activeCurve.localizedName) · \(store.curveStatus)"
        }
    }

    private var statusSymbol: String {
        store.errorMessage == nil ? controlSymbol : "exclamationmark.triangle.fill"
    }

    private var statusTint: Color {
        store.errorMessage == nil ? controlTint : .orange
    }

    private var controlSymbol: String {
        switch store.selectedMode {
        case .system: "checkmark.circle.fill"
        case .maximum: "fan.fill"
        case .autoBoost: "chart.xyaxis.line"
        }
    }

    private var controlTint: Color {
        switch store.selectedMode {
        case .system: .green
        case .maximum: .red
        case .autoBoost: .blue
        }
    }

    private var populatedGroups: [ThermalGroup] {
        ThermalGroup.allCases.filter { !store.temperatures(in: $0).isEmpty }
    }

    private func maximumTemperature(in group: ThermalGroup) -> Double? {
        store.temperatures(in: group).map(\.celsius).max()
    }

    private func temperatureText(_ temperature: Double?) -> String {
        temperature.map { "\(Int($0.rounded()))°C" } ?? "—"
    }

    private func temperatureTint(_ temperature: Double?) -> Color {
        guard let temperature else { return .secondary }
        if temperature >= 90 { return .red }
        if temperature >= 75 { return .orange }
        return .green
    }

    private func overviewSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
    }
}

private struct OverviewMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(LocalizedStringKey(title))
            } icon: {
                Image(systemName: systemImage)
            }
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
            Text(LocalizedStringKey(detail))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }
}

private struct ThermalZoneRow: View {
    let group: ThermalGroup
    let temperature: Double?

    var body: some View {
        HStack {
            Text(group.title)
                .font(.callout)
            Spacer()
            Text(temperature.map { "\(Int($0.rounded()))°C" } ?? "—")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.vertical, 3)
    }

    private var tint: Color {
        guard let temperature else { return .secondary }
        if temperature >= 90 { return .red }
        if temperature >= 75 { return .orange }
        return .primary
    }
}
