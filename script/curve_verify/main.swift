import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("Curve verification failed: \(message)\n", stderr)
        exit(1)
    }
}

let balanced = ThermalCurveProfile.balanced
expect(balanced.fanFraction(at: 40) == nil, "temperatures below activation must stay in System")
expect(abs((balanced.fanFraction(at: 52) ?? 0) - 0.15) < 0.0001, "first point")
expect(abs((balanced.fanFraction(at: 69) ?? 0) - 0.425) < 0.0001, "linear interpolation")
expect(abs((balanced.fanFraction(at: 96) ?? 0) - 1) < 0.0001, "maximum endpoint")
expect(
    ThermalCurveProfile.targetRPM(for: 0, minimumRPM: 2_000, maximumRPM: 6_000) == 0,
    "zero-percent demand must request a true zero RPM target"
)
expect(
    ThermalCurveProfile.targetRPM(for: 0.01, minimumRPM: 2_000, maximumRPM: 6_000) == 2_040,
    "positive demand must stay within the reported running range"
)
expect(
    ThermalCurveProfile.targetRPM(for: 1, minimumRPM: 2_000, maximumRPM: 6_000) == 6_000,
    "full demand must request maximum RPM"
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

var clickable = ThermalCurveProfile.balanced
let added = clickable.coarseAdjust(temperature: 69.4, fanFraction: 0.47)
expect(added == .added(temperature: 69, fanFraction: 0.47), "chart click should preserve one-percent precision")
expect(clickable.points.count == 6, "chart click should add one point")
let moved = clickable.coarseAdjust(temperature: 70.2, fanFraction: 0.62)
expect(moved == .moved(temperature: 70, fanFraction: 0.62), "nearby chart click should preserve one-percent precision")
expect(clickable.points.count == 6, "moving a point must not change point count")

var draggable = ThermalCurveProfile.balanced
let draggedID = draggable.normalizedPoints[2].id
let dragged = draggable.movePoint(id: draggedID, temperature: 79.6, fanFraction: 0.72)
expect(dragged?.temperature == 80, "dragging should round the point temperature")
expect(dragged?.fanFraction == 0.72, "dragging should round fan demand to one-percent steps")
expect(draggable.points.count == 5, "dragging an existing point must not add a point")

let constrained = draggable.movePoint(id: draggedID, temperature: 99, fanFraction: 0.01)
expect(constrained?.temperature == 83, "a dragged point must not cross its next neighbor")
expect(constrained?.fanFraction == 0.3, "a dragged point must not fall below its previous neighbor")
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
