import Foundation

enum AIPromptBuilder {
    static func summary(for session: AICaptureSession) -> AICaptureSummary {
        let sortedSamples = session.samples.sorted { $0.timestamp < $1.timestamp }
        let validSamples = sortedSamples.filter { !$0.temperatures.isEmpty || !$0.fans.isEmpty }
        let gaps = zip(sortedSamples, sortedSamples.dropFirst()).map {
            $1.timestamp.timeIntervalSince($0.timestamp)
        }
        let longestGap = gaps.max()
        let temperatureStatistics = ThermalGroup.allCases.compactMap { group -> AICaptureValueStatistics? in
            let values = validSamples.compactMap { $0.temperatures[group.rawValue] }
            guard !values.isEmpty else { return nil }
            return AICaptureValueStatistics(
                id: group.rawValue,
                title: group.title,
                minimum: values.min() ?? 0,
                average: values.reduce(0, +) / Double(values.count),
                p95: percentile(values, percentile: 0.95),
                maximum: values.max() ?? 0,
                suffix: "°C"
            )
        }

        let fanIndexes = Set(validSamples.flatMap { $0.fans.map(\.index) }).sorted()
        let fanStatistics = fanIndexes.compactMap { index -> AICaptureFanStatistics? in
            let samples = validSamples.flatMap { sample in
                sample.fans.filter { $0.index == index }
            }
            guard let first = samples.first, !samples.isEmpty else { return nil }
            let values = samples.map(\.currentRPM)
            return AICaptureFanStatistics(
                id: index,
                name: first.name,
                minimum: values.min() ?? 0,
                average: values.reduce(0, +) / Double(values.count),
                maximum: values.max() ?? 0,
                hardwareRange: "\(Int(first.minimumRPM.rounded()))–\(Int(first.maximumRPM.rounded())) RPM"
            )
        }

        return AICaptureSummary(
            duration: session.duration,
            sampleCount: sortedSamples.count,
            validSampleCount: validSamples.count,
            hasDataGaps: longestGap.map { $0 > 30 } ?? false,
            longestGap: longestGap,
            temperatures: temperatureStatistics,
            fans: fanStatistics
        )
    }

    static func prompt(for session: AICaptureSession) -> String {
        let summary = summary(for: session)
        let buckets = compressedBuckets(for: session)
        let temperatureLines = summary.temperatures.map {
            "- \($0.title): min \(number($0.minimum))°C, average \(number($0.average))°C, P95 \(number($0.p95))°C, max \(number($0.maximum))°C"
        }.joined(separator: "\n")
        let fanLines = summary.fans.map {
            "- \($0.name): min \(number($0.minimum)) RPM, average \(number($0.average)) RPM, max \(number($0.maximum)) RPM, hardware range \($0.hardwareRange)"
        }.joined(separator: "\n")
        let bucketLines = buckets.map { bucket in
            let temperatures = ThermalGroup.allCases.compactMap { group in
                bucket.temperatures[group.rawValue].map { "\(group.rawValue)=\(number($0))°C" }
            }.joined(separator: ", ")
            let fans = bucket.averageFanRPMs
                .sorted { $0.key < $1.key }
                .map { "fan\($0.key)=\(number($0.value, digits: 0))RPM" }
                .joined(separator: ", ")
            return "- +\(bucket.startMinute) min: \(temperatures.isEmpty ? "no thermal data" : temperatures); \(fans.isEmpty ? "no fan data" : fans)"
        }.joined(separator: "\n")

        return """
        You are helping design a safe temperature-based fan curve for Fankit on macOS.

        Return ONLY one JSON object matching the exact fankit-ai-schedule version 1 format below. Do not return Markdown, explanations, code, shell commands, SMC keys, raw RPM targets, or any executable instructions.

        The curve must be monotonic: fan_percent must never decrease as temperature_c rises. Use 2–8 points, temperatures from 35 to 100°C, and fan_percent from 0 to 100. Recommend a practical curve based on sustained cooling, noise, and the observed System behavior. Fankit will enforce its own hardware limits, ramp limits, hysteresis, and emergency protection after import.

        Required output shape:
        {
          "format": "fankit-ai-schedule",
          "version": 1,
          "name": "Short schedule name",
          "summary": "One-sentence explanation",
          "points": [
            { "temperature_c": 52, "fan_percent": 15 },
            { "temperature_c": 74, "fan_percent": 55 },
            { "temperature_c": 92, "fan_percent": 100 }
          ]
        }

        Observation duration: \(number(summary.duration, digits: 0)) seconds
        Valid samples: \(summary.validSampleCount) of \(summary.sampleCount)
        Sampling interval target: 10 seconds
        Data gap detected: \(summary.hasDataGaps ? "yes" : "no")
        Longest observed gap: \(summary.longestGap.map { "\(number($0, digits: 0)) seconds" } ?? "none")

        Temperature statistics:
        \(temperatureLines.isEmpty ? "- No valid temperature data" : temperatureLines)

        Fan statistics:
        \(fanLines.isEmpty ? "- No valid fan data" : fanLines)

        Compressed five-minute time series:
        \(bucketLines.isEmpty ? "- No valid time-series data" : bucketLines)
        """
    }

    private struct CompressedBucket {
        let startMinute: Int
        let temperatures: [String: Double]
        let averageFanRPMs: [Int: Double]
    }

    private static func compressedBuckets(for session: AICaptureSession) -> [CompressedBucket] {
        struct MutableBucket {
            var temperatures: [String: [Double]] = [:]
            var fanRPMs: [Int: [Double]] = [:]
        }

        var buckets: [Int: MutableBucket] = [:]
        for sample in session.samples {
            let offset = max(0, sample.timestamp.timeIntervalSince(session.startedAt))
            let minute = Int(offset / 300) * 5
            var bucket = buckets[minute] ?? MutableBucket()
            for (group, temperature) in sample.temperatures {
                bucket.temperatures[group, default: []].append(temperature)
            }
            for fan in sample.fans {
                bucket.fanRPMs[fan.index, default: []].append(fan.currentRPM)
            }
            buckets[minute] = bucket
        }

        return buckets.keys.sorted().map { minute in
            let bucket = buckets[minute] ?? MutableBucket()
            return CompressedBucket(
                startMinute: minute,
                temperatures: bucket.temperatures.mapValues { $0.max() ?? 0 },
                averageFanRPMs: bucket.fanRPMs.mapValues {
                    $0.reduce(0, +) / Double(max($0.count, 1))
                }
            )
        }
    }

    private static func percentile(_ values: [Double], percentile: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * percentile).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func number(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.*f", digits, value)
    }
}
