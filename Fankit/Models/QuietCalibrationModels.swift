import Foundation

enum QuietCalibrationScope: Hashable, Sendable {
    case allFans
    case fan(Int)
}

enum QuietCalibrationMethod: String, Codable, Hashable, Sendable {
    case combined
    case individual
}

struct QuietFanLimit: Codable, Hashable, Identifiable, Sendable {
    let fanIndex: Int
    let fanName: String
    let quietRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double

    var id: Int { fanIndex }
}

struct QuietCalibrationProfile: Codable, Hashable, Sendable {
    static let currentVersion = 2

    let version: Int
    let hardwareFingerprint: String
    let calibratedAt: Date
    let fanLimits: [QuietFanLimit]
    let method: QuietCalibrationMethod?

    init(
        version: Int = Self.currentVersion,
        hardwareFingerprint: String,
        calibratedAt: Date = .now,
        fanLimits: [QuietFanLimit],
        method: QuietCalibrationMethod = .individual
    ) {
        self.version = version
        self.hardwareFingerprint = hardwareFingerprint
        self.calibratedAt = calibratedAt
        self.fanLimits = fanLimits.sorted { $0.fanIndex < $1.fanIndex }
        self.method = method
    }

    var resolvedMethod: QuietCalibrationMethod { method ?? .individual }

    func isCompatible(with fans: [FanSnapshot]) -> Bool {
        version == Self.currentVersion
            && hardwareFingerprint == Self.hardwareFingerprint(for: fans)
            && !fans.isEmpty
            && fanLimits.count == fans.count
            && Set(fanLimits.map(\.fanIndex)) == Set(fans.map(\.index))
    }

    func limit(for fanIndex: Int) -> QuietFanLimit? {
        fanLimits.first { $0.fanIndex == fanIndex }
    }

    static func hardwareFingerprint(for fans: [FanSnapshot]) -> String {
        fans
            .sorted { $0.index < $1.index }
            .map {
                [
                    String($0.index),
                    $0.name,
                    String(Int($0.minimumRPM.rounded())),
                    String(Int($0.maximumRPM.rounded())),
                ].joined(separator: ":")
            }
            .joined(separator: "|")
    }
}
