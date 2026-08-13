import Darwin
import Foundation

final class HardwareMonitor {
    private let smc: SMCConnection
    private let sensorDefinitions: [SensorDefinition]

    init() throws {
        smc = try SMCConnection()
        sensorDefinitions = Self.sensorDefinitions(for: Self.detectedProfile)
    }

    func readFans() -> [FanSnapshot] {
        guard let count = try? smc.read("FNum").number() else { return [] }

        return (0..<Int(count)).compactMap { index in
            guard
                let current = try? smc.read("F\(index)Ac").number(),
                let minimum = try? smc.read("F\(index)Mn").number(),
                let maximum = try? smc.read("F\(index)Mx").number()
            else { return nil }

            return FanSnapshot(
                index: index,
                name: fanName(index: index, count: Int(count)),
                currentRPM: current,
                minimumRPM: minimum,
                maximumRPM: maximum
            )
        }
    }

    func readTemperatures() -> [ThermalSensor] {
        sensorDefinitions.compactMap { definition in
            guard
                let value = try? smc.read(definition.key).number(),
                value >= 1,
                value <= 125
            else { return nil }

            return ThermalSensor(
                key: definition.key,
                name: L10n.string(definition.name),
                group: definition.group,
                celsius: value
            )
        }
    }

    private func fanName(index: Int, count: Int) -> String {
        if count == 2 {
            return L10n.string(index == 0 ? "Left Side" : "Right Side")
        }
        return count == 1
            ? L10n.string("System Fan")
            : L10n.format("Fan %d", index + 1)
    }

    // Apple changes sensor keys between SoC generations. Keep generation-specific
    // keys explicit so unsupported values are omitted instead of being shown under
    // a false name.
    private enum AppleSiliconProfile {
        case m1
        case m2
        case m3
        case m4Base
        case m4ProMaxUltra
        case m5Base
        case m5ProMaxUltra
    }

    private static var detectedProfile: AppleSiliconProfile? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 1
        else { return nil }

        var characters = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &characters, &size, nil, 0) == 0
        else { return nil }

        let brand = String(cString: characters).lowercased()
        let isProMaxOrUltra = brand.contains("pro") || brand.contains("max") || brand.contains("ultra")
        if brand.contains("m5") {
            return isProMaxOrUltra ? .m5ProMaxUltra : .m5Base
        }
        if brand.contains("m4") {
            return isProMaxOrUltra ? .m4ProMaxUltra : .m4Base
        }
        if brand.contains("m3") { return .m3 }
        if brand.contains("m2") { return .m2 }
        if brand.contains("m1") { return .m1 }
        return nil
    }

    private static func sensorDefinitions(for profile: AppleSiliconProfile?) -> [SensorDefinition] {
        switch profile {
        case .m1:
            return m1Sensors + commonAppleSensors
        case .m2:
            return m2Sensors + commonAppleSensors
        case .m3:
            return m3Sensors + commonAppleSensors
        case .m4Base:
            return m4BaseSensors + m4MemorySensors + commonAppleSensors
        case .m4ProMaxUltra:
            return m4ProMaxUltraSensors + m4MemorySensors + commonAppleSensors
        case .m5Base:
            return m5BaseSensors + commonAppleSensors
        case .m5ProMaxUltra:
            return m5ProMaxUltraSensors + commonAppleSensors
        case nil:
            // Do not assign Apple Silicon core names when the chip cannot be
            // identified. Shared chassis sensors are still safe to expose.
            return commonAppleSensors
        }
    }

    private static let m1Sensors: [SensorDefinition] = [
        .init(key: "Tp09", name: "Efficiency Core 1", group: .cpu),
        .init(key: "Tp0T", name: "Efficiency Core 2", group: .cpu),
        .init(key: "Tp01", name: "Performance Core 1", group: .cpu),
        .init(key: "Tp05", name: "Performance Core 2", group: .cpu),
        .init(key: "Tp0D", name: "Performance Core 3", group: .cpu),
        .init(key: "Tp0H", name: "Performance Core 4", group: .cpu),
        .init(key: "Tp0L", name: "Performance Core 5", group: .cpu),
        .init(key: "Tp0P", name: "Performance Core 6", group: .cpu),
        .init(key: "Tp0X", name: "Performance Core 7", group: .cpu),
        .init(key: "Tp0b", name: "Performance Core 8", group: .cpu),
        .init(key: "Tg05", name: "GPU Cluster 1", group: .gpu),
        .init(key: "Tg0D", name: "GPU Cluster 2", group: .gpu),
        .init(key: "Tg0L", name: "GPU Cluster 3", group: .gpu),
        .init(key: "Tg0T", name: "GPU Cluster 4", group: .gpu),
        .init(key: "Tm02", name: "Memory Bank 1", group: .memory),
        .init(key: "Tm06", name: "Memory Bank 2", group: .memory),
        .init(key: "Tm08", name: "Memory Bank 3", group: .memory),
        .init(key: "Tm09", name: "Memory Bank 4", group: .memory),
    ]

    private static let m2Sensors: [SensorDefinition] = [
        .init(key: "Tp1h", name: "Efficiency Core 1", group: .cpu),
        .init(key: "Tp1t", name: "Efficiency Core 2", group: .cpu),
        .init(key: "Tp1p", name: "Efficiency Core 3", group: .cpu),
        .init(key: "Tp1l", name: "Efficiency Core 4", group: .cpu),
        .init(key: "Tp01", name: "Performance Core 1", group: .cpu),
        .init(key: "Tp05", name: "Performance Core 2", group: .cpu),
        .init(key: "Tp09", name: "Performance Core 3", group: .cpu),
        .init(key: "Tp0D", name: "Performance Core 4", group: .cpu),
        .init(key: "Tp0X", name: "Performance Core 5", group: .cpu),
        .init(key: "Tp0b", name: "Performance Core 6", group: .cpu),
        .init(key: "Tp0f", name: "Performance Core 7", group: .cpu),
        .init(key: "Tp0j", name: "Performance Core 8", group: .cpu),
        .init(key: "Tg0f", name: "GPU Cluster 1", group: .gpu),
        .init(key: "Tg0j", name: "GPU Cluster 2", group: .gpu),
    ]

    private static let m3Sensors: [SensorDefinition] = [
        .init(key: "Te05", name: "Efficiency Core 1", group: .cpu),
        .init(key: "Te0L", name: "Efficiency Core 2", group: .cpu),
        .init(key: "Te0P", name: "Efficiency Core 3", group: .cpu),
        .init(key: "Te0S", name: "Efficiency Core 4", group: .cpu),
        .init(key: "Tf04", name: "Performance Core 1", group: .cpu),
        .init(key: "Tf09", name: "Performance Core 2", group: .cpu),
        .init(key: "Tf0A", name: "Performance Core 3", group: .cpu),
        .init(key: "Tf0B", name: "Performance Core 4", group: .cpu),
        .init(key: "Tf0D", name: "Performance Core 5", group: .cpu),
        .init(key: "Tf0E", name: "Performance Core 6", group: .cpu),
        .init(key: "Tf44", name: "Performance Core 7", group: .cpu),
        .init(key: "Tf49", name: "Performance Core 8", group: .cpu),
        .init(key: "Tf4A", name: "Performance Core 9", group: .cpu),
        .init(key: "Tf4B", name: "Performance Core 10", group: .cpu),
        .init(key: "Tf4D", name: "Performance Core 11", group: .cpu),
        .init(key: "Tf4E", name: "Performance Core 12", group: .cpu),
        .init(key: "Tf14", name: "GPU Cluster 1", group: .gpu),
        .init(key: "Tf18", name: "GPU Cluster 2", group: .gpu),
        .init(key: "Tf19", name: "GPU Cluster 3", group: .gpu),
        .init(key: "Tf1A", name: "GPU Cluster 4", group: .gpu),
        .init(key: "Tf24", name: "GPU Cluster 5", group: .gpu),
        .init(key: "Tf28", name: "GPU Cluster 6", group: .gpu),
        .init(key: "Tf29", name: "GPU Cluster 7", group: .gpu),
        .init(key: "Tf2A", name: "GPU Cluster 8", group: .gpu),
    ]

    private static let m4BaseSensors: [SensorDefinition] = [
        .init(key: "Te05", name: "Efficiency Core 1", group: .cpu),
        .init(key: "Te0S", name: "Efficiency Core 2", group: .cpu),
        .init(key: "Te09", name: "Efficiency Core 3", group: .cpu),
        .init(key: "Te0H", name: "Efficiency Core 4", group: .cpu),
        .init(key: "Tp01", name: "Performance Core 1", group: .cpu),
        .init(key: "Tp05", name: "Performance Core 2", group: .cpu),
        .init(key: "Tp09", name: "Performance Core 3", group: .cpu),
        .init(key: "Tp0D", name: "Performance Core 4", group: .cpu),
        .init(key: "Tp0V", name: "Performance Core 5", group: .cpu),
        .init(key: "Tp0Y", name: "Performance Core 6", group: .cpu),
        .init(key: "Tp0b", name: "Performance Core 7", group: .cpu),
        .init(key: "Tp0e", name: "Performance Core 8", group: .cpu),
        .init(key: "Tg0G", name: "GPU Cluster 1", group: .gpu),
        .init(key: "Tg0H", name: "GPU Cluster 2", group: .gpu),
    ]

    private static let m4ProMaxUltraSensors: [SensorDefinition] = [
        .init(key: "Te05", name: "Efficiency Core 1", group: .cpu),
        .init(key: "Te0S", name: "Efficiency Core 2", group: .cpu),
        .init(key: "Te09", name: "Efficiency Core 3", group: .cpu),
        .init(key: "Te0H", name: "Efficiency Core 4", group: .cpu),
        .init(key: "Tp01", name: "Performance Core 1", group: .cpu),
        .init(key: "Tp05", name: "Performance Core 2", group: .cpu),
        .init(key: "Tp09", name: "Performance Core 3", group: .cpu),
        .init(key: "Tp0D", name: "Performance Core 4", group: .cpu),
        .init(key: "Tp0V", name: "Performance Core 5", group: .cpu),
        .init(key: "Tp0Y", name: "Performance Core 6", group: .cpu),
        .init(key: "Tp0b", name: "Performance Core 7", group: .cpu),
        .init(key: "Tp0e", name: "Performance Core 8", group: .cpu),
        .init(key: "Tg1U", name: "GPU Cluster 1", group: .gpu),
        .init(key: "Tg1k", name: "GPU Cluster 2", group: .gpu),
        .init(key: "Tg0K", name: "GPU Cluster 3", group: .gpu),
        .init(key: "Tg0L", name: "GPU Cluster 4", group: .gpu),
        .init(key: "Tg0d", name: "GPU Cluster 5", group: .gpu),
        .init(key: "Tg0e", name: "GPU Cluster 6", group: .gpu),
        .init(key: "Tg0j", name: "GPU Cluster 7", group: .gpu),
        .init(key: "Tg0k", name: "GPU Cluster 8", group: .gpu),
    ]

    private static let m4MemorySensors: [SensorDefinition] = [
        .init(key: "Tm0p", name: "Memory Proximity 1", group: .memory),
        .init(key: "Tm1p", name: "Memory Proximity 2", group: .memory),
        .init(key: "Tm2p", name: "Memory Proximity 3", group: .memory),
    ]

    private static let m5BaseSensors: [SensorDefinition] = [
        .init(key: "Tp00", name: "Super Core 1", group: .cpu),
        .init(key: "Tp04", name: "Super Core 2", group: .cpu),
        .init(key: "Tp0C", name: "Super Core 3", group: .cpu),
        .init(key: "Tp0G", name: "Super Core 4", group: .cpu),
        .init(key: "Tp0X", name: "Super Core 5", group: .cpu),
        .init(key: "Tp0a", name: "Super Core 6", group: .cpu),
        .init(key: "Tp0y", name: "Performance Core 1", group: .cpu),
        .init(key: "Tp12", name: "Performance Core 2", group: .cpu),
        .init(key: "Tp16", name: "Performance Core 3", group: .cpu),
        .init(key: "Tp1E", name: "Performance Core 4", group: .cpu),
        .init(key: "Tg0U", name: "GPU Cluster 1", group: .gpu),
        .init(key: "Tg0X", name: "GPU Cluster 2", group: .gpu),
        .init(key: "Tg0d", name: "GPU Cluster 3", group: .gpu),
        .init(key: "Tg0g", name: "GPU Cluster 4", group: .gpu),
        .init(key: "Tg0j", name: "GPU Cluster 5", group: .gpu),
        .init(key: "Tg1Y", name: "GPU Cluster 6", group: .gpu),
        .init(key: "Tg1c", name: "GPU Cluster 7", group: .gpu),
        .init(key: "Tg1g", name: "GPU Cluster 8", group: .gpu),
    ]

    private static let m5ProMaxUltraSensors: [SensorDefinition] = [
        .init(key: "Tp00", name: "Super Core 1", group: .cpu),
        .init(key: "Tp04", name: "Super Core 2", group: .cpu),
        .init(key: "Tp08", name: "Super Core 3", group: .cpu),
        .init(key: "Tp0C", name: "Super Core 4", group: .cpu),
        .init(key: "Tp0G", name: "Super Core 5", group: .cpu),
        .init(key: "Tp0K", name: "Super Core 6", group: .cpu),
        .init(key: "Tp0O", name: "Performance Core 1", group: .cpu),
        .init(key: "Tp0R", name: "Performance Core 2", group: .cpu),
        .init(key: "Tp0U", name: "Performance Core 3", group: .cpu),
        .init(key: "Tp0X", name: "Performance Core 4", group: .cpu),
        .init(key: "Tp0a", name: "Performance Core 5", group: .cpu),
        .init(key: "Tp0d", name: "Performance Core 6", group: .cpu),
        .init(key: "Tp0g", name: "Performance Core 7", group: .cpu),
        .init(key: "Tp0j", name: "Performance Core 8", group: .cpu),
        .init(key: "Tp0m", name: "Performance Core 9", group: .cpu),
        .init(key: "Tp0p", name: "Performance Core 10", group: .cpu),
        .init(key: "Tp0u", name: "Performance Core 11", group: .cpu),
        .init(key: "Tp0y", name: "Performance Core 12", group: .cpu),
        .init(key: "Tg0U", name: "GPU Cluster 1", group: .gpu),
        .init(key: "Tg0X", name: "GPU Cluster 2", group: .gpu),
        .init(key: "Tg0d", name: "GPU Cluster 3", group: .gpu),
        .init(key: "Tg0g", name: "GPU Cluster 4", group: .gpu),
        .init(key: "Tg0j", name: "GPU Cluster 5", group: .gpu),
        .init(key: "Tg1Y", name: "GPU Cluster 6", group: .gpu),
        .init(key: "Tg1c", name: "GPU Cluster 7", group: .gpu),
        .init(key: "Tg1g", name: "GPU Cluster 8", group: .gpu),
    ]

    private static let commonAppleSensors: [SensorDefinition] = [
        .init(key: "TB1T", name: "Battery 1", group: .battery),
        .init(key: "TB2T", name: "Battery 2", group: .battery),
        .init(key: "TaLP", name: "Airflow Left", group: .airflow),
        .init(key: "TaRF", name: "Airflow Right", group: .airflow),
        .init(key: "TH0x", name: "SSD / NAND", group: .system),
        .init(key: "TW0P", name: "Wireless Proximity", group: .system),
        .init(key: "TTLD", name: "Left Thunderbolt", group: .system),
        .init(key: "TTRD", name: "Right Thunderbolt", group: .system),
    ]
}
