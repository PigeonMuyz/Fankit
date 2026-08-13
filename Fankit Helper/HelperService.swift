import Darwin
import Foundation
import OSLog
import Security

private enum HelperErrorPayload {
    private static let prefix = "fan-control-error"

    static func encode(_ error: Error?) -> String {
        guard let error else { return "\(prefix)|appleSMCUnavailable" }
        if let error = error as? HelperControlError {
            switch error {
            case .noFans:
                return "\(prefix)|noFans"
            case .invalidFan(let fan):
                return "\(prefix)|invalidFan|\(fan)"
            case .invalidRange(let fan):
                return "\(prefix)|invalidRange|\(fan)"
            case .unsupportedModeKey(let fan):
                return "\(prefix)|unsupportedModeKey|\(fan)"
            case .manualModeNotConfirmed(let fan):
                return "\(prefix)|manualModeNotConfirmed|\(fan)"
            case .restoreNotConfirmed:
                return "\(prefix)|restoreNotConfirmed"
            }
        }
        if let error = error as? SMCError {
            switch error {
            case .connectionFailed(let result):
                return "\(prefix)|smcConnection|0x\(String(UInt32(bitPattern: result), radix: 16))"
            case .invalidKey(let key):
                return "\(prefix)|invalidSMCKey|\(key)"
            case .ioKit(let result):
                return "\(prefix)|ioKit|0x\(String(UInt32(bitPattern: result), radix: 16))"
            case .firmware(let result):
                return "\(prefix)|firmware|0x\(String(result, radix: 16))"
            case .unsupportedValueType(let type):
                return "\(prefix)|unsupportedValueType|\(type)"
            }
        }
        return "\(prefix)|unexpected"
    }
}

final class HelperState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.pigeonmuyz.fankit.helper.state")
    private let log = Logger(subsystem: FanControlHelperConstants.machServiceName, category: "Safety")
    private var controller: FanController?
    private var initializationError: Error?
    private var activeClient: UUID?
    private var lastHeartbeat = ContinuousClock.now
    private var manualOverrideActive = false
    private var watchdog: DispatchSourceTimer?

    init() {
        do {
            controller = try FanController()
        } catch {
            initializationError = error
            log.error("SMC initialization failed: \(error.localizedDescription, privacy: .public)")
        }
        startWatchdog()
    }

    func perform(client: UUID, operation: @escaping (FanController) throws -> Void, reply: @escaping (String?) -> Void) {
        queue.async {
            guard let controller = self.controller else {
                reply(HelperErrorPayload.encode(self.initializationError))
                return
            }
            do {
                try operation(controller)
                self.activeClient = client
                self.lastHeartbeat = .now
                self.manualOverrideActive = true
                reply(nil)
            } catch {
                self.manualOverrideActive = false
                reply(HelperErrorPayload.encode(error))
            }
        }
    }

    func restore(client: UUID?, reply: ((String?) -> Void)? = nil) {
        queue.async {
            if let client, let activeClient = self.activeClient, client != activeClient {
                reply?(nil)
                return
            }
            do {
                try self.controller?.restoreSystemControl()
                self.manualOverrideActive = false
                self.activeClient = nil
                reply?(nil)
            } catch {
                self.log.fault("Failed to restore system control: \(error.localizedDescription, privacy: .public)")
                reply?(HelperErrorPayload.encode(error))
            }
        }
    }

    func heartbeat(client: UUID) {
        queue.async {
            guard self.activeClient == client else { return }
            self.lastHeartbeat = .now
        }
    }

    func ping(reply: @escaping (String?) -> Void) {
        queue.async {
            reply(self.initializationError.map { HelperErrorPayload.encode($0) })
        }
    }

    func installUpdate(
        diskImagePath: String,
        currentAppPath: String,
        releaseVersion: String,
        reply: @escaping (String?) -> Void
    ) {
        queue.async {
            do {
                // Restore macOS fan control before changing the app bundle. The
                // helper exits after the reply so launchd can start the helper
                // bundled inside the new app on the next launch.
                try self.controller?.restoreSystemControl()
                self.manualOverrideActive = false
                self.activeClient = nil
                try PrivilegedAppUpdateInstaller.install(
                    diskImageURL: URL(fileURLWithPath: diskImagePath),
                    currentAppURL: URL(fileURLWithPath: currentAppPath),
                    releaseVersion: releaseVersion,
                    requireCurrentProcessBundle: true
                )
                reply(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) {
                    exit(EXIT_SUCCESS)
                }
            } catch {
                self.log.error("Automatic app update failed: \(error.localizedDescription, privacy: .public)")
                reply("update-installation-failed")
            }
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.manualOverrideActive else { return }
            if self.lastHeartbeat.duration(to: .now) > .seconds(15) {
                self.log.error("Control lease expired; restoring system mode")
                do {
                    try self.controller?.restoreSystemControl()
                    self.manualOverrideActive = false
                    self.activeClient = nil
                } catch {
                    self.log.fault("Watchdog restore failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        timer.activate()
        watchdog = timer
    }
}

final class HelperService: NSObject, FanControlHelperProtocol {
    private let clientID: UUID
    private let state: HelperState

    init(clientID: UUID, state: HelperState) {
        self.clientID = clientID
        self.state = state
    }

    func ping(reply: @escaping (String?) -> Void) { state.ping(reply: reply) }
    func setSystemMode(reply: @escaping (String?) -> Void) { state.restore(client: clientID, reply: reply) }
    func setMaximumMode(reply: @escaping (String?) -> Void) {
        state.perform(client: clientID, operation: { try $0.setMaximum() }, reply: reply)
    }
    func setTargetRPM(_ rpm: Double, fan: Int, reply: @escaping (String?) -> Void) {
        state.perform(client: clientID, operation: { try $0.setTargetRPM(rpm, fan: fan) }, reply: reply)
    }
    func heartbeat() { state.heartbeat(client: clientID) }
    func disconnectAndRestore(reply: @escaping (String?) -> Void) { state.restore(client: clientID, reply: reply) }
    func installUpdate(
        diskImagePath: String,
        currentAppPath: String,
        releaseVersion: String,
        reply: @escaping (String?) -> Void
    ) {
        state.installUpdate(
            diskImagePath: diskImagePath,
            currentAppPath: currentAppPath,
            releaseVersion: releaseVersion,
            reply: reply
        )
    }
    func restartAfterUpdate(reply: @escaping (String?) -> Void) {
        state.restore(client: nil) { errorMessage in
            reply(errorMessage)
            guard errorMessage == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                exit(EXIT_SUCCESS)
            }
        }
    }
}

enum PrivilegedAppUpdateInstaller {
    static func install(
        diskImageURL: URL,
        currentAppURL: URL,
        releaseVersion: String,
        requireCurrentProcessBundle: Bool
    ) throws {
        let currentAppURL = currentAppURL.standardizedFileURL.resolvingSymlinksInPath()
        let currentInfoURL = currentAppURL.appendingPathComponent("Contents/Info.plist")
        guard let currentInfo = NSDictionary(contentsOf: currentInfoURL) as? [String: Any],
              currentInfo["CFBundleIdentifier"] as? String == FanControlHelperConstants.appBundleIdentifier,
              let currentVersion = currentInfo["CFBundleShortVersionString"] as? String
        else {
            throw PrivilegedAppUpdateError.invalidIdentityOrVersion
        }

        if requireCurrentProcessBundle {
            guard runningAppURL() == currentAppURL else {
                throw PrivilegedAppUpdateError.invalidIdentityOrVersion
            }
        }

        guard let teamIdentifier = FanControlCodeSigning.teamIdentifier() else {
            throw PrivilegedAppUpdateError.invalidSignature
        }
        let requirement = FanControlCodeSigning.requirement(
            identifier: FanControlHelperConstants.appBundleIdentifier,
            teamIdentifier: teamIdentifier
        )
        try validateSignature(of: currentAppURL, requirement: requirement)

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
            throw PrivilegedAppUpdateError.appMissing
        }
        try validate(
            appAt: updateAppURL,
            releaseVersion: releaseVersion,
            currentVersion: currentVersion,
            requirement: requirement
        )

        let parentURL = currentAppURL.deletingLastPathComponent()
        let ownerAttributes = try? FileManager.default.attributesOfItem(atPath: currentAppURL.path)
        let stagingURL = parentURL.appendingPathComponent(
            ".Fankit-update-\(UUID().uuidString).app",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        try FileManager.default.copyItem(at: updateAppURL, to: stagingURL)
        if let ownerID = ownerAttributes?[.ownerAccountID] as? NSNumber,
           let groupID = ownerAttributes?[.groupOwnerAccountID] as? NSNumber
        {
            _ = try? run(
                "/usr/sbin/chown",
                arguments: ["-R", "\(ownerID):\(groupID)", stagingURL.path]
            )
        }
        try validate(
            appAt: stagingURL,
            releaseVersion: releaseVersion,
            currentVersion: currentVersion,
            requirement: requirement
        )
        _ = try FileManager.default.replaceItemAt(currentAppURL, withItemAt: stagingURL)
    }

    private static func runningAppURL() -> URL? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func mountedVolume(from data: Data) throws -> URL {
        guard let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
            let entities = propertyList["system-entities"] as? [[String: Any]],
            let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw PrivilegedAppUpdateError.cannotMount
        }
        return URL(fileURLWithPath: mountPath, isDirectory: true)
    }

    private static func validate(
        appAt url: URL,
        releaseVersion: String,
        currentVersion: String,
        requirement: String
    ) throws {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any],
              info["CFBundleIdentifier"] as? String == FanControlHelperConstants.appBundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              version == releaseVersion,
              compareVersions(version, currentVersion) == .orderedDescending
        else {
            throw PrivilegedAppUpdateError.invalidIdentityOrVersion
        }
        try validateSignature(of: url, requirement: requirement)
    }

    private static func validateSignature(of url: URL, requirement: String) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            throw PrivilegedAppUpdateError.invalidSignature
        }

        var requirementRef: SecRequirement?
        guard SecRequirementCreateWithString(
            requirement as CFString,
            [],
            &requirementRef
        ) == errSecSuccess,
            let requirementRef
        else {
            throw PrivilegedAppUpdateError.invalidSignature
        }

        let flags = SecCSFlags(rawValue:
            UInt32(kSecCSStrictValidate)
                | UInt32(kSecCSCheckAllArchitectures)
                | UInt32(kSecCSCheckNestedCode)
        )
        guard SecStaticCodeCheckValidity(staticCode, flags, requirementRef) == errSecSuccess else {
            throw PrivilegedAppUpdateError.invalidSignature
        }
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive])
    }

    private static func eject(_ mountPoint: URL) throws {
        _ = try run("/usr/sbin/diskutil", arguments: ["eject", mountPoint.path])
    }

    @discardableResult
    private static func run(_ executable: String, arguments: [String]) throws -> Data {
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
            throw PrivilegedAppUpdateError.commandFailed(message)
        }
        return output
    }
}

private enum PrivilegedAppUpdateError: LocalizedError {
    case cannotMount
    case appMissing
    case invalidIdentityOrVersion
    case invalidSignature
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotMount: "Unable to mount the update disk image."
        case .appMissing: "The update disk image does not contain Fankit.app."
        case .invalidIdentityOrVersion: "The update identity or version is invalid."
        case .invalidSignature: "The update signature is invalid."
        case .commandFailed(let message): message.isEmpty ? "The update command failed." : message
        }
    }
}
