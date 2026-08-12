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

struct ThermalCurveProfile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var summary: String
    var points: [ThermalCurvePoint]
    var isBuiltIn: Bool

    var localizedName: String {
        isBuiltIn ? L10n.string(name) : name
    }

    var localizedSummary: String {
        L10n.string(summary)
    }

    var activationTemperature: Double {
        normalizedPoints.first?.temperature ?? 50
    }

    var normalizedPoints: [ThermalCurvePoint] {
        points
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
    func fanFraction(at temperature: Double) -> Double? {
        let points = normalizedPoints
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
        minimumRPM: Double,
        maximumRPM: Double
    ) -> Double {
        let fraction = min(max(fanFraction, 0), 1)
        guard fraction > 0 else { return 0 }
        return minimumRPM + ((maximumRPM - minimumRPM) * fraction)
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
        summary: "Stay in System mode longer, then ramp gently.",
        points: [
            .init(temperature: 58, fanFraction: 0.12),
            .init(temperature: 68, fanFraction: 0.25),
            .init(temperature: 78, fanFraction: 0.48),
            .init(temperature: 88, fanFraction: 0.78),
            .init(temperature: 96, fanFraction: 1.00),
        ],
        isBuiltIn: true
    )

    static let balanced = ThermalCurveProfile(
        id: "builtin.balanced",
        name: "Balanced",
        summary: "A smooth default for everyday workloads.",
        points: [
            .init(temperature: 52, fanFraction: 0.15),
            .init(temperature: 64, fanFraction: 0.30),
            .init(temperature: 74, fanFraction: 0.55),
            .init(temperature: 84, fanFraction: 0.82),
            .init(temperature: 92, fanFraction: 1.00),
        ],
        isBuiltIn: true
    )

    static let cool = ThermalCurveProfile(
        id: "builtin.cool",
        name: "Cool",
        summary: "Earlier airflow for lower sustained temperatures.",
        points: [
            .init(temperature: 45, fanFraction: 0.18),
            .init(temperature: 58, fanFraction: 0.40),
            .init(temperature: 68, fanFraction: 0.65),
            .init(temperature: 78, fanFraction: 0.88),
            .init(temperature: 86, fanFraction: 1.00),
        ],
        isBuiltIn: true
    )

    static let sustained = ThermalCurveProfile(
        id: "builtin.sustained",
        name: "Sustained Work",
        summary: "Aggressive cooling for builds, rendering, and long loads.",
        points: [
            .init(temperature: 42, fanFraction: 0.25),
            .init(temperature: 54, fanFraction: 0.48),
            .init(temperature: 64, fanFraction: 0.72),
            .init(temperature: 74, fanFraction: 0.92),
            .init(temperature: 82, fanFraction: 1.00),
        ],
        isBuiltIn: true
    )

    static let presets = [quiet, balanced, cool, sustained]

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
