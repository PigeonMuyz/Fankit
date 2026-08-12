import Foundation
import OSLog

enum HelperControlError: LocalizedError {
    case noFans
    case invalidFan(Int)
    case invalidRange(Int)
    case unsupportedModeKey(Int)
    case manualModeNotConfirmed(Int)
    case restoreNotConfirmed

    var errorDescription: String? {
        switch self {
        case .noFans: "No controllable fans were detected."
        case .invalidFan(let index): "Fan \(index) does not exist."
        case .invalidRange(let index): "Fan \(index) did not report a valid safe RPM range."
        case .unsupportedModeKey(let index): "The control-mode key for fan \(index) was not found."
        case .manualModeNotConfirmed(let index): "Manual mode for fan \(index) could not be confirmed."
        case .restoreNotConfirmed: "Could not confirm that macOS resumed fan control."
        }
    }
}

final class FanController {
    private let log = Logger(subsystem: FanControlHelperConstants.machServiceName, category: "FanController")
    private let smc: SMCConnection
    private let recoveryMarker = URL(fileURLWithPath: "/Library/Application Support/Fankit/override-active")

    init() throws {
        smc = try SMCConnection()
        if FileManager.default.fileExists(atPath: recoveryMarker.path) {
            log.notice("Found an unfinished override marker; restoring system control")
            try restoreSystemControl()
        }
    }

    func setMaximum() throws {
        let count = try fanCount()
        let targets = try (0..<count).map { fan in
            maximumTarget(for: try safeBounds(for: fan))
        }
        try markOverridePending()
        do {
            try acquireManualControl(fans: Array(0..<count), targets: targets)
        } catch {
            try? restoreSystemControl()
            throw error
        }
    }

    func setTargetRPM(_ requestedRPM: Double, fan: Int) throws {
        let count = try fanCount()
        guard (0..<count).contains(fan) else { throw HelperControlError.invalidFan(fan) }
        let bounds = try safeBounds(for: fan)
        let target = requestedRPM <= 0
            ? 0
            : min(requestedRPM, maximumTarget(for: bounds))

        try markOverridePending()
        do {
            try acquireManualControl(fans: [fan], targets: [target])
        } catch {
            try? restoreSystemControl()
            throw error
        }
    }

    func restoreSystemControl() throws {
        let count = (try? fanCount()) ?? 0
        for fan in 0..<count {
            if let actual = try? smc.read("F\(fan)Ac").number() {
                try? writeRPM(actual, fan: fan)
            }
            if let key = modeKey(for: fan) {
                try? smc.write(key, bytes: [0])
            }
            if let target = try? smc.read("F\(fan)Tg") {
                try? smc.write("F\(fan)Tg", bytes: target.encoded(0))
            }
        }
        if hasForceTestKey {
            try? smc.write("Ftst", bytes: [0])
        }

        Thread.sleep(forTimeInterval: 0.2)
        let restored = (0..<count).allSatisfy { fan in
            guard let key = modeKey(for: fan), let mode = try? smc.read(key).number() else { return false }
            return mode == 0 || mode == 3
        }
        guard restored || count == 0 else { throw HelperControlError.restoreNotConfirmed }
        try? FileManager.default.removeItem(at: recoveryMarker)
        log.notice("System fan control restored")
    }

    private func acquireManualControl(fans: [Int], targets: [Double]) throws {
        if hasForceTestKey {
            try smc.write("Ftst", bytes: [1])
            Thread.sleep(forTimeInterval: 0.1)
        }

        for (fan, target) in zip(fans, targets) {
            guard let key = modeKey(for: fan) else { throw HelperControlError.unsupportedModeKey(fan) }
            var confirmed = false
            for attempt in 0..<100 {
                do {
                    try smc.write(key, bytes: [1])
                    if let value = try? smc.read(key).number(), value == 1 {
                        confirmed = true
                        break
                    }
                } catch {
                    if !hasForceTestKey { throw error }
                }
                if attempt < 99 { Thread.sleep(forTimeInterval: 0.1) }
            }
            guard confirmed else { throw HelperControlError.manualModeNotConfirmed(fan) }
            try writeRPM(target, fan: fan)
        }
    }

    private var hasForceTestKey: Bool { (try? smc.read("Ftst")) != nil }

    private func modeKey(for fan: Int) -> String? {
        let lower = "F\(fan)md"
        if (try? smc.read(lower)) != nil { return lower }
        let upper = "F\(fan)Md"
        if (try? smc.read(upper)) != nil { return upper }
        return nil
    }

    private func fanCount() throws -> Int {
        let count = Int(try smc.read("FNum").number().rounded())
        guard count > 0 else { throw HelperControlError.noFans }
        return count
    }

    private func safeBounds(for fan: Int) throws -> (minimum: Double, maximum: Double) {
        let minimum = try smc.read("F\(fan)Mn").number()
        let maximum = try smc.read("F\(fan)Mx").number()
        guard minimum.isFinite, maximum.isFinite, minimum >= 0, maximum > 0 else {
            throw HelperControlError.invalidRange(fan)
        }
        return (minimum, maximum)
    }

    private func maximumTarget(for bounds: (minimum: Double, maximum: Double)) -> Double {
        // Avoid the exact firmware-reported upper boundary. On some Apple
        // Silicon controllers that value can be interpreted as an invalid
        // transition and stop one fan when paired fans have different maxima.
        max(0, bounds.maximum - 1)
    }

    private func writeRPM(_ rpm: Double, fan: Int) throws {
        let key = "F\(fan)Tg"
        let target = try smc.read(key)
        try smc.write(key, bytes: target.encoded(rpm))
    }

    private func markOverridePending() throws {
        let directory = recoveryMarker.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("pending\n".utf8).write(to: recoveryMarker, options: .atomic)
    }
}
