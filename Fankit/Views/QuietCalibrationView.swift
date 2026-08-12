import SwiftUI

struct QuietCalibrationRecommendationView: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "ear.badge.waveform")
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text("Calibrate Quiet Fan Noise")
                    .font(.headline)
                Text("Calibrate fan noise in Settings to improve quiet curves and AI scheduling for this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Quiet Calibration", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.blue.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}

struct QuietCalibrationSummaryView: View {
    let store: FanControlStore
    @State private var showsCalibration = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: store.hasQuietCalibration ? "speaker.slash.fill" : "ear")
                    .font(.title2)
                    .foregroundStyle(store.hasQuietCalibration ? .green : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: L10n.string(
                        store.hasQuietCalibration ? "Calibrated for This Mac" : "Quiet Range Not Calibrated"
                    ))
                    .font(.headline)
                    Text(verbatim: store.quietRangeDescription)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("Measure the highest fan speed you cannot hear from your normal sitting position. On multi-fan Macs, choose a combined result or calibrate each fan separately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            if let profile = store.compatibleQuietCalibrationProfile {
                Label(
                    profile.resolvedMethod == .combined
                        ? "All fans were calibrated together."
                        : "Each limit applies only to that individual fan.",
                    systemImage: profile.resolvedMethod == .combined ? "fan" : "list.number"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(profile.fanLimits) { limit in
                    LabeledContent(limit.fanName) {
                        Text("\(Int(limit.quietRPM.rounded())) RPM")
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }

            HStack {
                if store.hasQuietCalibration {
                    Button("Reset Calibration", role: .destructive) {
                        store.resetQuietCalibration()
                    }
                }
                Spacer()
                Button {
                    showsCalibration = true
                } label: {
                    Text(verbatim: L10n.string(
                        store.hasQuietCalibration ? "Recalibrate" : "Calibrate Quiet Range"
                    ))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canControlFans || store.fans.isEmpty)
            }

            if !store.canControlFans {
                Label("Enable fan control before calibrating.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .sheet(isPresented: $showsCalibration) {
            QuietCalibrationView(store: store)
        }
    }
}

struct QuietCalibrationSettingsView: View {
    let store: FanControlStore

    var body: some View {
        Form {
            Section("Device Quiet Profile") {
                QuietCalibrationSummaryView(store: store)
            }

            Section("How AI Uses It") {
                Label(
                    "AI receives whether the limits were measured together or one fan at a time, and generates an independent curve for every fan.",
                    systemImage: "sparkles"
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct QuietCalibrationView: View {
    let store: FanControlStore
    @Environment(\.dismiss) private var dismiss

    private var fraction: Binding<Double> {
        Binding(
            get: { store.quietCalibrationFanFraction },
            set: store.updateQuietCalibrationFanFraction
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Quiet Fan Calibration", systemImage: "ear")
                .font(.title.bold())

            if store.isStartingQuietCalibration {
                ProgressView("Preparing fan control…")
                    .frame(maxWidth: .infinity, minHeight: 280)
            } else if store.isQuietCalibrationActive {
                activeCalibration
            } else if store.fans.count == 1 {
                ProgressView("Preparing single-fan calibration…")
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .task { store.beginQuietCalibration(method: .individual) }
            } else {
                methodSelection
            }
        }
        .padding(24)
        .frame(width: 680, height: 570)
        .onDisappear { store.cancelQuietCalibration() }
    }

    private var methodSelection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose what the saved quiet result should mean on this Mac.")
                .foregroundStyle(.secondary)

            calibrationChoice(
                title: "Calibrate All Fans Together",
                detail: "Run every fan at the same percentage. The saved result represents the combined sound of all fans running together.",
                icon: "fan",
                method: .combined
            )
            calibrationChoice(
                title: "Calibrate Fans One by One",
                detail: "Fankit guides you through each fan in order while holding the others at 0 RPM. Each saved limit belongs only to that fan.",
                icon: "list.number",
                method: .individual
            )

            Label(
                "An individual result does not mean the same speeds will remain inaudible when several fans run together.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
    }

    private func calibrationChoice(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        icon: String,
        method: QuietCalibrationMethod
    ) -> some View {
        Button {
            store.beginQuietCalibration(method: method)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 12))
        .disabled(!store.canControlFans || store.fans.isEmpty)
    }

    private var activeCalibration: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.quietCalibrationMethod == .individual, let fan = store.quietCalibrationCurrentFan {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Fan \(store.quietCalibrationStep) of \(store.fans.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: fan.name)
                            .font(.title3.bold())
                    }
                    Spacer()
                    ProgressView(
                        value: Double(store.quietCalibrationStep),
                        total: Double(store.fans.count)
                    )
                    .frame(width: 180)
                }
                Label(
                    "Other fans are held at 0 RPM. This result applies only to the selected fan.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label("All Fans Together", systemImage: "fan")
                    .font(.title3.bold())
                Text("The saved level represents all listed fans running together at these targets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Live fan demand").font(.headline)
                    Spacer()
                    Stepper(value: fraction, in: 0...1, step: 0.01) {
                        Text("\(Int((store.quietCalibrationFanFraction * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                Slider(value: fraction, in: 0...1, step: 0.01)
                    .accessibilityLabel("Live fan demand")
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("Fan").foregroundStyle(.secondary)
                    Text("Current").foregroundStyle(.secondary)
                    Text("Calibration Target").foregroundStyle(.secondary)
                    Text("Control Range").foregroundStyle(.secondary)
                }
                ForEach(store.fans) { fan in
                    GridRow {
                        Text(verbatim: fan.name)
                        Text("\(Int(fan.currentRPM.rounded())) RPM").monospacedDigit()
                        Text("\(Int((store.quietCalibrationTargetRPMs[fan.index] ?? 0).rounded())) RPM")
                            .monospacedDigit()
                        Text("0–\(Int(fan.maximumRPM.rounded())) RPM")
                            .monospacedDigit()
                    }
                }
            }
            .font(.callout)

            Label("Adjust to the highest level that remains inaudible from your normal sitting position.", systemImage: "ear")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = store.quietCalibrationMessage {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            HStack {
                Button("Cancel", role: .cancel) {
                    store.cancelQuietCalibration()
                    dismiss()
                }
                Spacer()
                Button {
                    if store.captureAndAdvanceQuietCalibration() { dismiss() }
                } label: {
                    if store.quietCalibrationMethod == .combined {
                        Text("Save Combined Calibration")
                    } else if let fan = store.quietCalibrationCurrentFan {
                        Text(verbatim: L10n.string(
                            store.quietCalibrationIsLastFan
                                ? "Save This Fan and Finish"
                                : "Save This Fan and Continue"
                        ) + " · " + fan.name)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
