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
    let mainWindow = MainWindowCoordinator()

    func prepare(store: FanControlStore, updateService: GitHubUpdateService) {
        self.store = store
        mainWindow.makeContent = {
            NSHostingController(rootView: MainWindowContent(store: store, updateService: updateService))
        }
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return false
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
                self?.mainWindow.show()
            }
        )
        store.start()
        scheduleDockPreferenceUpdate()
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
        let updateService = GitHubUpdateService()
        _updateService = State(initialValue: updateService)
        appDelegate.prepare(store: store, updateService: updateService)
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .system
    }

    var body: some Scene {
        Window("Fankit", id: "main") {
            MainWindowContent(store: store, updateService: updateService)
                .background {
                    MainWindowRegistration(coordinator: appDelegate.mainWindow)
                }
        }
        .defaultSize(width: 820, height: 640)

        Settings {
            SettingsView(store: store, updateService: updateService)
                .environment(\.locale, language.locale)
        }
    }
}

private struct MainWindowContent: View {
    let store: FanControlStore
    let updateService: GitHubUpdateService
    @AppStorage(PreferenceKey.appLanguage) private var languageRaw = AppLanguage.system.rawValue

    var body: some View {
        ContentView(store: store, updateService: updateService)
            .frame(minWidth: 720, minHeight: 560)
            .environment(\.locale, (AppLanguage(rawValue: languageRaw) ?? .system).locale)
    }
}

private struct MainWindowRegistration: NSViewRepresentable {
    let coordinator: MainWindowCoordinator

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(coordinator: coordinator)
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        let coordinator: MainWindowCoordinator

        init(coordinator: MainWindowCoordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { coordinator.register(window) }
        }
    }
}
