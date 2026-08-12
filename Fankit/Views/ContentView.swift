import SwiftUI

private enum SidebarDestination: String, Identifiable {
    case overview
    case temperatures
    case curves
    case aiScheduling
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .temperatures: "Temperatures"
        case .curves: "Curve Editor"
        case .aiScheduling: "AI Scheduling"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .temperatures: "thermometer.medium"
        case .curves: "chart.xyaxis.line"
        case .aiScheduling: "sparkles"
        case .settings: "gearshape"
        }
    }
}

struct ContentView: View {
    let store: FanControlStore
    let updateService: GitHubUpdateService
    @State private var selection: SidebarDestination? = .overview
    @State private var settingsSelection: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Monitoring") {
                    SidebarRow(destination: .overview)
                    SidebarRow(destination: .temperatures)
                }

                Section("Control") {
                    SidebarRow(destination: .curves)
                    SidebarRow(destination: .aiScheduling)
                }

                Section("Application") {
                    SidebarRow(
                        destination: .settings,
                        showsUpdateBadge: updateService.isUpdateAvailable
                    )
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(L10n.string("Fankit"))
        } detail: {
            detail
                .toolbar {
                    ToolbarItem {
                        Button(action: store.refresh) {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(store.isRefreshing)
                    }
                }
        }
        .onChange(of: store.aiWorkflowRequestID) { _, _ in
            selection = .aiScheduling
        }
        .onChange(of: store.settingsWorkflowRequestID) { _, _ in
            selection = .settings
        }
        .task {
            await updateService.checkForUpdatesAtLaunch()
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView(store: store)
        case .temperatures:
            ScrollView {
                TemperatureSections(store: store, compact: false)
                    .padding(24)
            }
            .navigationTitle(L10n.string("Temperatures"))
        case .curves:
            CurveEditorView(store: store, openQuietCalibration: openQuietCalibration)
        case .aiScheduling:
            AISchedulingView(store: store, openQuietCalibration: openQuietCalibration)
        case .settings:
            SettingsPageView(
                store: store,
                updateService: updateService,
                selection: $settingsSelection
            )
        }
    }

    private func openQuietCalibration() {
        settingsSelection = .quiet
        selection = .settings
    }
}

private struct SidebarRow: View {
    let destination: SidebarDestination
    var showsUpdateBadge = false

    var body: some View {
        HStack {
            Label {
                Text(verbatim: L10n.string(destination.title))
            } icon: {
                Image(systemName: destination.systemImage)
            }
            Spacer()
            if showsUpdateBadge {
                Circle()
                    .fill(.blue)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(Text(verbatim: L10n.string("Update Available")))
            }
        }
        .tag(destination)
    }
}

#Preview {
    ContentView(store: FanControlStore(), updateService: GitHubUpdateService())
        .frame(width: 900, height: 720)
}
