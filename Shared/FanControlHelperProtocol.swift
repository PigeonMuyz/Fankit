import Foundation
import Security

enum FanControlHelperConstants {
    static let machServiceName = "io.github.pigeonmuyz.fankit.helper"
    static let daemonPlistName = "io.github.pigeonmuyz.fankit.helper.plist"
    static let appBundleIdentifier = "io.github.pigeonmuyz.fankit"
}

enum FanControlCodeSigning {
    static func teamIdentifier() -> String? {
        var code: SecCode?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code {
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
                var information: CFDictionary?
                let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
                if SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
                   let dictionary = information as? [CFString: Any],
                   let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier] as? String
                {
                    return teamIdentifier
                }
            }
        }

        guard let task = SecTaskCreateFromSelf(nil),
              let applicationIdentifier = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.application-identifier" as CFString,
                  nil
              ) as? String,
              let teamIdentifier = applicationIdentifier.split(separator: ".").first,
              !teamIdentifier.isEmpty
        else { return nil }
        return String(teamIdentifier)
    }

    static func requirement(identifier: String, teamIdentifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

@objc(FanControlHelperProtocol)
protocol FanControlHelperProtocol {
    func ping(reply: @escaping (String?) -> Void)
    func setSystemMode(reply: @escaping (String?) -> Void)
    func setMaximumMode(reply: @escaping (String?) -> Void)
    func setTargetRPM(_ rpm: Double, fan: Int, reply: @escaping (String?) -> Void)
    func heartbeat()
    func disconnectAndRestore(reply: @escaping (String?) -> Void)
}
