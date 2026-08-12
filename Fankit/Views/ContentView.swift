import SwiftUI

private enum SidebarDestination: String, Identifiable {
    case overview
    case temperatures
    case curves

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .temperatures: "Temperatures"
        case .curves: "Curve Editor"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .temperatures: "thermometer.medium"
        case .curves: "chart.xyaxis.line"
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
