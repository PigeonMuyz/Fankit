import AppKit
import Foundation

enum PreferenceKey {
    static let savedFanMode = "savedFanControlMode"
    static let hideDockIcon = "hideDockIcon"
    static let appLanguage = "appLanguage"
    static let menuBarShowCPU = "menuBarShowCPU"
    static let menuBarShowGPU = "menuBarShowGPU"
    static let menuBarShowFanSpeed = "menuBarShowFanSpeed"
}

enum ApplicationPreferences {
    static func prepareDefaults() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: PreferenceKey.menuBarShowCPU) == nil {
            let legacyStyle = MenuBarDisplayStyle(
                rawValue: defaults.string(forKey: "menuBarDisplayStyle") ?? ""
            ) ?? .temperaturesAndRPM
            defaults.set(
                legacyStyle == .temperaturesAndRPM || legacyStyle == .temperaturesOnly,
                forKey: PreferenceKey.menuBarShowCPU
            )
            defaults.set(
                legacyStyle == .temperaturesAndRPM || legacyStyle == .temperaturesOnly,
                forKey: PreferenceKey.menuBarShowGPU
            )
            defaults.set(
                legacyStyle == .temperaturesAndRPM || legacyStyle == .rpmOnly,
                forKey: PreferenceKey.menuBarShowFanSpeed
            )
        }

        defaults.register(defaults: [
            PreferenceKey.savedFanMode: FanControlMode.system.rawValue,
            PreferenceKey.hideDockIcon: false,
            PreferenceKey.appLanguage: AppLanguage.system.rawValue,
            PreferenceKey.menuBarShowCPU: true,
            PreferenceKey.menuBarShowGPU: true,
            PreferenceKey.menuBarShowFanSpeed: true,
            "menuBarIconStyle": MenuBarIconStyle.thermometer.rawValue,
            "menuBarCustomSymbol": "thermometer.medium",
            "refreshInterval": 2.0,
        ])
    }

    @MainActor
    static func applyDockPreference(activate: Bool = false) {
        let hideDockIcon = UserDefaults.standard.bool(forKey: PreferenceKey.hideDockIcon)
        NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

enum L10n {
    static func string(_ key: String) -> String {
        let raw = UserDefaults.standard.string(forKey: PreferenceKey.appLanguage)
            ?? AppLanguage.system.rawValue
        guard let language = AppLanguage(rawValue: raw),
              let resource = language.resourceName,
              let path = Bundle.main.path(forResource: resource, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: currentLocale, arguments: arguments)
    }

    static func error(_ error: Error) -> String {
        guard let error = error as? SMCError else { return error.localizedDescription }
        switch error {
        case .connectionFailed(let result):
            return format(
                "Unable to connect to AppleSMC (code %@).",
                "0x\(String(UInt32(bitPattern: result), radix: 16))"
            )
        case .invalidKey(let key):
            return format("The SMC key must contain exactly four ASCII characters: %@.", key)
        case .ioKit(let result):
            return format(
                "The IOKit call failed (code %@).",
                "0x\(String(UInt32(bitPattern: result), radix: 16))"
            )
        case .firmware(let result):
            return format(
                "The SMC firmware rejected the request (code %@).",
                "0x\(String(result, radix: 16))"
            )
        case .unsupportedValueType(let type):
            return format("The SMC data type %@ is not supported.", type)
        }
    }

    private static var currentLocale: Locale {
        let raw = UserDefaults.standard.string(forKey: PreferenceKey.appLanguage)
            ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: raw)?.locale ?? .autoupdatingCurrent
    }
}
