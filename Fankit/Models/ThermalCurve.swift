import Foundation

struct ThermalCurvePoint: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var temperature: Double
    var fanFraction: Double

    init(id: UUID = UUID(), temperature: Double, fanFraction: Double) {
        self.id = id
        self.temperature = temperature
        self.fanFraction = fanFraction
    }
}

struct FanSpecificCurve: Codable, Hashable, Identifiable, Sendable {
    var fanIndex: Int
    var fanName: String
    var points: [ThermalCurvePoint]

    var id: Int { fanIndex }
}

struct ThermalCurveProfile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var summary: String
    var points: [ThermalCurvePoint]
    var isBuiltIn: Bool
    var fanCurves: [FanSpecificCurve]?

    init(
        id: String,
        name: String,
        summary: String,
        points: [ThermalCurvePoint],
        isBuiltIn: Bool,
        fanCurves: [FanSpecificCurve]? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.points = points
        self.isBuiltIn = isBuiltIn
        self.fanCurves = fanCurves
    }

    var localizedName: String {
        isBuiltIn ? L10n.string(name) : name
    }

    var localizedSummary: String {
        L10n.string(summary)
    }

    var activationTemperature: Double {
        allCurvePoints.compactMap { $0.first?.temperature }.min() ?? 50
    }

    var normalizedPoints: [ThermalCurvePoint] {
        Self.normalized(points)
    }

    var allCurvePoints: [[ThermalCurvePoint]] {
        [normalizedPoints] + (fanCurves ?? []).map { Self.normalized($0.points) }
    }

    func normalizedPoints(for fanIndex: Int?) -> [ThermalCurvePoint] {
        guard let fanIndex,
              let fanCurve = fanCurves?.first(where: { $0.fanIndex == fanIndex })
        else { return normalizedPoints }
        return Self.normalized(fanCurve.points)
    }

    func activationTemperature(for fanIndex: Int?) -> Double {
        normalizedPoints(for: fanIndex).first?.temperature ?? 50
    }

    func hasIndependentCurve(for fanIndex: Int) -> Bool {
        fanCurves?.contains(where: { $0.fanIndex == fanIndex }) == true
    }

    func displayProfile(for fanIndex: Int?) -> ThermalCurveProfile {
        guard let fanIndex else { return self }
        var result = self
        result.points = normalizedPoints(for: fanIndex)
        result.fanCurves = nil
        return result
    }

    func quietHeadroomPoints(calibratedFraction: Double) -> [ThermalCurvePoint] {
        let safeFraction = min(max(calibratedFraction, 0), 1)
        return normalizedPoints.enumerated().map { index, point in
            let utilization = index == 0 ? 0.75 : 1.0
            return ThermalCurvePoint(
                id: point.id,
                temperature: point.temperature,
                fanFraction: max(point.fanFraction, safeFraction * utilization)
            )
        }
    }

    private static func normalized(_ source: [ThermalCurvePoint]) -> [ThermalCurvePoint] {
        source
            .map {
                ThermalCurvePoint(
                    id: $0.id,
                    temperature: min(max($0.temperature, 35), 100),
                    fanFraction: min(max($0.fanFraction, 0), 1)
                )
            }
            .sorted { $0.temperature < $1.temperature }
    }

    /// Below the first point, `nil` means macOS keeps full control.
    func fanFraction(at temperature: Double, fanIndex: Int? = nil) -> Double? {
        let points = normalizedPoints(for: fanIndex)
        guard let first = points.first, temperature >= first.temperature else { return nil }
        guard let last = points.last else { return nil }
        if temperature >= last.temperature { return last.fanFraction }

        for (lower, upper) in zip(points, points.dropFirst()) where temperature <= upper.temperature {
            let span = upper.temperature - lower.temperature
            guard span > 0 else { return max(lower.fanFraction, upper.fanFraction) }
            let progress = (temperature - lower.temperature) / span
            return lower.fanFraction + ((upper.fanFraction - lower.fanFraction) * progress)
        }
        return last.fanFraction
    }

    static func targetRPM(
        for fanFraction: Double,
        maximumRPM: Double
    ) -> Double {
        let fraction = min(max(fanFraction, 0), 1)
        guard fraction > 0, maximumRPM.isFinite, maximumRPM > 0 else { return 0 }
        let requested = maximumRPM * fraction
        return min(requested, maximumTargetRPM(maximumRPM: maximumRPM))
    }

    static func maximumTargetRPM(maximumRPM: Double) -> Double {
        // Some Apple Silicon fan controllers treat the exact F%dMx boundary as
        // an invalid transition. One RPM is below every supported target-key
        // resolution while remaining indistinguishable from the reported max.
        max(0, maximumRPM - 1)
    }

    func validated() -> ThermalCurveProfile {
        var result = self
        var unique: [ThermalCurvePoint] = []
        for point in normalizedPoints {
            if let last = unique.last, abs(last.temperature - point.temperature) < 0.5 {
                unique[unique.count - 1].fanFraction = max(last.fanFraction, point.fanFraction)
            } else {
                unique.append(point)
            }
        }
        if unique.count < 2 {
            unique = Self.balanced.points
        }

        // Fan demand must never decrease while temperature rises.
        var previous = 0.0
        for index in unique.indices {
            unique[index].fanFraction = max(previous, unique[index].fanFraction)
            previous = unique[index].fanFraction
        }
        result.points = Array(unique.prefix(8))
        result.fanCurves = result.fanCurves?.map { curve in
            let validatedCurve = ThermalCurveProfile(
                id: "fan.\(curve.fanIndex)",
                name: curve.fanName,
                summary: "",
                points: curve.points,
                isBuiltIn: false
            ).validated()
            return FanSpecificCurve(
                fanIndex: curve.fanIndex,
                fanName: curve.fanName,
                points: validatedCurve.points
            )
        }
        return result
    }

    mutating func coarseAdjust(temperature: Double, fanFraction: Double) -> CurveAdjustment {
        let temperature = min(max(temperature.rounded(), 35), 100)
        let fanFraction = min(max((fanFraction * 100).rounded() / 100, 0), 1)
        let points = normalizedPoints
        let nearest = points.min { abs($0.temperature - temperature) < abs($1.temperature - temperature) }
        let adjustment: CurveAdjustment

        if points.count < 8, nearest.map({ abs($0.temperature - temperature) > 4 }) ?? true {
            self.points.append(.init(temperature: temperature, fanFraction: fanFraction))
            adjustment = .added(temperature: temperature, fanFraction: fanFraction)
        } else if let nearest,
                  let pointIndex = self.points.firstIndex(where: { $0.id == nearest.id })
        {
            self.points[pointIndex].temperature = temperature
            self.points[pointIndex].fanFraction = fanFraction
            adjustment = .moved(temperature: temperature, fanFraction: fanFraction)
        } else {
            adjustment = .unchanged
        }
        self = validated()
        return adjustment
    }

    @discardableResult
    mutating func movePoint(
        id: UUID,
        temperature: Double,
        fanFraction: Double
    ) -> ThermalCurvePoint? {
        let sortedPoints = normalizedPoints
        guard let sortedIndex = sortedPoints.firstIndex(where: { $0.id == id }),
              let pointIndex = points.firstIndex(where: { $0.id == id })
        else { return nil }

        let lowerTemperature = sortedIndex > 0
            ? sortedPoints[sortedIndex - 1].temperature + 1
            : 35
        let upperTemperature = sortedIndex < sortedPoints.count - 1
            ? sortedPoints[sortedIndex + 1].temperature - 1
            : 100
        let safeTemperature: Double
        if lowerTemperature <= upperTemperature {
            safeTemperature = min(max(temperature.rounded(), lowerTemperature), upperTemperature)
        } else {
            safeTemperature = sortedPoints[sortedIndex].temperature
        }

        let lowerFanFraction = sortedIndex > 0
            ? sortedPoints[sortedIndex - 1].fanFraction
            : 0
        let upperFanFraction = sortedIndex < sortedPoints.count - 1
            ? sortedPoints[sortedIndex + 1].fanFraction
            : 1
        let roundedFanFraction = (fanFraction * 100).rounded() / 100

        points[pointIndex].temperature = safeTemperature
        points[pointIndex].fanFraction = min(
            max(roundedFanFraction, lowerFanFraction),
            upperFanFraction
        )
        return points[pointIndex]
    }
}

enum CurveAdjustment: Equatable, Sendable {
    case added(temperature: Double, fanFraction: Double)
    case moved(temperature: Double, fanFraction: Double)
    case unchanged
}

extension ThermalCurveProfile {
    static let quiet = ThermalCurveProfile(
        id: "builtin.quiet",
        name: "Quiet",
        summary: "Use steady low-noise airflow early, then ramp firmly under load.",
        points: [
            .init(temperature: 48, fanFraction: 0.22),
            .init(temperature: 60, fanFraction: 0.38),
            .init(temperature: 70, fanFraction: 0.60),
            .init(temperature: 80, fanFraction: 0.84),
            .init(temperature: 88, fanFraction: 1.00),
        ],
        isBuiltIn: true
    )

    static let balanced = ThermalCurveProfile(
        id: "builtin.balanced",
        name: "Balanced",
        summary: "Start cooling sooner for everyday work and sustained loads.",
        points: [
            .init(temperature: 44, fanFraction: 0.28),
            .init(temperature: 56, fanFraction: 0.48),
            .init(temperature: 66, fanFraction: 0.70),
            .init(temperature: 76, fanFraction: 0.90),
            .init(temperature: 84, fanFraction: 1.00),
        ],
        isBuiltIn: true
    )

    static let performance = ThermalCurveProfile(
        id: "builtin.performance",
        name: "Performance",
        summary: "Prioritize sustained performance with early, decisive cooling.",
        points: [
            .init(temperature: 40, fanFraction: 0.38),
            .init(temperature: 50, fanFraction: 0.60),
            .init(temperature: 60, fanFraction: 0.80),
            .init(temperature: 70, fanFraction: 0.95),
            .init(temperature: 78, fanFraction: 1.00),
        ],
        isBuiltIn: true
    )

    static let presets = [quiet, balanced, performance]

    static var defaultCustom: ThermalCurveProfile {
        var profile = balanced
        profile.id = "custom"
        profile.name = "Custom"
        profile.summary = "Your editable temperature curve."
        profile.isBuiltIn = false
        profile.points = profile.points.map {
            ThermalCurvePoint(temperature: $0.temperature, fanFraction: $0.fanFraction)
        }
        return profile
    }
}
