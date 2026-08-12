import Charts
import SwiftUI

struct ThermalCurveView: View {
    let store: FanControlStore
    let compact: Bool
    @AppStorage("curveShowCurrentTemperature") private var showCurrentTemperature = true
    @AppStorage("curveShowRecommendedQuietRange") private var showRecommendedQuietRange = true

    private var profileSelection: Binding<String> {
        Binding(
            get: {
                store.selectedMode == .aiScheduling
                    ? (store.activeAICurveID ?? "")
                    : store.activeCurveID
            },
            set: {
                if store.selectedMode == .aiScheduling {
                    store.selectAICurve($0)
                } else {
                    store.selectCurve($0)
                }
            }
        )
    }

    private var displayedFanIndex: Int? {
        store.activeScheduleCurve.fanCurves == nil ? nil : store.fans.sorted { $0.index < $1.index }.first?.index
    }

    private var displayedProfile: ThermalCurveProfile {
        store.activeScheduleCurve.displayProfile(for: displayedFanIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Temperature Curve", systemImage: "chart.xyaxis.line")
                    .font(.title3.bold())
                Spacer()
                if store.isCurveMode {
                    Label(
                        store.isCurveOverrideActive ? "Controlling" : "System",
                        systemImage: store.isCurveOverrideActive ? "fan.fill" : "checkmark.circle"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(store.isCurveOverrideActive ? .blue : .secondary)
                }
            }

            Picker("Preset", selection: profileSelection) {
                ForEach(store.selectedMode == .aiScheduling ? store.aiProfiles : store.curveProfiles.filter { !$0.isAIGenerated }) { profile in
                    if let kind = profile.aiPresetKind {
                        Text(verbatim: "\(kind.title) · \(profile.name)").tag(profile.id)
                    } else {
                        Text(profile.isBuiltIn ? profile.localizedName : "★ \(profile.name)").tag(profile.id)
                    }
                }
            }

            Text(verbatim: store.activeScheduleCurve.localizedSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if store.activeScheduleCurve.fanCurves != nil {
                Label("This preset controls each fan independently.", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            CurveChart(
                profile: displayedProfile,
                currentTemperature: store.displayedCurveTemperature,
                quietFanFraction: store.quietFanFraction(for: displayedFanIndex),
                quietRangeDescription: store.quietRangeDescription,
                showCurrentTemperature: $showCurrentTemperature,
                showRecommendedQuietRange: $showRecommendedQuietRange
            )
            .frame(height: compact ? 115 : 170)

            HStack(spacing: 14) {
                Label(
                    "System below \(Int(store.activeScheduleCurve.activationTemperature))°C",
                    systemImage: "arrow.uturn.backward.circle"
                )
                if showCurrentTemperature, let temperature = store.displayedCurveTemperature {
                    Label(
                        store.isCurveMode
                            ? "\(Int(temperature.rounded()))°C control input"
                            : "\(Int(temperature.rounded()))°C current temperature",
                        systemImage: "thermometer.medium"
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if store.isCurveMode {
                Text(verbatim: store.curveStatus)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(compact ? 0 : 18)
        .background(
            compact ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial),
            in: .rect(cornerRadius: 14)
        )
    }
}

struct CurveEditorView: View {
    let store: FanControlStore
    let openQuietCalibration: () -> Void
    @State private var newPresetName = ""
    @State private var selectedFanIndex: Int?
    @AppStorage("curveShowCurrentTemperature") private var showCurrentTemperature = true
    @AppStorage("curveShowRecommendedQuietRange") private var showRecommendedQuietRange = true

    private var profileSelection: Binding<String> {
        Binding(get: { store.activeCurveID }, set: store.selectCurve)
    }

    private var editingProfile: ThermalCurveProfile {
        store.curveProfile(for: selectedFanIndex)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Fan Curve Editor")
                        .font(.largeTitle.bold())
                    Text("Drag an existing point to shape the curve, or click empty space to add a point.")
                        .foregroundStyle(.secondary)
                }

                if !store.hasQuietCalibration {
                    QuietCalibrationRecommendationView(openSettings: openQuietCalibration)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Picker("Editing preset", selection: profileSelection) {
                                ForEach(store.curveProfiles.filter { !$0.isAIGenerated }) { profile in
                                    Text(profile.isBuiltIn ? profile.localizedName : "★ \(profile.name)").tag(profile.id)
                                }
                            }
                            Spacer()
                            Text(store.activeCurve.isBuiltIn ? "Built-in" : "Custom")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(store.activeCurve.isBuiltIn ? Color.secondary : Color.blue)
                        }

                        if store.fans.count > 1 {
                            Picker("Curve to edit", selection: $selectedFanIndex) {
                                Text("All Fans · Shared").tag(Int?.none)
                                ForEach(store.fans.sorted { $0.index < $1.index }) { fan in
                                    Text(verbatim: fan.name).tag(Optional(fan.index))
                                }
                            }
                            .pickerStyle(.segmented)

                            HStack {
                                if let selectedFanIndex {
                                    Label(
                                        store.activeCurve.hasIndependentCurve(for: selectedFanIndex)
                                            ? "This fan has an independent curve."
                                            : "This fan currently follows the shared curve. Editing creates an independent curve.",
                                        systemImage: store.activeCurve.hasIndependentCurve(for: selectedFanIndex)
                                            ? "slider.horizontal.3"
                                            : "link"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    Spacer()
                                    if store.activeCurve.hasIndependentCurve(for: selectedFanIndex) {
                                        Button("Reset to Shared") {
                                            store.resetIndependentCurve(for: selectedFanIndex)
                                        }
                                    }
                                } else {
                                    Label(
                                        "The shared curve is the fallback for fans without an independent curve.",
                                        systemImage: "link"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }

                        CurveChart(
                            profile: editingProfile,
                            currentTemperature: store.displayedCurveTemperature,
                            quietFanFraction: store.quietFanFraction(for: selectedFanIndex),
                            quietRangeDescription: store.quietRangeDescription,
                            showCurrentTemperature: $showCurrentTemperature,
                            showRecommendedQuietRange: $showRecommendedQuietRange,
                            onAddPoint: { temperature, fanFraction in
                                store.addCurvePoint(
                                    temperature: temperature,
                                    fanFraction: fanFraction,
                                    fanIndex: selectedFanIndex
                                )
                            },
                            onMovePoint: { id, temperature, fanFraction in
                                store.dragCurvePoint(
                                    id: id,
                                    temperature: temperature,
                                    fanFraction: fanFraction,
                                    fanIndex: selectedFanIndex
                                )
                            },
                            onFinishMovingPoint: { id in
                                store.finishDraggingCurvePoint(id: id, fanIndex: selectedFanIndex)
                            }
                        )
                        .frame(height: 300)

                        Label(
                            "Drag a point for coarse adjustment. Click empty space to add a new point.",
                            systemImage: "arrow.up.and.down.and.arrow.left.and.right"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if let message = store.curveEditorMessage {
                            Label {
                                Text(verbatim: message)
                            } icon: {
                                Image(systemName: "checkmark.circle")
                            }
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Preset Library") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            TextField("New preset name", text: $newPresetName)
                            Button("Save as New Preset", systemImage: "square.and.arrow.down") {
                                store.saveCurveAsPreset(named: newPresetName)
                                newPresetName = ""
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if !store.activeCurve.isBuiltIn {
                            HStack {
                                TextField("Current preset name", text: Binding(
                                    get: { store.activeCurve.name },
                                    set: store.renameCustomCurve
                                ))
                                Button("Delete Preset", systemImage: "trash", role: .destructive) {
                                    store.deleteActiveCustomCurve()
                                }
                            }
                        } else {
                            Label(
                                "Built-in presets are read-only. Editing one automatically creates a saved custom copy.",
                                systemImage: "lock.open"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Precise Curve Points") {
                    CurvePointEditor(store: store, fanIndex: selectedFanIndex)
                        .padding(6)
                }
            }
            .padding(24)
        }
        .navigationTitle(L10n.string("Curve Editor"))
    }
}

private struct CurveChart: View {
    let profile: ThermalCurveProfile
    let currentTemperature: Double?
    let quietFanFraction: Double?
    let quietRangeDescription: String
    @Binding var showCurrentTemperature: Bool
    @Binding var showRecommendedQuietRange: Bool
    var onAddPoint: ((Double, Double) -> Void)?
    var onMovePoint: ((UUID, Double, Double) -> Void)?
    var onFinishMovingPoint: ((UUID) -> Void)?

    @State private var selectedPointID: UUID?
    @State private var draggingPointID: UUID?

    var body: some View {
        Chart {
            ForEach(profile.normalizedPoints) { point in
                AreaMark(
                    x: .value("Temperature", point.temperature),
                    y: .value("Fan demand", point.fanFraction * 100)
                )
                .foregroundStyle(.linearGradient(
                    colors: [.blue.opacity(0.25), .blue.opacity(0.03)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Temperature", point.temperature),
                    y: .value("Fan demand", point.fanFraction * 100)
                )
                .interpolationMethod(.linear)
                .foregroundStyle(.blue)
                .lineStyle(.init(lineWidth: 2))

                PointMark(
                    x: .value("Temperature", point.temperature),
                    y: .value("Fan demand", point.fanFraction * 100)
                )
                .foregroundStyle(selectedPointID == point.id ? .orange : .blue)
                .symbolSize(selectedPointID == point.id ? 115 : 70)

                if selectedPointID == point.id {
                    PointMark(
                        x: .value("Selected temperature", point.temperature),
                        y: .value("Selected fan demand", point.fanFraction * 100)
                    )
                    .foregroundStyle(.clear)
                    .annotation(position: .top) {
                        Text("\(Int(point.temperature))°C · \(Int((point.fanFraction * 100).rounded()))%")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: .capsule)
                    }
                }
            }

            if showRecommendedQuietRange, let quietFanFraction {
                RectangleMark(
                    yStart: .value("Quiet range start", 0),
                    yEnd: .value("Quiet range end", quietFanFraction * 100)
                )
                .foregroundStyle(.green.opacity(0.055))

                RuleMark(y: .value("Quiet fan limit", quietFanFraction * 100))
                    .foregroundStyle(.green.opacity(0.85))
                    .lineStyle(.init(lineWidth: 1.5, dash: [6, 4]))
                    .annotation(position: .top, alignment: .trailing) {
                        Label(quietRangeDescription, systemImage: "speaker.slash.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: .capsule)
                    }
            }

            if showCurrentTemperature, let currentTemperature {
                RuleMark(x: .value("Current", currentTemperature))
                    .foregroundStyle(.orange)
                    .lineStyle(.init(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("\(Int(currentTemperature.rounded()))°")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
            }
        }
        .chartXScale(domain: 35...100)
        .chartYScale(domain: 0...100)
        .chartXAxisLabel("Temperature (°C)")
        .chartYAxisLabel("Fan (%)")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if onAddPoint != nil || onMovePoint != nil {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if draggingPointID == nil {
                                        draggingPointID = nearestPointID(
                                            to: value.startLocation,
                                            proxy: proxy,
                                            geometry: geometry
                                        )
                                        if let draggingPointID {
                                            selectedPointID = draggingPointID
                                        }
                                    }

                                    guard let draggingPointID,
                                          let values = chartValues(
                                            at: value.location,
                                            proxy: proxy,
                                            geometry: geometry
                                          )
                                    else { return }
                                    onMovePoint?(draggingPointID, values.temperature, values.fanFraction)
                                }
                                .onEnded { value in
                                    if let draggingPointID {
                                        if let values = chartValues(
                                            at: value.location,
                                            proxy: proxy,
                                            geometry: geometry
                                        ) {
                                            onMovePoint?(draggingPointID, values.temperature, values.fanFraction)
                                        }
                                        onFinishMovingPoint?(draggingPointID)
                                    } else if hypot(value.translation.width, value.translation.height) < 5,
                                              let values = chartValues(
                                                at: value.location,
                                                proxy: proxy,
                                                geometry: geometry
                                              )
                                    {
                                        selectedPointID = nil
                                        onAddPoint?(values.temperature, values.fanFraction)
                                    }
                                    draggingPointID = nil
                                }
                        )
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            CurveMarkerOptionsMenu(
                showCurrentTemperature: $showCurrentTemperature,
                showRecommendedQuietRange: $showRecommendedQuietRange
            )
            .padding(.top, 2)
            .padding(.trailing, 4)
        }
        .accessibilityLabel(
            Text(verbatim: L10n.format("Fan curve for %@", profile.localizedName))
        )
    }

    private func nearestPointID(
        to location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> UUID? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        return profile.normalizedPoints
            .compactMap { point -> (UUID, CGFloat)? in
                guard let x = proxy.position(forX: point.temperature),
                      let y = proxy.position(forY: point.fanFraction * 100)
                else { return nil }
                let distance = hypot(
                    location.x - (frame.origin.x + x),
                    location.y - (frame.origin.y + y)
                )
                return (point.id, distance)
            }
            .filter { $0.1 <= 16 }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func chartValues(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> (temperature: Double, fanFraction: Double)? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        let plotPoint = CGPoint(
            x: location.x - frame.origin.x,
            y: location.y - frame.origin.y
        )
        guard plotPoint.x >= 0, plotPoint.x <= frame.width,
              plotPoint.y >= 0, plotPoint.y <= frame.height,
              let temperature: Double = proxy.value(atX: plotPoint.x),
              let percentage: Double = proxy.value(atY: plotPoint.y)
        else { return nil }
        return (temperature, percentage / 100)
    }
}

private struct CurveMarkerOptionsMenu: View {
    @Binding var showCurrentTemperature: Bool
    @Binding var showRecommendedQuietRange: Bool

    var body: some View {
        Menu {
            Toggle(isOn: $showCurrentTemperature) {
                Label("Current Temperature", systemImage: "thermometer.medium")
            }
            Toggle(isOn: $showRecommendedQuietRange) {
                Label("Recommended Quiet Range", systemImage: "speaker.slash.fill")
            }
        } label: {
            Label("Chart Markers", systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .help("Choose chart markers")
        .accessibilityLabel("Chart marker options")
    }
}

private struct CurvePointEditor: View {
    let store: FanControlStore
    let fanIndex: Int?

    private var profile: ThermalCurveProfile { store.curveProfile(for: fanIndex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(profile.points.count) of 8 points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Add Point", systemImage: "plus") {
                    store.addCurvePoint(fanIndex: fanIndex)
                }
                .disabled(profile.points.count >= 8)
            }

            ForEach(profile.normalizedPoints) { point in
                HStack(spacing: 14) {
                    Stepper(
                        value: Binding(
                            get: { point.temperature },
                            set: { store.updateCurvePoint(id: point.id, temperature: $0, fanIndex: fanIndex) }
                        ),
                        in: 35...100,
                        step: 1
                    ) {
                        Text("\(Int(point.temperature))°C")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .leading)
                    }

                    Slider(
                        value: Binding(
                            get: { point.fanFraction },
                            set: { store.updateCurvePoint(id: point.id, fanFraction: $0, fanIndex: fanIndex) }
                        ),
                        in: 0...1,
                        step: 0.01
                    )

                    Text("\(Int((point.fanFraction * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)

                    Button("Remove", systemImage: "minus.circle") {
                        store.removeCurvePoint(id: point.id, fanIndex: fanIndex)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(profile.points.count <= 2)
                }
            }

            Label(
                "0% requests 0 RPM on supported hardware.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
