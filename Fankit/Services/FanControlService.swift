import AppKit
import Foundation
import ServiceManagement

enum FanControlError: LocalizedError {
    case helperUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable(let message): message
        }
    }
}

enum ControlHelperStatus: Equatable {
    case notInstalled
    case requiresApproval
    case enabled
    case ready
    case notFound
    case failed(String)

    var title: String {
        switch self {
        case .notInstalled: L10n.string("Not Installed")
        case .requiresApproval: L10n.string("Needs Approval")
        case .enabled: L10n.string("Connecting")
        case .ready: L10n.string("Ready")
        case .notFound: L10n.string("Not Found")
        case .failed: L10n.string("Unavailable")
        }
    }

    var detail: String {
        switch self {
        case .notInstalled: L10n.string("Install the native control helper to use Max and Auto Boost.")
        case .requiresApproval: L10n.string("Allow Fankit in System Settings > Login Items.")
        case .enabled: L10n.string("The helper is enabled and establishing a secure connection.")
        case .ready: L10n.string("Code signing verification and the AppleSMC connection are ready.")
        case .notFound: L10n.string("The helper is not registered yet. Enable control to create its service record.")
        case .failed(let message): message
        }
    }

    var actionTitle: String {
        switch self {
        case .requiresApproval:
            L10n.string("Open System Settings")
        case .failed:
            L10n.string("Repair Control")
        default:
            L10n.string("Enable Control")
        }
    }
}

@MainActor
final class FanControlService {
    private let daemon = SMAppService.daemon(plistName: FanControlHelperConstants.daemonPlistName)
    private var connection: NSXPCConnection?
    private var heartbeatTimer: Timer?
    private var hasAttemptedAutomaticRepair = false

    var status: ControlHelperStatus = .notInstalled
    var canWrite: Bool { status == .ready }

    deinit {
        heartbeatTimer?.invalidate()
        connection?.invalidate()
    }

    func refreshStatus() async -> ControlHelperStatus {
        switch daemon.status {
        case .notRegistered:
            invalidateConnection()
            status = .notInstalled
        case .requiresApproval:
            invalidateConnection()
            status = .requiresApproval
        case .notFound:
            invalidateConnection()
            status = .notFound
        case .enabled:
            status = .enabled
            do {
                try await ping()
                status = .ready
            } catch {
                guard !hasAttemptedAutomaticRepair else {
                    status = .failed(error.localizedDescription)
                    break
                }

                // Updating the app replaces the on-disk helper while launchd may
                // still be running the previous executable. Its live signature
                // then fails validation, so refresh the registration once before
                // asking the user to repair anything manually.
                hasAttemptedAutomaticRepair = true
                NSLog("Fankit helper connection failed; refreshing its registration: %@", error.localizedDescription)
                do {
                    status = try await restartDaemonAfterUpdate()
                } catch {
                    NSLog("Fankit helper could not restart in place; using legacy registration repair: %@", error.localizedDescription)
                    do {
                        status = try await registerCurrentDaemon(replacingExisting: true)
                    } catch {
                        status = .failed(error.localizedDescription)
                    }
                }
            }
        @unknown default:
            status = .failed(L10n.string("Unknown helper status."))
        }
        return status
    }

    func install() async throws -> ControlHelperStatus {
        if daemon.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            status = .requiresApproval
            return status
        }

        do {
            hasAttemptedAutomaticRepair = true
            status = try await registerCurrentDaemon(replacingExisting: daemon.status == .enabled)
        } catch {
            NSLog("Fankit helper registration error: %@", error.localizedDescription)
            let message = L10n.string("Unable to update the control helper.")
            status = .failed(message)
            throw FanControlError.helperUnavailable(message)
        }

        if daemon.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        return status
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func installUpdate(
        diskImageURL: URL,
        currentAppURL: URL,
        releaseVersion: String
    ) async throws {
        guard daemon.status == .enabled else {
            throw FanControlError.helperUnavailable(status.detail)
        }

        let connection = try helperConnection()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: FanControlError.helperUnavailable(
                    error.localizedDescription
                ))
            }
            guard let helper = proxy as? FanControlHelperProtocol else {
                continuation.resume(throwing: FanControlError.helperUnavailable(
                    L10n.string("Unable to create the helper XPC proxy.")
                ))
                return
            }
            helper.installUpdate(
                diskImagePath: diskImageURL.path,
                currentAppPath: currentAppURL.path,
                releaseVersion: releaseVersion
            ) { errorMessage in
                if let errorMessage {
                    continuation.resume(throwing: FanControlError.helperUnavailable(
                        self.localizedHelperError(errorMessage)
                    ))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func prepareForAppUpdate() async throws {
        guard daemon.status == .enabled else { return }
        _ = try await restartDaemonAfterUpdate()
    }

    func apply(_ mode: FanControlMode) async throws {
        switch mode {
        case .system:
            try await call { proxy, reply in proxy.setSystemMode(reply: reply) }
            stopHeartbeat()
        case .maximum:
            try await call { proxy, reply in proxy.setMaximumMode(reply: reply) }
            startHeartbeat()
        case .autoBoost:
            // The store evaluates the selected curve and sends bounded targets.
            break
        case .aiScheduling:
            // The store evaluates the validated AI curve and sends bounded targets.
            break
        }
    }

    func setTargetRPM(_ rpm: Double, fan: Int) async throws {
        try await call { proxy, reply in proxy.setTargetRPM(rpm, fan: fan, reply: reply) }
        startHeartbeat()
    }

    private func ping() async throws {
        try await call(requireReadyStatus: false) { proxy, reply in proxy.ping(reply: reply) }
    }

    private func unregisterCurrentDaemon() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            daemon.unregister { (error: Error?) in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func registerCurrentDaemon(replacingExisting: Bool) async throws -> ControlHelperStatus {
        invalidateConnection()
        if replacingExisting {
            try await unregisterCurrentDaemon()
        }

        do {
            try daemon.register()
        } catch {
            // Service Management can report a denied launch at the same time as
            // it moves the service into requiresApproval. Preserve that precise
            // state so the UI asks for one approval instead of offering Repair.
            if daemon.status == .requiresApproval
                || (error as NSError).code == kSMErrorLaunchDeniedByUser
            {
                status = .requiresApproval
                return status
            }
            throw error
        }

        return await waitForDaemonToBecomeReady()
    }

    private func restartDaemonAfterUpdate() async throws -> ControlHelperStatus {
        // Do not attach a client-side code requirement to this one-shot
        // connection. Immediately after an update, the old process no longer
        // matches the helper file that replaced it on disk. The helper still
        // authenticates this app before accepting the connection, and this
        // channel can only request a safe restore-and-exit operation.
        invalidateConnection()
        let restartConnection = NSXPCConnection(
            machServiceName: FanControlHelperConstants.machServiceName,
            options: .privileged
        )
        restartConnection.remoteObjectInterface = NSXPCInterface(with: FanControlHelperProtocol.self)
        restartConnection.activate()

        defer { restartConnection.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proxy = restartConnection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            }
            guard let helper = proxy as? FanControlHelperProtocol else {
                continuation.resume(throwing: FanControlError.helperUnavailable(
                    L10n.string("Unable to create the helper XPC proxy.")
                ))
                return
            }
            helper.restartAfterUpdate { errorMessage in
                if let errorMessage {
                    continuation.resume(throwing: FanControlError.helperUnavailable(
                        self.localizedHelperError(errorMessage)
                    ))
                } else {
                    continuation.resume()
                }
            }
        }

        return await waitForDaemonToBecomeReady()
    }

    private func waitForDaemonToBecomeReady() async -> ControlHelperStatus {
        var lastConnectionError: Error?

        for attempt in 0..<50 {
            switch daemon.status {
            case .enabled:
                status = .enabled
                do {
                    try await ping()
                    status = .ready
                    return status
                } catch {
                    lastConnectionError = error
                    invalidateConnection()
                }
            case .requiresApproval:
                status = .requiresApproval
                return status
            case .notRegistered, .notFound:
                break
            @unknown default:
                status = .failed(L10n.string("Unknown helper status."))
                return status
            }

            if attempt < 49 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        status = .failed(
            lastConnectionError?.localizedDescription
                ?? L10n.string("Unable to communicate with the control helper.")
        )
        return status
    }

    private func call(
        requireReadyStatus: Bool = true,
        _ body: @escaping (FanControlHelperProtocol, @escaping (String?) -> Void) -> Void
    ) async throws {
        if requireReadyStatus && daemon.status != .enabled {
            throw FanControlError.helperUnavailable(status.detail)
        }

        let connection = try helperConnection()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                NSLog("Fankit helper XPC error: %@", error.localizedDescription)
                continuation.resume(throwing: FanControlError.helperUnavailable(
                    L10n.string("Unable to communicate with the control helper.")
                ))
            }
            guard let helper = proxy as? FanControlHelperProtocol else {
                continuation.resume(throwing: FanControlError.helperUnavailable(L10n.string("Unable to create the helper XPC proxy.")))
                return
            }
            body(helper) { errorMessage in
                if let errorMessage {
                    continuation.resume(throwing: FanControlError.helperUnavailable(
                        self.localizedHelperError(errorMessage)
                    ))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func helperConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        guard let teamIdentifier = FanControlCodeSigning.teamIdentifier() else {
            throw FanControlError.helperUnavailable(L10n.string("Unable to read the main application's Team ID."))
        }

        let connection = NSXPCConnection(
            machServiceName: FanControlHelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: FanControlHelperProtocol.self)
        connection.setCodeSigningRequirement(
            FanControlCodeSigning.requirement(
                identifier: FanControlHelperConstants.machServiceName,
                teamIdentifier: teamIdentifier
            )
        )
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.invalidateConnection() }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.invalidateConnection() }
        }
        connection.activate()
        self.connection = connection
        return connection
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = Timer(
            timeInterval: 5,
            target: self,
            selector: #selector(sendHeartbeat),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    @objc private func sendHeartbeat() {
        guard let connection,
              let helper = connection.remoteObjectProxy as? FanControlHelperProtocol
        else { return }
        helper.heartbeat()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    private func invalidateConnection() {
        stopHeartbeat()
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
    }

    private func localizedHelperError(_ payload: String) -> String {
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[0] == "fan-control-error" else {
            return payload
        }
        let integer = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        let value = parts.count > 2 ? parts[2] : ""
        switch parts[1] {
        case "appleSMCUnavailable":
            return L10n.string("AppleSMC is unavailable.")
        case "noFans":
            return L10n.string("No controllable fans were detected.")
        case "invalidFan":
            return L10n.format("Fan %d does not exist.", integer)
        case "invalidRange":
            return L10n.format("Fan %d did not report a valid safe RPM range.", integer)
        case "unsupportedModeKey":
            return L10n.format("The control-mode key for fan %d was not found.", integer)
        case "manualModeNotConfirmed":
            return L10n.format("Manual mode for fan %d could not be confirmed.", integer)
        case "restoreNotConfirmed":
            return L10n.string("Could not confirm that macOS resumed fan control.")
        case "smcConnection":
            return L10n.format("Unable to connect to AppleSMC (code %@).", value)
        case "invalidSMCKey":
            return L10n.format(
                "The SMC key must contain exactly four ASCII characters: %@.",
                value
            )
        case "ioKit":
            return L10n.format("The IOKit call failed (code %@).", value)
        case "firmware":
            return L10n.format("The SMC firmware rejected the request (code %@).", value)
        case "unsupportedValueType":
            return L10n.format("The SMC data type %@ is not supported.", value)
        case "update-installation-failed":
            return L10n.string("The privileged helper could not install the update.")
        default:
            return L10n.string("The control helper reported an unexpected error.")
        }
    }
}
