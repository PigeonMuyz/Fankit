import Foundation

enum AIScheduleParser {
    private static let prohibitedFields: Set<String> = [
        "command", "commands", "script", "shell", "smc_key", "smc_keys",
        "rpm", "target_rpm", "target_rpms", "executable", "install"
    ]

    static func parse(_ text: String) throws -> ThermalCurveProfile {
        guard let profile = try parseProfiles(text).first else {
            throw AIScheduleValidationError.invalidJSON
        }
        return profile
    }

    static func parseProfiles(_ text: String, fans: [FanSnapshot] = []) throws -> [ThermalCurveProfile] {
        let jsonText = try normalizedJSONText(text)
        let data = Data(jsonText.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw AIScheduleValidationError.invalidJSON
        }

        if let unsafeField = findProhibitedField(in: dictionary) {
            throw AIScheduleValidationError.unsupportedCommandField(unsafeField)
        }

        let decoder = JSONDecoder()
        if dictionary["format"] as? String == "fankit-ai-presets" {
            guard let collection = try? decoder.decode(AIImportedPresetCollection.self, from: data) else {
                throw AIScheduleValidationError.invalidJSON
            }
            return try parse(collection, fans: fans)
        }

        guard let legacy = try? decoder.decode(AIImportedLegacySchedule.self, from: data) else {
            throw AIScheduleValidationError.invalidJSON
        }
        guard legacy.format == "fankit-ai-schedule" else {
            throw AIScheduleValidationError.unsupportedFormat
        }
        guard legacy.version == 1 else {
            throw AIScheduleValidationError.unsupportedVersion
        }
        try validateMetadata(legacy.schedule)
        try validatePoints(legacy.points)
        return [profile(from: legacy.schedule, id: "ai.preview")]
    }

    private static func parse(
        _ collection: AIImportedPresetCollection,
        fans: [FanSnapshot]
    ) throws -> [ThermalCurveProfile] {
        guard collection.format == "fankit-ai-presets" else {
            throw AIScheduleValidationError.unsupportedFormat
        }
        guard collection.version == 2 || collection.version == 3 else {
            throw AIScheduleValidationError.unsupportedVersion
        }
        guard collection.schedules.count == AIPresetKind.allCases.count else {
            throw AIScheduleValidationError.invalidPresetCollection
        }

        let kinds = collection.schedules.compactMap(\.preset)
        guard Set(kinds) == Set(AIPresetKind.allCases), kinds.count == collection.schedules.count else {
            throw AIScheduleValidationError.invalidPresetCollection
        }

        return try collection.schedules
            .sorted { ($0.preset?.sortOrder ?? .max) < ($1.preset?.sortOrder ?? .max) }
            .map { schedule in
                try validateMetadata(schedule)
                if collection.version == 3 {
                    try validateFanCurves(schedule, fans: fans)
                } else {
                    guard let points = schedule.points else {
                        throw AIScheduleValidationError.invalidPointCount
                    }
                    try validatePoints(points)
                }
                guard let kind = schedule.preset else {
                    throw AIScheduleValidationError.invalidPresetCollection
                }
                return profile(
                    from: schedule,
                    id: "ai.preview.\(kind.rawValue)",
                    fans: fans
                )
            }
    }

    private static func profile(
        from schedule: AIImportedSchedule,
        id: String,
        fans: [FanSnapshot] = []
    ) -> ThermalCurveProfile {
        let importedFanCurves = schedule.fanCurves?.sorted { $0.fanIndex < $1.fanIndex }
        let fallbackPoints = schedule.points ?? importedFanCurves?.first?.points ?? []
        return ThermalCurveProfile(
            id: id,
            name: schedule.name,
            summary: schedule.summary,
            points: thermalPoints(from: fallbackPoints),
            isBuiltIn: false,
            fanCurves: importedFanCurves?.map { curve in
                FanSpecificCurve(
                    fanIndex: curve.fanIndex,
                    fanName: fans.first(where: { $0.index == curve.fanIndex })?.name
                        ?? curve.fanName
                        ?? "Fan \(curve.fanIndex + 1)",
                    points: thermalPoints(from: curve.points)
                )
            }
        ).validated()
    }

    private static func thermalPoints(from points: [AIImportedCurvePoint]) -> [ThermalCurvePoint] {
        points.map {
                ThermalCurvePoint(
                    temperature: $0.temperatureCelsius,
                    fanFraction: $0.fanPercent / 100
                )
            }
    }

    private static func normalizedJSONText(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AIScheduleValidationError.emptyInput }
        guard trimmed.hasPrefix("```") else { return trimmed }

        guard let firstLineEnd = trimmed.firstIndex(of: "\n"),
              let closingFence = trimmed.range(of: "```", options: .backwards),
              closingFence.lowerBound > firstLineEnd
        else {
            throw AIScheduleValidationError.invalidJSON
        }
        return String(trimmed[trimmed.index(after: firstLineEnd)..<closingFence.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validateMetadata(_ schedule: AIImportedSchedule) throws {
        let name = schedule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = schedule.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...48).contains(name.count) else {
            throw AIScheduleValidationError.invalidName
        }
        guard (1...240).contains(summary.count) else {
            throw AIScheduleValidationError.invalidSummary
        }
    }

    private static func validateFanCurves(
        _ schedule: AIImportedSchedule,
        fans: [FanSnapshot]
    ) throws {
        guard let fanCurves = schedule.fanCurves, !fanCurves.isEmpty else {
            throw AIScheduleValidationError.invalidFanCurveCollection
        }
        let indexes = fanCurves.map(\.fanIndex)
        guard Set(indexes).count == indexes.count else {
            throw AIScheduleValidationError.invalidFanCurveCollection
        }
        if !fans.isEmpty {
            let expected = Set(fans.map(\.index))
            guard Set(indexes) == expected else {
                throw AIScheduleValidationError.invalidFanCurveCollection
            }
        }
        for curve in fanCurves {
            try validatePoints(curve.points)
        }
    }

    private static func validatePoints(_ points: [AIImportedCurvePoint]) throws {
        guard (2...8).contains(points.count) else {
            throw AIScheduleValidationError.invalidPointCount
        }

        var previousTemperature: Double?
        var previousFanPercent: Double?
        for point in points {
            guard point.temperatureCelsius.isFinite, point.fanPercent.isFinite else {
                throw AIScheduleValidationError.nonFinitePoint
            }
            guard (35...100).contains(point.temperatureCelsius) else {
                throw AIScheduleValidationError.temperatureOutOfRange(point.temperatureCelsius)
            }
            guard (0...100).contains(point.fanPercent) else {
                throw AIScheduleValidationError.fanPercentOutOfRange(point.fanPercent)
            }
            if let previousTemperature, point.temperatureCelsius <= previousTemperature {
                throw AIScheduleValidationError.temperaturesNotIncreasing
            }
            if let previousFanPercent, point.fanPercent < previousFanPercent {
                throw AIScheduleValidationError.fanDemandDecreases
            }
            previousTemperature = point.temperatureCelsius
            previousFanPercent = point.fanPercent
        }
    }

    private static func findProhibitedField(in value: Any) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                if prohibitedFields.contains(key.lowercased()) {
                    return key
                }
                if let nested = findProhibitedField(in: child) {
                    return nested
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let nested = findProhibitedField(in: child) {
                    return nested
                }
            }
        }
        return nil
    }
}
