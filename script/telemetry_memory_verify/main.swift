import AppKit
import SwiftUI
import Darwin

// Compile with TelemetryPlot.swift. Exercises the actual renderer without SMC/helper access.
@MainActor
func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return info.phys_footprint
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    func plot(_ tick: Int) -> TelemetryPlot {
        TelemetryPlot(series: (0..<3).map { channel in
            .init(points: (0..<20).map { offset in
                .init(time: Double(tick + offset),
                      value: 50 + 20 * sin(Double(tick + offset + channel) / 7))
            }, color: [.orange, .blue, .teal][channel])
        }, domain: 0...100)
    }
    let host = NSHostingView(rootView: plot(0))
    window.contentView = host
    window.orderFrontRegardless()
    var baseline: UInt64 = 0
    for tick in 0...6000 {
        autoreleasepool {
            host.rootView = plot(tick)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
        }
        if tick % 1000 == 0 {
            let bytes = footprint()
            print("refreshes=\(tick) footprintMiB=\(bytes / 1_048_576)")
            fflush(stdout)
            if tick == 1000 { baseline = bytes }
            if tick == 6000 {
                precondition(bytes < baseline + 32 * 1_048_576, "Renderer memory grew by more than 32 MiB after warmup")
            }
        }
    }
    for _ in 0..<200 {
        weak var releasedHost: NSHostingView<TelemetryPlot>?
        autoreleasepool {
            let temporary = NSHostingView(rootView: plot(0))
            releasedHost = temporary
            window.contentView = temporary
            window.contentView = nil
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
        precondition(releasedHost == nil, "Closed content was retained")
    }
    window.close()
    print("Telemetry renderer memory verification passed")
}
