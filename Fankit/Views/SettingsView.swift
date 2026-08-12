import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case menuBar
    case quiet
    case updates
    case safety

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .quiet: "Quiet"
        case .updates: "Updates"
        case .safety: "Safety"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .menuBar: "menubar.rectangle"
        case .quiet: "speaker.slash.fill"
        case .updates: "arrow.triangle.2.circlepath"
        case .safety: "checkmark.shield"
        }
    }
}

struct SettingsView: View {
    let store: FanControlStore
    let updateService: GitHubUpdateService
    @State private var selection: SettingsTab = .general

    var body: some View {
        SettingsTabs(
            store: store,
            updateService: updateService,
            selection: $selection
        )
        .frame(width: 620, height: 500)
        .scenePadding()
    }
}

struct SettingsPageView: View {
    let store: FanControlStore
    let updateService: GitHubUpdateService
    @Binding var selection: SettingsTab

    var body: some View {
        SettingsTabs(
            store: store,
            updateService: updateService,
            selection: $selection
        )
        .padding(24)
        .navigationTitle(L10n.string("Settings"))
    }
}

private struct SettingsTabs: View {
    let store: FanControlStore
    let updateService: GitHubUpdateService
    @Binding var selection: SettingsTab

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsView()
                .tabItem { tabLabel(.general) }
                .tag(SettingsTab.general)

            MenuBarSettingsView(store: store)
                .tabItem { tabLabel(.menuBar) }
                .tag(SettingsTab.menuBar)

            QuietCalibrationSettingsView(store: store)
                .tabItem { tabLabel(.quiet) }
                .tag(SettingsTab.quiet)

            UpdateSettingsView(updateService: updateService)
                .tabItem { tabLabel(.updates) }
                .tag(SettingsTab.updates)

            SafetySettingsView(store: store)
                .tabItem { tabLabel(.safety) }
                .tag(SettingsTab.safety)
        }
    }

    private func tabLabel(_ tab: SettingsTab) -> some View {
        Label {
            Text(verbatim: L10n.string(tab.title))
        } icon: {
            Image(systemName: tab.systemImage)
        }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(PreferenceKey.hideDockIcon) private var hideDockIcon = false
    @AppStorage(PreferenceKey.appLanguage) private var languageRaw = AppLanguage.system.rawValue
    @AppStorage("refreshInterval") private var refreshInterval = 2.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchMessage: String?

    private var language: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: languageRaw) ?? .system },
            set: { languageRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Fankit at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: updateLaunchAtLogin
                ))
                Toggle("Hide Fankit in the Dock", isOn: $hideDockIcon)
                Text("The menu bar item remains available when the Dock icon is hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let launchMessage {
                    Label(launchMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Language") {
                Picker("Application language", selection: language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Text("The selected language is applied throughout Fankit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Monitoring") {
                Picker("Update interval", selection: $refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            launchMessage = nil
        } catch {
            NSLog("Fankit login item error: %@", error.localizedDescription)
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchMessage = L10n.string("Unable to change the login item setting.")
        }
    }
}

private struct MenuBarSettingsView: View {
    let store: FanControlStore

    @AppStorage(PreferenceKey.menuBarShowCPU) private var showCPU = true
    @AppStorage(PreferenceKey.menuBarShowGPU) private var showGPU = true
    @AppStorage(PreferenceKey.menuBarShowFanSpeed) private var showFanSpeed = true
    @AppStorage("menuBarIconStyle") private var iconStyleRaw = MenuBarIconStyle.thermometer.rawValue
    @AppStorage("menuBarCustomSymbol") private var customSymbol = "thermometer.medium"

    private var iconStyle: Binding<MenuBarIconStyle> {
        Binding(
            get: { MenuBarIconStyle(rawValue: iconStyleRaw) ?? .thermometer },
            set: { iconStyleRaw = $0.rawValue }
        )
    }

    private var hasTextItem: Bool { showCPU || showGPU || showFanSpeed }

    var body: some View {
        Form {
            Section("Displayed Items") {
                Toggle("CPU temperature", isOn: $showCPU)
                Toggle("GPU temperature", isOn: $showGPU)
                Toggle("Fan speed", isOn: $showFanSpeed)
            }

            Section("Icon") {
                Picker("Menu bar icon", selection: iconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                if iconStyle.wrappedValue == .custom {
                    TextField("SF Symbol name", text: $customSymbol, prompt: Text("thermometer.medium"))
                    Label(
                        "Use an SF Symbols name, for example fan, cpu, or thermometer.high.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !hasTextItem && iconStyle.wrappedValue == .hidden {
                    Label(
                        "A thermometer icon will remain visible so you can reopen Fankit.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("Preview") {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    MenuBarStatusPreview(presentation: previewPresentation)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(.separator.opacity(0.55), lineWidth: 0.5)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var previewPresentation: MenuBarStatusPresentation {
        MenuBarStatusPresentation(
            cpuTemperature: store.hottestCPUTemperature,
            gpuTemperature: store.hottestGPUTemperature,
            rpm: store.fastestFanRPM,
            showCPU: showCPU,
            showGPU: showGPU,
            showFanSpeed: showFanSpeed,
            iconStyle: iconStyle.wrappedValue,
            customSymbol: customSymbol
        )
    }
}

private struct MenuBarStatusPreview: NSViewRepresentable {
    let presentation: MenuBarStatusPresentation

    func makeNSView(context: Context) -> StatusItemLabelView {
        let view = StatusItemLabelView(frame: .zero)
        view.configure(presentation)
        return view
    }

    func updateNSView(_ view: StatusItemLabelView, context: Context) {
        view.configure(presentation)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: StatusItemLabelView,
        context: Context
    ) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

private struct UpdateSettingsView: View {
    let updateService: GitHubUpdateService
    @AppStorage(PreferenceKey.automaticallyCheckForUpdates) private var automaticallyChecks = true
    @AppStorage(PreferenceKey.checkForUpdatesAtEveryLaunch) private var checksAtEveryLaunch = false

    var body: some View {
        Form {
            Section("Update Preferences") {
                LabeledContent(
                    "Current Version",
                    value: updateService.currentVersion
                )
                Toggle("Automatically check for updates", isOn: $automaticallyChecks)
                Toggle("Check for updates every time Fankit starts", isOn: $checksAtEveryLaunch)
                    .disabled(!automaticallyChecks)
                Text("Automatic checks use a 12-hour interval unless every-launch checking is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("GitHub Releases") {
                HStack {
                    if updateService.isChecking {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking for Updates…")
                            .foregroundStyle(.secondary)
                    } else if let release = updateService.latestRelease,
                              updateService.isUpdateAvailable
                    {
                        Label {
                            Text(verbatim: L10n.format("Version %@ is available.", release.version))
                        } icon: {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        .foregroundStyle(.blue)
                    } else if updateService.latestRelease != nil {
                        Label(
                            "Fankit is up to date.",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    } else {
                        Text("No update check has completed yet.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") {
                        Task { await updateService.checkForUpdates() }
                    }
                    .disabled(updateService.isChecking || updateService.isDownloading)
                }

                if let release = updateService.latestRelease,
                   updateService.isUpdateAvailable
                {
                    if let body = release.body, !body.isEmpty {
                        Text(verbatim: body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Button("View Release Notes") {
                            updateService.openReleasePage()
                        }
                        Spacer()
                        Button {
                            Task { await updateService.downloadAndOpenUpdate() }
                        } label: {
                            if updateService.isDownloading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Download and Open Update")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(updateService.isDownloading)
                    }
                }

                if let errorMessage = updateService.errorMessage {
                    Label {
                        Text(verbatim: errorMessage)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: automaticallyChecks) { _, enabled in
            guard enabled else { return }
            Task { await updateService.checkForUpdates() }
        }
    }
}

private struct SafetySettingsView: View {
    let store: FanControlStore

    var body: some View {
        Form {
            Section("Fankit") {
                LabeledContent("Saved mode", value: store.selectedMode.title)
                Label(
                    "The last successful mode is restored only after the signed control helper is ready.",
                    systemImage: "clock.arrow.circlepath"
                )
                .foregroundStyle(.secondary)
                Label(
                    "When Fankit quits, the privileged helper restores System mode. It is reapplied safely on the next launch.",
                    systemImage: "checkmark.shield"
                )
                .foregroundStyle(.secondary)
                Label(
                    "Auto Boost returns control to macOS after any sensor or helper failure.",
                    systemImage: "thermometer.and.liquid.waves"
                )
                .foregroundStyle(.secondary)
            }

            Section("Control Helper") {
                LabeledContent("Status", value: store.helperStatus.title)
                HStack {
                    Text(store.helperStatus.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(store.helperStatus.actionTitle) {
                        store.installOrApproveHelper()
                    }
                    .disabled(store.isChangingHelper || store.helperStatus == .ready)
                }
            }
        }
        .formStyle(.grouped)
    }
}
