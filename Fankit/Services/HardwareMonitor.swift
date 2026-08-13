import Foundation

final class HardwareMonitor {
    private let smc: SMCConnection

    init() throws {
        smc = try SMCConnection()
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
        Self.sensorDefinitions.compactMap { definition in
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
    private static let sensorDefinitions: [SensorDefinition] = [
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
        .init(key: "Tg0U", name: "GPU Cluster 1", group: .gpu),
        .init(key: "Tg0X", name: "GPU Cluster 2", group: .gpu),
        .init(key: "Tg0d", name: "GPU Cluster 3", group: .gpu),
        .init(key: "Tg0g", name: "GPU Cluster 4", group: .gpu),
        .init(key: "Tg0j", name: "GPU Cluster 5", group: .gpu),
        .init(key: "Tg1Y", name: "GPU Cluster 6", group: .gpu),
        .init(key: "Tg1c", name: "GPU Cluster 7", group: .gpu),
        .init(key: "Tg1g", name: "GPU Cluster 8", group: .gpu),
        .init(key: "Tg05", name: "GPU Cluster 1", group: .gpu),
        .init(key: "Tg0D", name: "GPU Cluster 2", group: .gpu),
        .init(key: "Tg0L", name: "GPU Cluster 3", group: .gpu),
        .init(key: "Tg0T", name: "GPU Cluster 4", group: .gpu),
        .init(key: "Tm02", name: "Memory Bank 1", group: .memory),
        .init(key: "Tm06", name: "Memory Bank 2", group: .memory),
        .init(key: "Tm08", name: "Memory Bank 3", group: .memory),
        .init(key: "Tm09", name: "Memory Bank 4", group: .memory),
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
