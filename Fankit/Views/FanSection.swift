import SwiftUI

struct FanSection: View {
    let store: FanControlStore
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Fans", systemImage: "fan")
                .font(.title3.bold())

            Picker("Fan mode", selection: Binding(
                get: { store.selectedMode },
                set: store.selectMode
            )) {
                ForEach(FanControlMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(L10n.string(
                store.canControlFans
                    ? "Change fan control mode"
                    : "Requires a signed privileged helper"
            ))
            .disabled(!store.canControlFans)

            if store.selectedMode == .autoBoost {
                HStack {
                    Label {
                        Text(verbatim: store.activeCurve.localizedName)
                    } icon: {
                        Image(systemName: "chart.xyaxis.line")
                    }
                    Spacer()
                    Text(verbatim: store.curveStatus)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }

            if store.fans.isEmpty {
                ContentUnavailableView("No Fans Found", systemImage: "fan.slash")
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
            } else {
                ForEach(store.fans) { fan in
                    FanRow(fan: fan, targetRPM: store.curveTargetRPMs[fan.index])
                }
            }

            if !store.canControlFans {
                HStack(alignment: .center, spacing: 10) {
                    Label {
                        Text(verbatim: store.helperStatus.detail)
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(store.helperStatus.actionTitle) {
                        store.installOrApproveHelper()
                    }
                    .disabled(store.isChangingHelper)
                }
            }
        }
        .padding(compact ? 0 : 18)
        .background(compact ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial), in: .rect(cornerRadius: 14))
    }
}

private struct FanRow: View {
    let fan: FanSnapshot
    let targetRPM: Double?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text(verbatim: fan.name)
                    .fontWeight(.medium)
                ProgressView(value: fan.fraction)
                    .tint(fan.fraction > 0.82 ? .red : .blue)
                Text("\(Int(fan.currentRPM.rounded())) RPM")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .trailing)
            }
            GridRow {
                Text(verbatim: targetDescription)
                    .font(.caption)
                    .foregroundStyle(targetRPM == nil ? .tertiary : .secondary)
                Color.clear.frame(height: 1)
                Color.clear.frame(height: 1)
            }
        }
    }

    private var targetDescription: String {
        if let targetRPM {
            return L10n.format("Target %d RPM", Int(targetRPM.rounded()))
        }
        return L10n.format(
            "%d–%d RPM",
            Int(fan.minimumRPM),
            Int(fan.maximumRPM)
        )
    }
}
