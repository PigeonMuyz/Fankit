import AppKit

MainActor.assumeIsolated {
  // Tests use plain AppKit content: no hardware monitoring or helper connection.
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  let coordinator = MainWindowCoordinator()
  var creations = 0
  coordinator.makeContent = {
    creations += 1
    let controller = NSViewController()
    controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 640))
    return controller
  }

  // A background launch has not created a SwiftUI scene or registered a window.
  assert(coordinator.window == nil)
  coordinator.show()
  let first = coordinator.window!
  assert(first.isVisible && creations == 1)
  coordinator.show()
  assert(coordinator.window === first && creations == 1)
  first.close()
  assert(!first.isVisible)
  coordinator.show()
  assert(first.isVisible && coordinator.window === first)
  first.miniaturize(nil)
  coordinator.show()
  assert(!first.isMiniaturized && first.isVisible)

  // If SwiftUI creates its scene later, retain just that window, not two windows.
  let scene = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
    styleMask: [.titled, .closable, .miniaturizable, .resizable],
    backing: .buffered, defer: false)
  scene.isReleasedWhenClosed = false
  coordinator.register(scene)
  assert(coordinator.window === scene && scene.isVisible && !first.isVisible)
  scene.close()
  coordinator.show()
  assert(scene.isVisible && creations == 1)
  scene.close()

  // Registration before the first request must never create fallback content.
  let registered = MainWindowCoordinator()
  registered.makeContent = { fatalError("Unexpected fallback") }
  registered.register(scene)
  registered.show()
  assert(scene.isVisible)
  scene.close()
  print("Main window lifecycle verification passed")
}
