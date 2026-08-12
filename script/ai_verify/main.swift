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

let presetJSON = """
{
  "format": "fankit-ai-presets",
  "version": 2,
  "schedules": [
    {
      "preset": "quiet",
      "name": "Quiet first",
      "summary": "Keep fan demand gentle for everyday work.",
      "points": [
        { "temperature_c": 55, "fan_percent": 12 },
        { "temperature_c": 82, "fan_percent": 55 }
      ]
    },
    {
      "preset": "balanced",
      "name": "Balanced",
      "summary": "Balance noise and sustained cooling.",
      "points": [
        { "temperature_c": 50, "fan_percent": 18 },
        { "temperature_c": 78, "fan_percent": 65 }
      ]
    },
    {
      "preset": "performance",
      "name": "Performance first",
      "summary": "Increase airflow earlier for sustained performance.",
      "points": [
        { "temperature_c": 44, "fan_percent": 30 },
        { "temperature_c": 72, "fan_percent": 80 }
      ]
    }
  ]
}
"""

let presetProfiles = try AIScheduleParser.parseProfiles(presetJSON)
expect(presetProfiles.count == 3, "one AI response produces three presets")
expect(presetProfiles.map(\.aiPresetKind) == [.quiet, .balanced, .performance], "presets retain their switchable kind")

do {
    let incomplete = presetJSON.replacingOccurrences(
        of: "\"preset\": \"performance\"",
        with: "\"preset\": \"balanced\""
    )
    _ = try AIScheduleParser.parseProfiles(incomplete)
    expect(false, "duplicate preset kinds must be rejected")
} catch AIScheduleValidationError.invalidPresetCollection {
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
let multiFans = fans + [
    FanSnapshot(index: 1, name: "Right", currentRPM: 2_100, minimumRPM: 1_100, maximumRPM: 6_200),
]
let version3JSON = """
{
  "format": "fankit-ai-presets",
  "version": 3,
  "schedules": [
    { "preset": "quiet", "name": "Quiet", "summary": "Independent quiet curves.", "fan_curves": [
      { "fan_index": 0, "fan_name": "Left", "points": [{"temperature_c": 55,"fan_percent": 10},{"temperature_c": 80,"fan_percent": 45}] },
      { "fan_index": 1, "fan_name": "Right", "points": [{"temperature_c": 58,"fan_percent": 8},{"temperature_c": 82,"fan_percent": 40}] }
    ]},
    { "preset": "balanced", "name": "Balanced", "summary": "Independent balanced curves.", "fan_curves": [
      { "fan_index": 0, "fan_name": "Left", "points": [{"temperature_c": 50,"fan_percent": 18},{"temperature_c": 78,"fan_percent": 65}] },
      { "fan_index": 1, "fan_name": "Right", "points": [{"temperature_c": 52,"fan_percent": 22},{"temperature_c": 76,"fan_percent": 72}] }
    ]},
    { "preset": "performance", "name": "Performance", "summary": "Independent performance curves.", "fan_curves": [
      { "fan_index": 0, "fan_name": "Left", "points": [{"temperature_c": 44,"fan_percent": 30},{"temperature_c": 72,"fan_percent": 80}] },
      { "fan_index": 1, "fan_name": "Right", "points": [{"temperature_c": 42,"fan_percent": 35},{"temperature_c": 70,"fan_percent": 85}] }
    ]}
  ]
}
"""
let independentProfiles = try AIScheduleParser.parseProfiles(version3JSON, fans: multiFans)
expect(independentProfiles.count == 3, "version 3 produces three presets")
expect(independentProfiles[1].fanCurves?.count == 2, "version 3 preserves one curve per physical fan")
expect(
    independentProfiles[1].fanFraction(at: 52, fanIndex: 0) != independentProfiles[1].fanFraction(at: 52, fanIndex: 1),
    "asymmetric fan curves remain independent"
)
do {
    let missingFan = version3JSON.replacingOccurrences(of: "{ \"fan_index\": 1, \"fan_name\": \"Right\", \"points\": [{\"temperature_c\": 58,\"fan_percent\": 8},{\"temperature_c\": 82,\"fan_percent\": 40}] }", with: "")
    _ = try AIScheduleParser.parseProfiles(missingFan, fans: multiFans)
    expect(false, "version 3 must include every physical fan")
} catch {
    // Expected: malformed or incomplete fan collection.
}
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
expect(prompt.contains("fankit-ai-presets"), "prompt includes the three-preset machine-readable format")
expect(prompt.contains("Processor"), "prompt includes observed sensor data")
expect(prompt.contains("\"fan_name\": \"Left\""), "prompt falls back to the actual observed fan list")

let quietProfile = QuietCalibrationProfile(
    hardwareFingerprint: QuietCalibrationProfile.hardwareFingerprint(for: fans),
    fanLimits: [
        QuietFanLimit(
            fanIndex: 0,
            fanName: "Left",
            quietRPM: 2_600,
            minimumRPM: 1_200,
            maximumRPM: 5_500
        )
    ]
)
let calibratedPrompt = AIPromptBuilder.prompt(
    for: session,
    quietProfile: quietProfile,
    currentFans: fans
)
expect(calibratedPrompt.contains("2600 RPM"), "prompt includes the device quiet calibration")
expect(calibratedPrompt.contains("version 3"), "prompt requests the independent fan format")
expect(calibratedPrompt.contains("fan_index"), "prompt identifies physical fans")

let individualQuietProfile = QuietCalibrationProfile(
    hardwareFingerprint: QuietCalibrationProfile.hardwareFingerprint(for: multiFans),
    fanLimits: multiFans.map { fan in
        QuietFanLimit(
            fanIndex: fan.index,
            fanName: fan.name,
            quietRPM: 2_500,
            minimumRPM: fan.minimumRPM,
            maximumRPM: fan.maximumRPM
        )
    },
    method: .individual
)
let individualPrompt = AIPromptBuilder.prompt(
    for: session,
    quietProfile: individualQuietProfile,
    currentFans: multiFans
)
expect(individualPrompt.contains("does not prove"), "individual calibration is not described as a combined acoustic result")

let legacyCalibrationJSON = """
{
  "version": 1,
  "hardwareFingerprint": "\(QuietCalibrationProfile.hardwareFingerprint(for: fans))",
  "calibratedAt": 0,
  "fanLimits": [{"fanIndex":0,"fanName":"Left","quietRPM":2500,"minimumRPM":1200,"maximumRPM":5500}]
}
"""
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .secondsSince1970
let legacyCalibration = try decoder.decode(
    QuietCalibrationProfile.self,
    from: Data(legacyCalibrationJSON.utf8)
)
expect(!legacyCalibration.isCompatible(with: fans), "ambiguous version 1 quiet calibration requires recalibration")

print("AI scheduling verification passed")
