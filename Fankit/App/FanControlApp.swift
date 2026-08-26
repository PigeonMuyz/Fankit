import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var defaultsObserver: NSObjectProtocol?
    private var applicationObservers: [NSObjectProtocol] = []
    private var dockPreferenceTask: Task<Void, Never>?
    private var store: FanControlStore?
    private var didFinishLaunching = false
    private var openMainWindowHandler: (() -> Void)?
    private var shouldOpenMainWindowWhenReady = false

    func prepare(store: FanControlStore) {
        self.store = store
        installServicesIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDockPreferenceUpdate() }
        }
        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDockPreferenceUpdate() }
        })
        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleDockPreferenceUpdate() }
        })

        installServicesIfNeeded()
        scheduleDockPreferenceUpdate(activate: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func setOpenMainWindowHandler(_ handler: @escaping () -> Void) {
        openMainWindowHandler = handler
        guard shouldOpenMainWindowWhenReady else { return }
        shouldOpenMainWindowWhenReady = false
        handler()
    }

    deinit {
        dockPreferenceTask?.cancel()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        for observer in applicationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func installServicesIfNeeded() {
        guard didFinishLaunching,
              let store,
              statusItemController == nil
        else { return }

        statusItemController = StatusItemController(
            store: store,
            openMainWindow: { [weak self] in
                self?.requestOpenMainWindow()
            }
        )
        store.start()
        scheduleDockPreferenceUpdate()
    }

    private func requestOpenMainWindow() {
        guard let openMainWindowHandler else {
            shouldOpenMainWindowWhenReady = true
            return
        }
        openMainWindowHandler()
    }

    private func scheduleDockPreferenceUpdate(activate: Bool = false) {
        dockPreferenceTask?.cancel()
        dockPreferenceTask = Task { @MainActor [weak self] in
            // SwiftUI may create the first window after didFinishLaunching. Retry
            // until AppKit accepts the requested activation policy instead of
            // assuming the initial call succeeded.
            for delayMilliseconds in [0, 50, 150, 350, 750, 1_500] {
                if delayMilliseconds > 0 {
                    try? await Task.sleep(for: .milliseconds(delayMilliseconds))
                }
                guard !Task.isCancelled, let self else { return }
                if self.updateDockPreference(activate: activate) {
                    return
                }
            }

            NSLog("Fankit could not apply the requested Dock activation policy")
        }
    }

    @discardableResult
    private func updateDockPreference(activate: Bool = false) -> Bool {
        let shouldHide = UserDefaults.standard.bool(forKey: PreferenceKey.hideDockIcon)
        return ApplicationPreferences.applyDockPreference(
            activate: activate && !shouldHide
        )
    }
}

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: FanControlStore
    @State private var updateService: GitHubUpdateService
    @AppStorage(PreferenceKey.appLanguage) private var languageRaw = AppLanguage.system.rawValue

    init() {
        ApplicationPreferences.prepareDefaults()
        let store = FanControlStore()
        _store = State(initialValue: store)
        _updateService = State(initialValue: GitHubUpdateService())
        appDelegate.prepare(store: store)
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .system
    }

    var body: some Scene {
        Window("Fankit", id: "main") {
            ContentView(store: store, updateService: updateService)
                .frame(minWidth: 720, minHeight: 560)
                .environment(\.locale, language.locale)
                .background {
                    StatusItemBootstrapView(appDelegate: appDelegate)
                }
        }
        .defaultSize(width: 820, height: 640)

        Settings {
            SettingsView(store: store, updateService: updateService)
                .environment(\.locale, language.locale)
        }
    }
}

private struct StatusItemBootstrapView: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                appDelegate.setOpenMainWindowHandler {
                    openWindow(id: "main")
                }
            }
    }
}
