import AppKit
import NotchedCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        TestHost.willFinishLaunching()
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let output = TestHost.selfTestOutput {
            let controller = NotchController(geometry: TestHost.geometry(), options: TestHost.shellOptions)
            self.controller = controller
            controller.start()
            TestHost.didFinishLaunching()
            Task { await SelfTest.run(controller: controller, output: output) }
            return
        }
        #endif
        // No screens at all: nothing to show. A screen arriving later re-runs nothing, which is
        // fine for a Mac that boots with no display.
        guard let geometry = NotchGeometry.current() else { return }
        let controller = NotchController(geometry: geometry)
        self.controller = controller
        controller.start()
    }
}
