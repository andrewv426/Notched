import AppKit
import NotchedCore

/// Brings the app an agent runs in to the front when a row is clicked. It acts once per request
/// (`request.at`), so reconciling twice does nothing. It only activates an app that is already
/// running, found by the bundle id the hook recorded; it never launches one and never opens a URL
/// or path taken from a record. No Automation permission is needed.
@MainActor
final class Focuser {
    private let mayActivate: Bool
    /// The last request acted on. A test run reads it instead of watching another app come forward.
    private(set) var lastRequest: AgentFocusRequest?

    init(mayActivate: Bool) {
        self.mayActivate = mayActivate
    }

    func reflect(_ request: AgentFocusRequest?) {
        guard let request, request.at != lastRequest?.at else { return }
        lastRequest = request
        guard mayActivate, let host = request.host,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: host).first,
              let url = app.bundleURL else { return }
        // Notched is never the active app, so NSRunningApplication.activate() may be refused;
        // LaunchServices activates a running app on our behalf.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
