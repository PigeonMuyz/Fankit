import Foundation
import Security

enum AppUpdateInstallationResult: Sendable {
    case installed(URL)
    case requiresAdministratorAuthorization(URL)
}

enum AppUpdateInstaller {
    nonisolated static func install(
        diskImageURL: URL,
        releaseVersion: String,
        currentVersion: String,
        currentAppURL: URL,
        bundleIdentifier: String,
        codeSigningRequirement: String
    ) throws -> AppUpdateInstallationResult {
        let mountData = try run(
            "/usr/sbin/diskutil",
            arguments: [
                "image", "attach", "--mountOptions", "nobrowse", "--readOnly", "--plist",
                diskImageURL.path,
            ]
        )
        let mountPoint = try mountedVolume(from: mountData)
        defer { try? eject(mountPoint) }

        let updateAppURL = mountPoint.appendingPathComponent("Fankit.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: updateAppURL.path) else {
            throw AppUpdateInstallationError.appMissing
        }
        try validate(
            appAt: updateAppURL,
            releaseVersion: releaseVersion,
            currentVersion: currentVersion,
            bundleIdentifier: bundleIdentifier,
            codeSigningRequirement: codeSigningRequirement
        )

        let parentURL = currentAppURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentURL.path) else {
            return .requiresAdministratorAuthorization(diskImageURL)
        }

        let stagingURL = parentURL.appendingPathComponent(
            ".Fankit-update-\(UUID().uuidString).app",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        do {
            try FileManager.default.copyItem(at: updateAppURL, to: stagingURL)
            try validate(
                appAt: stagingURL,
                releaseVersion: releaseVersion,
                currentVersion: currentVersion,
                bundleIdentifier: bundleIdentifier,
                codeSigningRequirement: codeSigningRequirement
            )
            _ = try FileManager.default.replaceItemAt(currentAppURL, withItemAt: stagingURL)
            return .installed(currentAppURL)
        } catch let error as AppUpdateInstallationError {
            throw error
        } catch {
            return .requiresAdministratorAuthorization(diskImageURL)
        }
    }

    nonisolated static func installUsingAdministratorPrivileges(
        diskImageURL: URL,
        releaseVersion: String,
        currentVersion: String,
        currentAppURL: URL,
        bundleIdentifier: String,
        codeSigningRequirement: String
    ) throws {
        let mountData = try run(
            "/usr/sbin/diskutil",
            arguments: [
                "image", "attach", "--mountOptions", "nobrowse", "--readOnly", "--plist",
                diskImageURL.path,
            ]
        )
        let mountPoint = try mountedVolume(from: mountData)
        defer { try? eject(mountPoint) }

        let updateAppURL = mountPoint.appendingPathComponent("Fankit.app", isDirectory: true)
        let helperURL = updateAppURL.appendingPathComponent(
            "Contents/MacOS/FankitHelper",
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: updateAppURL.path),
              FileManager.default.isExecutableFile(atPath: helperURL.path)
        else {
            throw AppUpdateInstallationError.appMissing
        }
        try validate(
            appAt: updateAppURL,
            releaseVersion: releaseVersion,
            currentVersion: currentVersion,
            bundleIdentifier: bundleIdentifier,
            codeSigningRequirement: codeSigningRequirement
        )

        let command = [
            shellQuote(helperURL.path),
            "--install-update",
            "--disk-image", shellQuote(diskImageURL.path),
            "--current-app", shellQuote(currentAppURL.path),
            "--release-version", shellQuote(releaseVersion),
        ].joined(separator: " ")
        let script = "do shell script \(appleScriptString(command)) with administrator privileges"
        _ = try run("/usr/bin/osascript", arguments: ["-e", script])
    }

    private nonisolated static func mountedVolume(from data: Data) throws -> URL {
        guard let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
            let entities = propertyList["system-entities"] as? [[String: Any]],
            let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw AppUpdateInstallationError.cannotMount
        }
        return URL(fileURLWithPath: mountPath, isDirectory: true)
    }

    private nonisolated static func validate(
        appAt url: URL,
        releaseVersion: String,
        currentVersion: String,
        bundleIdentifier: String,
        codeSigningRequirement: String
    ) throws {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              version == releaseVersion,
              GitHubUpdateService.compareVersions(version, currentVersion) == .orderedDescending
        else {
            throw AppUpdateInstallationError.invalidIdentityOrVersion
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            throw AppUpdateInstallationError.invalidSignature
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            codeSigningRequirement as CFString,
            [],
            &requirement
        ) == errSecSuccess,
            let requirement
        else {
            throw AppUpdateInstallationError.invalidSignature
        }

        let flags = SecCSFlags(rawValue:
            UInt32(kSecCSStrictValidate)
                | UInt32(kSecCSCheckAllArchitectures)
                | UInt32(kSecCSCheckNestedCode)
        )
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw AppUpdateInstallationError.invalidSignature
        }
    }

    private nonisolated static func eject(_ mountPoint: URL) throws {
        _ = try run("/usr/sbin/diskutil", arguments: ["eject", mountPoint.path])
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private nonisolated static func appleScriptString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    @discardableResult
    private nonisolated static func run(_ executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errorData, encoding: .utf8) ?? ""
            throw AppUpdateInstallationError.commandFailed(message)
        }
        return output
    }
}

enum AppUpdateInstallationError: Error {
    case cannotMount
    case appMissing
    case invalidIdentityOrVersion
    case invalidSignature
    case commandFailed(String)
}
