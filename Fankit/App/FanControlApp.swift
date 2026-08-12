import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var defaultsObserver: NSObjectProtocol?
    private var lastDockPreference: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateDockPreference(activate: true)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDockPreference() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func configureStatusItem(store: FanControlStore, openSettings: @escaping @MainActor () -> Void) {
        guard statusItemController == nil else { return }
        statusItemController = StatusItemController(store: store, openSettings: openSettings)
    }

    private func updateDockPreference(activate: Bool = false) {
        let shouldHide = UserDefaults.standard.bool(forKey: PreferenceKey.hideDockIcon)
        guard lastDockPreference != shouldHide || activate else { return }
        lastDockPreference = shouldHide
        ApplicationPreferences.applyDockPreference(activate: activate && !shouldHide)
    }
}

@main
struct FanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: FanControlStore
    @AppStorage(PreferenceKey.appLanguage) private var languageRaw = AppLanguage.system.rawValue

    init() {
        ApplicationPreferences.prepareDefaults()
        _store = State(initialValue: FanControlStore())
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup("Fankit", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 720, minHeight: 560)
                .environment(\.locale, language.locale)
                .background {
                    StatusItemBootstrapView {
                        appDelegate.configureStatusItem(store: store, openSettings: $0)
                        store.start()
                    }
                }
        }
        .defaultSize(width: 820, height: 640)

        Settings {
            SettingsView(store: store)
                .environment(\.locale, language.locale)
        }
    }
}

private struct StatusItemBootstrapView: View {
    @Environment(\.openSettings) private var openSettings
    let configure: (@escaping @MainActor () -> Void) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task {
                configure {
                    openSettings()
                }
            }
    }
}
