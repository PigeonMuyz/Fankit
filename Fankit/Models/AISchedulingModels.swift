import Foundation

enum AIPresetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case quiet
    case balanced
    case performance

    var id: Self { self }

    var title: String {
        switch self {
        case .quiet: L10n.string("Quiet First")
        case .balanced: L10n.string("Balanced")
        case .performance: L10n.string("Performance First")
        }
    }

    var sortOrder: Int {
        switch self {
        case .quiet: 0
        case .balanced: 1
        case .performance: 2
        }
    }
}

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
    let preset: AIPresetKind?
    let name: String
    let summary: String
    let points: [AIImportedCurvePoint]?
    let fanCurves: [AIImportedFanCurve]?

    enum CodingKeys: String, CodingKey {
        case preset, name, summary, points
        case fanCurves = "fan_curves"
    }

    init(
        preset: AIPresetKind?,
        name: String,
        summary: String,
        points: [AIImportedCurvePoint]? = nil,
        fanCurves: [AIImportedFanCurve]? = nil
    ) {
        self.preset = preset
        self.name = name
        self.summary = summary
        self.points = points
        self.fanCurves = fanCurves
    }
}

struct AIImportedFanCurve: Codable, Hashable, Sendable {
    let fanIndex: Int
    let fanName: String?
    let points: [AIImportedCurvePoint]

    enum CodingKeys: String, CodingKey {
        case fanIndex = "fan_index"
        case fanName = "fan_name"
        case points
    }
}

struct AIImportedPresetCollection: Codable, Hashable, Sendable {
    let format: String
    let version: Int
    let schedules: [AIImportedSchedule]
}

struct AIImportedLegacySchedule: Codable, Hashable, Sendable {
    let format: String
    let version: Int
    let name: String
    let summary: String
    let points: [AIImportedCurvePoint]

    var schedule: AIImportedSchedule {
        AIImportedSchedule(preset: nil, name: name, summary: summary, points: points)
    }
}

enum AIScheduleValidationError: LocalizedError, Sendable {
    case emptyInput
    case invalidJSON
    case unsupportedCommandField(String)
    case unsupportedFormat
    case unsupportedVersion
    case invalidPresetCollection
    case invalidFanCurveCollection
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
            "This Fankit build supports AI preset collection versions 3 and 2, plus legacy schedule version 1."
        case .invalidPresetCollection:
            "The AI response must contain one quiet, balanced, and performance preset."
        case .invalidFanCurveCollection:
            "Each version 3 preset must contain exactly one curve for every fan on this Mac."
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

    var aiPresetKind: AIPresetKind? {
        AIPresetKind.allCases.first {
            id.hasPrefix("ai.\($0.rawValue).") || id == "ai.preview.\($0.rawValue)"
        }
    }
}
