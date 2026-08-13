import Darwin
import Foundation
import OSLog

if CommandLine.arguments.contains("--install-update") {
    guard geteuid() == 0 else {
        fputs("Fankit update installer must run as root.\n", stderr)
        exit(EXIT_FAILURE)
    }

    func argumentValue(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              index + 1 < CommandLine.arguments.count
        else { return nil }
        return CommandLine.arguments[index + 1]
    }

    guard let diskImagePath = argumentValue("--disk-image"),
          let currentAppPath = argumentValue("--current-app"),
          let releaseVersion = argumentValue("--release-version")
    else {
        fputs("Missing update installer arguments.\n", stderr)
        exit(EXIT_FAILURE)
    }

    do {
        try PrivilegedAppUpdateInstaller.install(
            diskImageURL: URL(fileURLWithPath: diskImagePath),
            currentAppURL: URL(fileURLWithPath: currentAppPath),
            releaseVersion: releaseVersion,
            requireCurrentProcessBundle: false
        )
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Fankit update installation failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

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
