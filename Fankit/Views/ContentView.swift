import SwiftUI

private enum SidebarDestination: String, Identifiable {
    case overview
    case temperatures
    case curves
    case aiScheduling

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .temperatures: "Temperatures"
        case .curves: "Curve Editor"
        case .aiScheduling: "AI Scheduling"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .temperatures: "thermometer.medium"
        case .curves: "chart.xyaxis.line"
        case .aiScheduling: "sparkles"
        }
    }
}

struct ContentView: View {
    let store: FanControlStore
    @State private var selection: SidebarDestination? = .overview

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
            }
            .listStyle(.sidebar)
            .navigationTitle("Fankit")
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
            .navigationTitle("Temperatures")
        case .curves:
            CurveEditorView(store: store)
        case .aiScheduling:
            AISchedulingView(store: store)
        }
    }
}

private struct SidebarRow: View {
    let destination: SidebarDestination

    var body: some View {
        Label(LocalizedStringKey(destination.title), systemImage: destination.systemImage)
        .tag(destination)
    }
}

#Preview {
    ContentView(store: FanControlStore())
        .frame(width: 900, height: 720)
}
