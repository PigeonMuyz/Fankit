import Foundation

enum L10n {
    static func string(_ key: String) -> String { key }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("AI scheduling verification failed: \(message)\n", stderr)
        exit(1)
    }
}

let validJSON = """
{
  "format": "fankit-ai-schedule",
  "version": 1,
  "name": "Balanced sustained work",
  "summary": "Earlier cooling during sustained CPU and GPU load.",
  "points": [
    { "temperature_c": 52, "fan_percent": 15 },
    { "temperature_c": 74, "fan_percent": 55 },
    { "temperature_c": 92, "fan_percent": 100 }
  ]
}
"""

let profile = try AIScheduleParser.parse(validJSON)
expect(profile.id == "ai.preview", "preview profiles use a transient ID")
expect(profile.points.count == 3, "valid JSON produces all curve points")
expect(profile.points.last?.fanFraction == 1, "percentages convert to fractions")

let fencedProfile = try AIScheduleParser.parse("```json\n\(validJSON)\n```")
expect(
    zip(fencedProfile.points, profile.points).allSatisfy {
        $0.temperature == $1.temperature && $0.fanFraction == $1.fanFraction
    },
    "JSON code fences are supported"
)

do {
    _ = try AIScheduleParser.parse(validJSON.replacingOccurrences(of: "\"fan_percent\": 55", with: "\"fan_percent\": 10"))
    expect(false, "decreasing fan demand must be rejected")
} catch AIScheduleValidationError.fanDemandDecreases {
    // Expected.
}

do {
    _ = try AIScheduleParser.parse(validJSON.replacingOccurrences(of: "\"points\": [", with: "\"command\": \"rm -rf /\", \"points\": ["))
    expect(false, "unsafe command fields must be rejected")
} catch AIScheduleValidationError.unsupportedCommandField {
    // Expected.
}

let sensors = [
    ThermalSensor(key: "cpu", name: "CPU", group: .cpu, celsius: 72),
    ThermalSensor(key: "gpu", name: "GPU", group: .gpu, celsius: 68),
]
let fans = [
    FanSnapshot(index: 0, name: "Left", currentRPM: 2_400, minimumRPM: 1_200, maximumRPM: 5_500),
]
let started = Date(timeIntervalSince1970: 1_000)
let samples = (0..<12).map { index in
    AICaptureSample(
        timestamp: started.addingTimeInterval(Double(index * 10)),
        sensors: sensors,
        fans: fans
    )
}
let session = AICaptureSession(
    id: UUID(),
    startedAt: started,
    endedAt: started.addingTimeInterval(110),
    state: .completed,
    samples: samples
)
let summary = AIPromptBuilder.summary(for: session)
expect(summary.validSampleCount == 12, "capture summary counts valid samples")
expect(summary.temperatures.first?.maximum == 72, "summary uses hottest sensor per group")
let prompt = AIPromptBuilder.prompt(for: session)
expect(prompt.contains("fankit-ai-schedule"), "prompt includes the machine-readable format")
expect(prompt.contains("Processor"), "prompt includes observed sensor data")

print("AI scheduling verification passed")
