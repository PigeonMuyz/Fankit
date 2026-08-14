import Foundation

enum FanControlMode: String, CaseIterable, Identifiable {
    case system
    case maximum
    case autoBoost
    case aiScheduling

    var id: Self { self }

    var title: String {
        switch self {
        case .system: L10n.string("System")
        case .maximum: L10n.string("Max")
        case .autoBoost: L10n.string("Auto Boost")
        case .aiScheduling: L10n.string("AI Scheduling")
        }
    }
}

enum MenuBarSchedule: String, CaseIterable, Identifiable {
    case systemScheduling
    case extremeCooling
    case customScheduling
    case aiScheduling

    var id: Self { self }

    var title: String {
        switch self {
        case .systemScheduling: L10n.string("System Scheduling")
        case .extremeCooling: L10n.string("Extreme Cooling")
        case .customScheduling: L10n.string("Custom Scheduling")
        case .aiScheduling: L10n.string("AI Scheduling")
        }
    }

    var systemImage: String {
        switch self {
        case .systemScheduling: "checkmark.circle"
        case .extremeCooling: "fan.fill"
        case .customScheduling: "chart.xyaxis.line"
        case .aiScheduling: "sparkles"
        }
    }

    var fanControlMode: FanControlMode? {
        switch self {
        case .systemScheduling: .system
        case .extremeCooling: .maximum
        case .customScheduling: .autoBoost
        case .aiScheduling: .aiScheduling
        }
    }

    var isAvailable: Bool { fanControlMode != nil }

    init(mode: FanControlMode) {
        switch mode {
        case .system: self = .systemScheduling
        case .maximum: self = .extremeCooling
        case .autoBoost: self = .customScheduling
        case .aiScheduling: self = .aiScheduling
        }
    }
}

struct FanSnapshot: Identifiable, Equatable {
    let index: Int
    let name: String
    let currentRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double

    var id: Int { index }

    var fraction: Double {
        fraction(forRPM: currentRPM)
    }

    func fraction(forRPM rpm: Double) -> Double {
        guard maximumRPM > 0 else { return 0 }
        return min(max(rpm / maximumRPM, 0), 1)
    }
}

struct LiveTelemetrySample: Identifiable, Equatable {
    let timestamp: Date
    let temperature: Double
    let fans: [FanSnapshot]

    var id: Date { timestamp }
}

enum ThermalGroup: String, CaseIterable, Identifiable {
    case cpu = "Processor"
    case gpu = "Graphics"
    case memory = "Memory"
    case battery = "Battery"
    case airflow = "Airflow"
    case system = "System"

    var id: Self { self }

    var title: String { L10n.string(rawValue) }
}

struct ThermalSensor: Identifiable, Equatable {
    let key: String
    let name: String
    let group: ThermalGroup
    let celsius: Double

    var id: String { key }
}

struct SensorDefinition: Sendable {
    let key: String
    let name: String
    let group: ThermalGroup
}

enum MenuBarDisplayStyle: String, CaseIterable, Identifiable {
    case temperaturesAndRPM
    case temperaturesOnly
    case rpmOnly
    case iconOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .temperaturesAndRPM: L10n.string("Temperatures + RPM")
        case .temperaturesOnly: L10n.string("Temperatures only")
        case .rpmOnly: L10n.string("RPM only")
        case .iconOnly: L10n.string("Icon only")
        }
    }
}

enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    case thermometer
    case fan
    case gauge
    case custom
    case hidden

    var id: Self { self }

    var title: String {
        switch self {
        case .thermometer: L10n.string("Thermometer")
        case .fan: L10n.string("Fan")
        case .gauge: L10n.string("Gauge")
        case .custom: L10n.string("Custom SF Symbol")
        case .hidden: L10n.string("No icon")
        }
    }

    func symbol(customSymbol: String) -> String? {
        switch self {
        case .thermometer: "thermometer.medium"
        case .fan: "fan"
        case .gauge: "gauge.with.dots.needle.67percent"
        case .custom: customSymbol.isEmpty ? "thermometer.medium" : customSymbol
        case .hidden: nil
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case japanese
    case cantonese
    case mandarin

    var id: Self { self }

    var title: String {
        switch self {
        case .system: L10n.string("Follow System")
        case .english: "English"
        case .japanese: "日本語"
        case .cantonese: "粵語"
        case .mandarin: "普通话"
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .japanese: Locale(identifier: "ja")
        case .cantonese: Locale(identifier: "yue-Hant-HK")
        case .mandarin: Locale(identifier: "zh-Hans")
        }
    }

    var resourceName: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .japanese: "ja"
        case .cantonese: "yue-Hant"
        case .mandarin: "zh-Hans"
        }
    }
}
