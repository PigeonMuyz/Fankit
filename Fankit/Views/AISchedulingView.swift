import AppKit
import Charts
import SwiftUI

struct AISchedulingView: View {
    let store: FanControlStore

    @State private var aiResponse = ""
    @State private var promptWasCopied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                intro

                if store.isLoadingAIState {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if let session = store.aiCaptureSession {
                    recordingView(session)
                } else if let preview = store.aiPreviewProfile {
                    previewView(preview)
                } else if let session = store.latestAICaptureSession {
                    reviewView(session)
                } else {
                    emptyObservationView
                }

                if let error = store.aiCaptureError {
                    errorBanner(error)
                }
            }
            .padding(24)
        }
        .navigationTitle("AI Scheduling")
        .onAppear {
            store.beginAICaptureIfNeeded()
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                L10n.string("AI Scheduling Guide"),
                systemImage: "sparkles"
            )
            .font(.largeTitle.bold())

            Text(verbatim: L10n.string("Observe your Mac before asking AI"))
                .font(.title3.weight(.medium))
            Text(verbatim: L10n.string(
                "Fankit records System scheduling data locally, then lets you copy a safe summary to an AI you trust. AI output is previewed and validated before it can control fans."
            ))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let activeAICurve = store.activeAICurve {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.purple)
                    Text(verbatim: L10n.format("Current AI schedule: %@", activeAICurve.localizedName))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Button {
                        store.selectMode(.aiScheduling)
                    } label: {
                        Text(verbatim: L10n.string("Enable AI Scheduling"))
                    }
                    .disabled(!store.canControlFans)
                }
                .padding(12)
                .background(.purple.opacity(0.1), in: .rect(cornerRadius: 10))
            }
        }
    }

    private func recordingView(_ session: AICaptureSession) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label(
                        L10n.string("System Observation"),
                        systemImage: "waveform.path.ecg"
                    )
                    .font(.title3.weight(.semibold))
                    Spacer()
                    Text(verbatim: L10n.string("Recording"))
                        .foregroundStyle(.green)
                        .font(.callout.weight(.medium))
                }

                HStack(spacing: 20) {
                    AIInfoTile(
                        title: L10n.string("Elapsed"),
                        value: durationText(session.duration),
                        systemImage: "timer"
                    )
                    AIInfoTile(
                        title: L10n.string("Samples"),
                        value: "\(session.sampleCount)",
                        systemImage: "chart.xyaxis.line"
                    )
                    AIInfoTile(
                        title: L10n.string("Limit"),
                        value: L10n.string("24 hours"),
                        systemImage: "clock"
                    )
                }

                ProgressView(value: min(session.duration / AIObservationRecorder.maximumDuration, 1))
                    .tint(.blue)

                Text(verbatim: L10n.string(
                    "Fankit is keeping macOS in control and saving one observation about every 10 seconds. You can stop now or leave it running; it ends automatically after 24 hours."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    Button(role: .cancel) {
                        store.finishAICapture()
                    } label: {
                        Text(verbatim: L10n.string("Stop and Review"))
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var emptyObservationView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label(
                    L10n.string("No System Observation"),
                    systemImage: "waveform.path.ecg"
                )
                .font(.title3.weight(.semibold))
                Text(verbatim: L10n.string(
                    "Start a System observation to collect enough temperature and fan data for an AI recommendation. The maximum recording length is 24 hours."
                ))
                .foregroundStyle(.secondary)
                Button {
                    store.startAICapture()
                } label: {
                    Text(verbatim: L10n.string("Start System Observation"))
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func reviewView(_ session: AICaptureSession) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if let summary = store.aiCaptureSummary {
                summaryView(summary, session: session)
            }
            promptView
            responseView
        }
    }

    private func summaryView(_ summary: AICaptureSummary, session: AICaptureSession) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label(
                    L10n.string("Observation Summary"),
                    systemImage: "chart.xyaxis.line"
                )
                .font(.title3.weight(.semibold))

                HStack(spacing: 20) {
                    AIInfoTile(
                        title: L10n.string("Duration"),
                        value: durationText(summary.duration),
                        systemImage: "timer"
                    )
                    AIInfoTile(
                        title: L10n.string("Valid Samples"),
                        value: "\(summary.validSampleCount)/\(summary.sampleCount)",
                        systemImage: "checkmark.circle"
                    )
                    AIInfoTile(
                        title: L10n.string("Longest Gap"),
                        value: summary.longestGap.map { durationText($0) } ?? "—",
                        systemImage: "pause.circle"
                    )
                }

                if !summary.isUsefulForPrompt {
                    Label(
                        L10n.string("This observation is short, but you can still generate a prompt. A longer observation usually gives AI better context."),
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)
                }

                if !summary.temperatures.isEmpty {
                    AIObservationChart(session: session)

                    Text(verbatim: L10n.string("Temperature Summary"))
                        .font(.headline)
                    ForEach(summary.temperatures) { statistic in
                        statisticRow(
                            title: statistic.title,
                            detail: L10n.format(
                                "Min %@ · Avg %@ · P95 %@ · Max %@",
                                number(statistic.minimum),
                                number(statistic.average),
                                number(statistic.p95),
                                number(statistic.maximum)
                            ),
                            suffix: statistic.suffix
                        )
                    }
                }

                if !summary.fans.isEmpty {
                    Text(verbatim: L10n.string("Fan Summary"))
                        .font(.headline)
                    ForEach(summary.fans) { statistic in
                        statisticRow(
                            title: statistic.name,
                            detail: L10n.format(
                                "Min %@ · Avg %@ · Max %@ · Range %@",
                                number(statistic.minimum, digits: 0),
                                number(statistic.average, digits: 0),
                                number(statistic.maximum, digits: 0),
                                statistic.hardwareRange
                            ),
                            suffix: "RPM"
                        )
                    }
                }

                HStack {
                    Button {
                        store.discardLatestAICapture()
                        store.startAICapture()
                    } label: {
                        Text(verbatim: L10n.string("Start New Observation"))
                    }
                    Spacer()
                    Button(role: .destructive) {
                        store.discardLatestAICapture()
                    } label: {
                        Text(verbatim: L10n.string("Discard Observation"))
                    }
                }
            }
        }
    }

    private var promptView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(
                        L10n.string("Prompt for Your Trusted AI"),
                        systemImage: "doc.on.clipboard"
                    )
                    .font(.title3.weight(.semibold))
                    Spacer()
                    Button {
                        copyPrompt()
                    } label: {
                        Label(
                            L10n.string(promptWasCopied ? "Prompt Copied" : "Copy Prompt"),
                            systemImage: promptWasCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                }

                Text(verbatim: L10n.string(
                    "Copy this prompt to an AI you trust. Fankit does not send this data anywhere."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)

                TextEditor(text: .constant(store.aiPrompt ?? ""))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 230, maxHeight: 340)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
                    .textSelection(.enabled)
            }
        }
    }

    private var responseView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    L10n.string("Paste AI Response"),
                    systemImage: "arrow.down.doc"
                )
                .font(.title3.weight(.semibold))
                Text(verbatim: L10n.string(
                    "Ask the AI to return only the Fankit JSON format shown in the prompt. Fankit will never execute commands from the response."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)

                TextEditor(text: $aiResponse)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180, maxHeight: 260)
                    .padding(8)
                    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))

                if let error = store.aiPreviewError {
                    errorBanner(error)
                }

                HStack {
                    Spacer()
                    Button {
                        store.previewAIResponse(aiResponse)
                    } label: {
                        Text(verbatim: L10n.string("Preview AI Result"))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(aiResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func previewView(_ profile: ThermalCurveProfile) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label(
                            L10n.string("AI Schedule Preview"),
                            systemImage: "sparkles"
                        )
                        .font(.title3.weight(.semibold))
                        Spacer()
                        Text(verbatim: L10n.string("Not Enabled"))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)
                    }

                    Text(verbatim: profile.name)
                        .font(.headline)
                    Text(verbatim: profile.summary)
                        .foregroundStyle(.secondary)

                    AIScheduleCurveChart(profile: profile)
                        .frame(height: 220)

                    ForEach(profile.normalizedPoints) { point in
                        HStack {
                            Text(verbatim: "\(Int(point.temperature.rounded()))°C")
                                .monospacedDigit()
                            Spacer()
                            Text(verbatim: "\(Int((point.fanFraction * 100).rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.blue)
                        }
                        .font(.callout)
                    }

                    Label(
                        L10n.string("Fankit will enforce hardware limits, ramp limits, hysteresis, and emergency cooling."),
                        systemImage: "checkmark.shield"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            store.clearAIPreview()
                        } label: {
                            Text(verbatim: L10n.string("Return to Response"))
                        }
                        Spacer()
                        Button {
                            store.saveAIPreview()
                        } label: {
                            Text(verbatim: L10n.string("Save for Later"))
                        }
                        Button {
                            store.saveAndEnableAIPreview()
                        } label: {
                            Text(verbatim: L10n.string("Save and Enable AI Scheduling"))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!store.canControlFans)
                    }
                }
            }
        }
    }

    private func statisticRow(title: String, detail: String, suffix: String) -> some View {
        HStack {
            Text(verbatim: title)
                .fontWeight(.medium)
            Spacer()
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: suffix)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label {
            Text(verbatim: message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
    }

    private func copyPrompt() {
        guard let prompt = store.aiPrompt else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        promptWasCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            promptWasCopied = false
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return String(format: "%02d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func number(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.*f", digits, value)
    }
}

private struct AIInfoTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AIObservationChart: View {
    let session: AICaptureSession

    private var samples: [AICaptureSample] {
        session.samples.sorted { $0.timestamp < $1.timestamp }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: L10n.string("Observation Timeline"))
                .font(.headline)

            Chart {
                ForEach(samples) { sample in
                    if let temperature = sample.hottestTemperature {
                        LineMark(
                            x: .value("Time (min)", minutes(from: sample)),
                            y: .value("Temperature (°C)", temperature)
                        )
                        .foregroundStyle(.orange)
                        .interpolationMethod(.linear)
                    }
                }
            }
            .chartYAxisLabel(L10n.string("Temperature (°C)"))
            .chartLegend(.hidden)
            .frame(height: 130)

            Chart {
                ForEach(samples) { sample in
                    if let rpm = sample.fans.map(\.currentRPM).max() {
                        LineMark(
                            x: .value("Time (min)", minutes(from: sample)),
                            y: .value("Fan Speed (RPM)", rpm)
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.linear)
                    }
                }
            }
            .chartYAxisLabel(L10n.string("Fan Speed (RPM)"))
            .chartLegend(.hidden)
            .frame(height: 130)
        }
    }

    private func minutes(from sample: AICaptureSample) -> Double {
        sample.timestamp.timeIntervalSince(session.startedAt) / 60
    }
}

private struct AIScheduleCurveChart: View {
    let profile: ThermalCurveProfile

    var body: some View {
        Chart {
            ForEach(profile.normalizedPoints) { point in
                AreaMark(
                    x: .value("Temperature", point.temperature),
                    y: .value("Fan demand", point.fanFraction * 100)
                )
                .foregroundStyle(.purple.opacity(0.14))
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Temperature", point.temperature),
                    y: .value("Fan demand", point.fanFraction * 100)
                )
                .foregroundStyle(.purple)
                .lineStyle(.init(lineWidth: 2))

                PointMark(
                    x: .value("Temperature", point.temperature),
                    y: .value("Fan demand", point.fanFraction * 100)
                )
                .foregroundStyle(.purple)
            }
        }
        .chartXScale(domain: 35...100)
        .chartYScale(domain: 0...100)
        .chartLegend(.hidden)
    }
}
