import Foundation

enum AIScheduleParser {
    private static let prohibitedFields: Set<String> = [
        "command", "commands", "script", "shell", "smc_key", "smc_keys",
        "rpm", "target_rpm", "target_rpms", "executable", "install"
    ]

    static func parse(_ text: String) throws -> ThermalCurveProfile {
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
        guard let schedule = try? decoder.decode(AIImportedSchedule.self, from: data) else {
            throw AIScheduleValidationError.invalidJSON
        }
        try validate(schedule)

        return ThermalCurveProfile(
            id: "ai.preview",
            name: schedule.name,
            summary: schedule.summary,
            points: schedule.points.map {
                ThermalCurvePoint(
                    temperature: $0.temperatureCelsius,
                    fanFraction: $0.fanPercent / 100
                )
            },
            isBuiltIn: false
        ).validated()
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

    private static func validate(_ schedule: AIImportedSchedule) throws {
        guard schedule.format == "fankit-ai-schedule" else {
            throw AIScheduleValidationError.unsupportedFormat
        }
        guard schedule.version == 1 else {
            throw AIScheduleValidationError.unsupportedVersion
        }
        let name = schedule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = schedule.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...48).contains(name.count) else {
            throw AIScheduleValidationError.invalidName
        }
        guard (1...240).contains(summary.count) else {
            throw AIScheduleValidationError.invalidSummary
        }
        guard (2...8).contains(schedule.points.count) else {
            throw AIScheduleValidationError.invalidPointCount
        }

        var previousTemperature: Double?
        var previousFanPercent: Double?
        for point in schedule.points {
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
