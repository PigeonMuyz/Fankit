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

struct MenuBarStatusPresentation: Equatable {
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

@MainActor
enum MenuBarStatusImageRenderer {
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: MenuBarStatusMetrics.fontSize,
        weight: .medium
    )

    static func image(for presentation: MenuBarStatusPresentation) -> NSImage {
        let width = preferredWidth(for: presentation)
        let size = NSSize(width: width, height: MenuBarStatusMetrics.contentHeight)
        let image = NSImage(size: size)
        image.isTemplate = true
        image.lockFocus()
        defer { image.unlockFocus() }

        let hasIcon = presentation.symbolName != nil
        let textX = hasIcon && presentation.layout != .iconOnly
            ? MenuBarStatusMetrics.iconSize + MenuBarStatusMetrics.iconTextSpacing
            : 0
        let iconX = presentation.layout == .iconOnly
            ? floor((size.width - MenuBarStatusMetrics.iconSize) / 2)
            : 0

        if let symbolName = presentation.symbolName,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        {
            let configuredSymbol = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.white])
            ) ?? symbol
            configuredSymbol.draw(
                in: NSRect(
                    x: iconX,
                    y: floor((size.height - MenuBarStatusMetrics.iconSize) / 2),
                    width: MenuBarStatusMetrics.iconSize,
                    height: MenuBarStatusMetrics.iconSize
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        if let firstLine = presentation.firstLine {
            NSString(string: firstLine).draw(
                in: NSRect(
                    x: textX,
                    y: presentation.layout == .singleLine
                        ? floor((size.height - 14) / 2)
                        : 11,
                    width: size.width - textX,
                    height: presentation.layout == .singleLine ? 14 : MenuBarStatusMetrics.lineHeight
                ),
                withAttributes: attributes
            )
        }
        if let secondLine = presentation.secondLine {
            NSString(string: secondLine).draw(
                in: NSRect(
                    x: textX,
                    y: 1,
                    width: size.width - textX,
                    height: MenuBarStatusMetrics.lineHeight
                ),
                withAttributes: attributes
            )
        }
        return image
    }

    private static func preferredWidth(for presentation: MenuBarStatusPresentation) -> CGFloat {
        let hasIcon = presentation.symbolName != nil
        let iconWidth = hasIcon
            ? MenuBarStatusMetrics.iconSize
                + (presentation.hasText ? MenuBarStatusMetrics.iconTextSpacing : 0)
            : 0
        let textWidth = max(
            presentation.firstLine.map(measure) ?? 0,
            presentation.secondLine.map(measure) ?? 0
        )
        return max(
            iconWidth + textWidth,
            hasIcon ? MenuBarStatusMetrics.iconSize + 2 : 20
        )
    }

    private static func measure(_ string: String) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width) + 2
    }
}
