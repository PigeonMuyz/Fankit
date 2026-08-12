import Foundation

enum AICaptureSessionState: String, Codable, Sendable {
    case recording
    case completed
    case stopped
}

struct AICaptureFanSample: Codable, Hashable, Identifiable, Sendable {
    let index: Int
    let name: String
    let currentRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double

    var id: Int { index }
}

struct AICaptureSample: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    /// One value per thermal group: the hottest valid sensor in that group.
    let temperatures: [String: Double]
    let fans: [AICaptureFanSample]

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        sensors: [ThermalSensor],
        fans: [FanSnapshot]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.temperatures = Dictionary(
            grouping: sensors,
            by: \.group.rawValue
        ).compactMapValues { values in
            values.map(\.celsius).max()
        }
        self.fans = fans.map {
            AICaptureFanSample(
                index: $0.index,
                name: $0.name,
                currentRPM: $0.currentRPM,
                minimumRPM: $0.minimumRPM,
                maximumRPM: $0.maximumRPM
            )
        }
    }

    var hottestTemperature: Double? { temperatures.values.max() }
}

struct AICaptureSession: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var state: AICaptureSessionState
    var samples: [AICaptureSample]

    var isRecording: Bool { state == .recording }
    var sampleCount: Int { samples.count }
    var duration: TimeInterval {
        (endedAt ?? .now).timeIntervalSince(startedAt)
    }
}

struct AICaptureValueStatistics: Identifiable, Sendable {
    let id: String
    let title: String
    let minimum: Double
    let average: Double
    let p95: Double
    let maximum: Double
    let suffix: String
}

struct AICaptureFanStatistics: Identifiable, Sendable {
    let id: Int
    let name: String
    let minimum: Double
    let average: Double
    let maximum: Double
    let hardwareRange: String
}

struct AICaptureSummary: Sendable {
    let duration: TimeInterval
    let sampleCount: Int
    let validSampleCount: Int
    let hasDataGaps: Bool
    let longestGap: TimeInterval?
    let temperatures: [AICaptureValueStatistics]
    let fans: [AICaptureFanStatistics]

    var isUsefulForPrompt: Bool {
        duration >= 60 && validSampleCount >= 6
    }
}

struct AIImportedCurvePoint: Codable, Hashable, Sendable {
    let temperatureCelsius: Double
    let fanPercent: Double

    enum CodingKeys: String, CodingKey {
        case temperatureCelsius = "temperature_c"
        case fanPercent = "fan_percent"
    }
}

struct AIImportedSchedule: Codable, Hashable, Sendable {
    let format: String
    let version: Int
    let name: String
    let summary: String
    let points: [AIImportedCurvePoint]
}

enum AIScheduleValidationError: LocalizedError, Sendable {
    case emptyInput
    case invalidJSON
    case unsupportedCommandField(String)
    case unsupportedFormat
    case unsupportedVersion
    case invalidName
    case invalidSummary
    case invalidPointCount
    case nonFinitePoint
    case temperatureOutOfRange(Double)
    case fanPercentOutOfRange(Double)
    case temperaturesNotIncreasing
    case fanDemandDecreases

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            "Paste an AI JSON response first."
        case .invalidJSON:
            "The response is not valid JSON or a supported JSON code block."
        case .unsupportedCommandField(let field):
            "The response contains an unsafe field: \(field)."
        case .unsupportedFormat:
            "The JSON format must be fankit-ai-schedule."
        case .unsupportedVersion:
            "This Fankit build only supports AI schedule version 1."
        case .invalidName:
            "The schedule name must contain 1–48 characters."
        case .invalidSummary:
            "The schedule summary must contain 1–240 characters."
        case .invalidPointCount:
            "The schedule must contain 2–8 curve points."
        case .nonFinitePoint:
            "Every curve point must contain finite numeric values."
        case .temperatureOutOfRange(let value):
            "Temperature \(value)°C is outside the safe 35–100°C range."
        case .fanPercentOutOfRange(let value):
            "Fan demand \(value)% is outside the safe 0–100% range."
        case .temperaturesNotIncreasing:
            "Curve temperatures must be strictly increasing."
        case .fanDemandDecreases:
            "Fan demand cannot decrease as temperature rises."
        }
    }
}

extension ThermalCurveProfile {
    var isAIGenerated: Bool { id.hasPrefix("ai.") }
}
