import AppKit

enum MenuBarStatusLayout {
    case iconOnly
    case singleLine
    case twoLine
}

enum MenuBarStatusMetrics {
    static let contentHeight: CGFloat = NSStatusBar.system.thickness
    static let iconSize: CGFloat = 16
    static let iconTextSpacing: CGFloat = 3
    static let fontSize: CGFloat = 9
    static let lineHeight: CGFloat = 11
}

struct MenuBarStatusPresentation {
    let symbolName: String?
    let firstLine: String?
    let secondLine: String?
    let accessibilitySummary: String

    var layout: MenuBarStatusLayout {
        if secondLine != nil { return .twoLine }
        if firstLine != nil { return .singleLine }
        return .iconOnly
    }

    var hasText: Bool {
        firstLine != nil
    }

    init(
        cpuTemperature: Double?,
        gpuTemperature: Double?,
        rpm: Double?,
        showCPU: Bool,
        showGPU: Bool,
        showFanSpeed: Bool,
        iconStyle: MenuBarIconStyle,
        customSymbol: String
    ) {
        let temperatureLine: String? = switch (showCPU, showGPU) {
        case (true, true):
            "\(Self.formatTemperature(cpuTemperature)) / \(Self.formatTemperature(gpuTemperature))"
        case (true, false):
            "CPU \(Self.formatTemperature(cpuTemperature))"
        case (false, true):
            "GPU \(Self.formatTemperature(gpuTemperature))"
        case (false, false):
            nil
        }
        let fanLine = showFanSpeed
            ? rpm.map { "\(Int($0.rounded())) RPM" } ?? "---- RPM"
            : nil

        if let temperatureLine {
            firstLine = temperatureLine
            secondLine = fanLine
        } else {
            firstLine = fanLine
            secondLine = nil
        }

        let requestedSymbol: String?
        if firstLine == nil && iconStyle == .hidden {
            requestedSymbol = "thermometer.medium"
        } else {
            requestedSymbol = iconStyle.symbol(customSymbol: customSymbol)
        }
        symbolName = Self.validatedSymbol(requestedSymbol)

        var accessibilityParts = ["Fankit"]
        if showCPU {
            accessibilityParts.append("CPU \(Self.formatTemperature(cpuTemperature))")
        }
        if showGPU {
            accessibilityParts.append("GPU \(Self.formatTemperature(gpuTemperature))")
        }
        if let fanLine {
            accessibilityParts.append(fanLine)
        }
        accessibilitySummary = accessibilityParts.joined(separator: ", ")
    }

    private static func formatTemperature(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))°C" } ?? "--°C"
    }

    private static func validatedSymbol(_ requestedSymbol: String?) -> String? {
        guard let requestedSymbol else { return nil }
        if NSImage(systemSymbolName: requestedSymbol, accessibilityDescription: nil) != nil {
            return requestedSymbol
        }
        return "thermometer.medium"
    }
}
