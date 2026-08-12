import Darwin
import Foundation
import OSLog

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let state: HelperState
    private let log = Logger(subsystem: FanControlHelperConstants.machServiceName, category: "XPC")

    init(state: HelperState) { self.state = state }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let clientID = UUID()
        connection.exportedInterface = NSXPCInterface(with: FanControlHelperProtocol.self)
        connection.exportedObject = HelperService(clientID: clientID, state: state)
        connection.interruptionHandler = { [weak state] in state?.restore(client: clientID) }
        connection.invalidationHandler = { [weak state] in state?.restore(client: clientID) }
        connection.activate()
        log.notice("Accepted authenticated client")
        return true
    }
}

let log = Logger(subsystem: FanControlHelperConstants.machServiceName, category: "Main")
guard geteuid() == 0 else {
    log.fault("Helper must run as root")
    exit(EXIT_FAILURE)
}
guard let teamIdentifier = FanControlCodeSigning.teamIdentifier() else {
    log.fault("Unable to determine helper Team ID")
    exit(EXIT_FAILURE)
}

let state = HelperState()
let delegate = HelperListenerDelegate(state: state)
let listener = NSXPCListener(machServiceName: FanControlHelperConstants.machServiceName)
var signalSources: [DispatchSourceSignal] = []
listener.setConnectionCodeSigningRequirement(
    FanControlCodeSigning.requirement(
        identifier: FanControlHelperConstants.appBundleIdentifier,
        teamIdentifier: teamIdentifier
    )
)
listener.delegate = delegate

for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        listener.invalidate()
        state.restore(client: nil) { _ in exit(EXIT_SUCCESS) }
    }
    source.activate()
    signalSources.append(source)
}

listener.activate()
log.notice("Fankit helper started")
RunLoop.current.run()
