import SwiftUI

struct MenuBarPanelView: View {
    let store: FanControlStore
    let showMainWindow: () -> Void
    let showSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Fankit", systemImage: "fan")
                    .font(.headline)
                Spacer()
                Text(store.selectedMode.title)
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

            Picker("Fan mode", selection: Binding(
                get: { store.selectedMode },
                set: { store.selectMode($0) }
            )) {
                ForEach(FanControlMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!store.canControlFans)
            .help("Change fan control mode")

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
        .frame(width: 380, height: 350)
    }

    @ViewBuilder
    private var controlSummary: some View {
        if store.selectedMode == .autoBoost {
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent("Active Preset", value: store.activeCurve.localizedName)
                LabeledContent(
                    "Control Temperature",
                    value: temperatureText(store.curveControlTemperature)
                )
                Label {
                    Text(verbatim: store.curveStatus)
                } icon: {
                    Image(systemName: "waveform.path.ecg")
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } else {
            Label(
                store.selectedMode == .maximum
                    ? "All available fans are running at maximum speed"
                    : "Fan speed is managed by macOS",
                systemImage: store.selectedMode == .maximum ? "fan.fill" : "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
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
