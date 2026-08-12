import Foundation

enum L10n {
    static func string(_ key: String) -> String { key }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("Curve verification failed: \(message)\n", stderr)
        exit(1)
    }
}

let balanced = ThermalCurveProfile.balanced
expect(balanced.fanFraction(at: 40) == nil, "temperatures below activation must stay in System")
expect(abs((balanced.fanFraction(at: 44) ?? 0) - 0.28) < 0.0001, "first point")
expect(abs((balanced.fanFraction(at: 61) ?? 0) - 0.59) < 0.0001, "linear interpolation")
expect(abs((balanced.fanFraction(at: 90) ?? 0) - 1) < 0.0001, "maximum endpoint")
expect(ThermalCurveProfile.presets.count == 3, "the built-in library contains exactly three presets")
expect(
    ThermalCurveProfile.presets.map(\.id) == ["builtin.quiet", "builtin.balanced", "builtin.performance"],
    "the built-in library exposes quiet, balanced, and performance in order"
)
expect(
    ThermalCurveProfile.quiet.activationTemperature < 50
        && ThermalCurveProfile.balanced.activationTemperature < ThermalCurveProfile.quiet.activationTemperature
        && ThermalCurveProfile.performance.activationTemperature < ThermalCurveProfile.balanced.activationTemperature,
    "more performance-oriented presets activate cooling progressively earlier"
)
let calibratedQuietPoints = ThermalCurveProfile.quiet.quietHeadroomPoints(
    calibratedFraction: 0.40
)
expect(
    abs(calibratedQuietPoints[0].fanFraction - 0.30) < 0.0001,
    "calibrated quiet headroom is introduced gradually at activation"
)
expect(
    abs(calibratedQuietPoints[1].fanFraction - 0.40) < 0.0001,
    "the quiet preset uses the full safe calibrated demand after activation"
)
expect(
    zip(calibratedQuietPoints, calibratedQuietPoints.dropFirst()).allSatisfy {
        $0.fanFraction <= $1.fanFraction
    },
    "calibrated quiet headroom preserves monotonic demand"
)
expect(
    ThermalCurveProfile.targetRPM(for: 0, maximumRPM: 6_000) == 0,
    "zero-percent demand must request a true zero RPM target"
)
expect(
    ThermalCurveProfile.targetRPM(for: 0.01, maximumRPM: 6_000) == 60,
    "positive demand must map from zero instead of the reported minimum"
)
expect(
    ThermalCurveProfile.targetRPM(for: 1, maximumRPM: 6_000) == 5_999,
    "full demand must stay one RPM below the firmware boundary"
)
let asymmetricMaximumTargets = [
    ThermalCurveProfile.targetRPM(for: 1, maximumRPM: 5_779),
    ThermalCurveProfile.targetRPM(for: 1, maximumRPM: 6_241),
]
expect(
    asymmetricMaximumTargets == [5_778, 6_240],
    "paired fans must retain independent safe maximum targets"
)

let unsafe = ThermalCurveProfile(
    id: "test",
    name: "Test",
    summary: "",
    points: [
        .init(temperature: 80, fanFraction: 0.2),
        .init(temperature: 60, fanFraction: 0.8),
        .init(temperature: 80, fanFraction: 0.5),
    ],
    isBuiltIn: false
).validated()
expect(unsafe.points.count == 2, "duplicate temperatures must merge")
expect(unsafe.points[1].fanFraction >= unsafe.points[0].fanFraction, "fan demand must not fall as temperature rises")

let encoded = try JSONEncoder().encode(ThermalCurveProfile.defaultCustom)
let decoded = try JSONDecoder().decode(ThermalCurveProfile.self, from: encoded)
expect(decoded.points.count == ThermalCurveProfile.defaultCustom.points.count, "custom curve persistence")

let independent = ThermalCurveProfile(
    id: "independent",
    name: "Independent",
    summary: "",
    points: ThermalCurveProfile.balanced.points,
    isBuiltIn: false,
    fanCurves: [
        FanSpecificCurve(
            fanIndex: 1,
            fanName: "Right",
            points: [
                .init(temperature: 42, fanFraction: 0.2),
                .init(temperature: 75, fanFraction: 0.8),
            ]
        ),
    ]
).validated()
expect(independent.fanFraction(at: 42, fanIndex: 0) == nil, "fans without overrides use the shared curve")
expect(independent.fanFraction(at: 42, fanIndex: 1) == 0.2, "fan overrides activate independently")
expect(independent.activationTemperature == 42, "runtime activation uses the earliest fan curve")
let independentData = try JSONEncoder().encode(independent)
let decodedIndependent = try JSONDecoder().decode(ThermalCurveProfile.self, from: independentData)
expect(decodedIndependent.fanCurves?.first?.fanIndex == 1, "independent fan curves persist")

var clickable = ThermalCurveProfile.balanced
let added = clickable.coarseAdjust(temperature: 61.4, fanFraction: 0.57)
expect(added == .added(temperature: 61, fanFraction: 0.57), "chart click should preserve one-percent precision")
expect(clickable.points.count == 6, "chart click should add one point")
let moved = clickable.coarseAdjust(temperature: 62.2, fanFraction: 0.62)
expect(moved == .moved(temperature: 62, fanFraction: 0.62), "nearby chart click should preserve one-percent precision")
expect(clickable.points.count == 6, "moving a point must not change point count")

var draggable = ThermalCurveProfile.balanced
let draggedID = draggable.normalizedPoints[2].id
let dragged = draggable.movePoint(id: draggedID, temperature: 70.6, fanFraction: 0.78)
expect(dragged?.temperature == 71, "dragging should round the point temperature")
expect(dragged?.fanFraction == 0.78, "dragging should round fan demand to one-percent steps")
expect(draggable.points.count == 5, "dragging an existing point must not add a point")

let constrained = draggable.movePoint(id: draggedID, temperature: 99, fanFraction: 0.01)
expect(constrained?.temperature == 75, "a dragged point must not cross its next neighbor")
expect(constrained?.fanFraction == 0.48, "a dragged point must not fall below its previous neighbor")
expect(zip(draggable.normalizedPoints, draggable.normalizedPoints.dropFirst()).allSatisfy {
    $0.temperature < $1.temperature && $0.fanFraction <= $1.fanFraction
}, "dragging must preserve a valid monotonic curve")

var zeroDemand = ThermalCurveProfile(
    id: "zero",
    name: "Zero",
    summary: "",
    points: [
        .init(temperature: 50, fanFraction: 0),
        .init(temperature: 80, fanFraction: 0.5),
    ],
    isBuiltIn: false
).validated()
expect(zeroDemand.points.first?.fanFraction == 0, "validation must preserve zero-percent fan demand")
let zeroDragged = zeroDemand.movePoint(
    id: zeroDemand.normalizedPoints[0].id,
    temperature: 50,
    fanFraction: 0
)
expect(zeroDragged?.fanFraction == 0, "the first point must be draggable to zero percent")

let presetLibrary = [ThermalCurveProfile.defaultCustom, clickable]
let libraryData = try JSONEncoder().encode(presetLibrary)
let decodedLibrary = try JSONDecoder().decode([ThermalCurveProfile].self, from: libraryData)
expect(decodedLibrary.count == 2, "multiple named presets must persist")

print("Curve verification passed")
