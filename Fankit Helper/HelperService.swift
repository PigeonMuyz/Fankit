import Darwin
import Foundation
import OSLog

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
