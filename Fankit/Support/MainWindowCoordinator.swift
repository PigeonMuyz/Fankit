import AppKit

/// Owns the main window independently of whether SwiftUI has created its scene.
@MainActor
final class MainWindowCoordinator {
    var makeContent: (() -> NSViewController)?
    private(set) var window: NSWindow?
    private var fallbackController: NSWindowController?

    func register(_ sceneWindow: NSWindow) {
        guard sceneWindow !== window else { return }
        let wasVisible = window?.isVisible == true
        fallbackController?.close()
        fallbackController = nil
        window = sceneWindow
        if wasVisible { show() }
    }

    func show() {
        if window == nil {
            guard let makeContent else { return }
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            created.title = "Fankit"
            created.identifier = NSUserInterfaceItemIdentifier("main")
            created.isReleasedWhenClosed = false
            created.contentViewController = makeContent()
            created.contentMinSize = NSSize(width: 720, height: 560)
            created.center()
            fallbackController = NSWindowController(window: created)
            window = created
        }
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
