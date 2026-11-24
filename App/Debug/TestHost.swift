#if DEBUG
import AppKit
import NotchedCore

/// How the app behaves when a script runs it for a test (`NOTCHED_SELFTEST=<output dir>`).
///
/// Every test run: no mouse monitors or screen observers (the test sends synthetic events), its own
/// agent inbox, no other app brought to the front, no real media source or volume (the test sends
/// synthetic `.nowPlaying` events), and a panel that is never restorable.
///
/// `NOTCHED_SELFTEST_MEDIA=live` runs only the live media check instead, against the real adapter
/// and a fixture player. It sends playback commands and sets the volume, so it refuses to run
/// anywhere but a virtual Mac (`Scripts/vm-selftest.sh`).
///
/// Background mode (the default; `NOTCHED_FOREGROUND=1` turns it off), so it stays out of the
/// user's way on their own Mac:
/// - the notch is a synthetic one on a screen 30 000 pt off-screen, so the panel can take the mouse
///   for a moment without ever sitting under the user's pointer;
/// - the panel is transparent, and never becomes key, so the user's keystrokes stay theirs;
/// - checks that need key focus are skipped and listed in result.txt;
/// - App Nap is held off so the deadline alarm is not throttled.
///
/// In the foreground (the Tart VM) the panel sits on the real screen, which there has no notch, and
/// may become key, so the focus checks run.
@MainActor
enum TestHost {
    private nonisolated static let environment = ProcessInfo.processInfo.environment

    nonisolated static let isActive = environment["NOTCHED_SELFTEST"] != nil
    static let isBackground = isActive && environment["NOTCHED_FOREGROUND"] != "1"
    static let selfTestOutput = environment["NOTCHED_SELFTEST"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let isLiveMedia = isActive && environment["NOTCHED_SELFTEST_MEDIA"] == "live"

    static var shellOptions: ShellOptions {
        ShellOptions(followsRealInput: false, mayTakeKeyFocus: !isBackground, mayActivateApps: false,
                     followsRealMedia: isLiveMedia && isVirtualMac,
                     agentInbox: (selfTestOutput ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                         .appendingPathComponent("agents", isDirectory: true))
    }

    /// A 14-inch MacBook Pro's screen and notch, moved far off-screen.
    static let offscreenGeometry = NotchGeometry(
        screenFrame: CGRect(x: -30_000, y: -30_000, width: 1512, height: 982),
        hardwareNotch: CGRect(x: -30_000 + 662, y: -30_000 + 950, width: 188, height: 32)
    )

    static func geometry() -> NotchGeometry {
        if isBackground { return offscreenGeometry }
        return NotchGeometry.current() ?? offscreenGeometry
    }

    /// A Tart VM reports a model such as "VirtualMac2,1".
    static var isVirtualMac: Bool {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix("VirtualMac")
    }

    private static var activity: NSObjectProtocol?
    /// How often a background run was made active (and gave focus back).
    private(set) static var focusTakenCount = 0

    static func willFinishLaunching() {
        guard isActive else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Notched test run")
    }

    static func didFinishLaunching() {
        guard isActive else { return }
        NSApp.windows.forEach(prepare)
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.windows.forEach(prepare) }
        }
        if isBackground {
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    focusTakenCount += 1
                    NSApp.deactivate()
                }
            }
        }
    }

    /// Nil when this process cannot restore or save a window.
    static func savedWindowProblem() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        let ignoresSavedState = zip(arguments, arguments.dropFirst()).contains {
            $0 == "-ApplePersistenceIgnoreState" && $1 == "YES"
        }
        if !ignoresSavedState { return "a test run must be launched with -ApplePersistenceIgnoreState YES" }
        if NSApp.windows.contains(where: \.isRestorable) { return "a test window is restorable" }
        return nil
    }

    /// Safe to call again on the same window: it only changes what is not already set.
    static func prepare(_ window: NSWindow) {
        if window.isRestorable { window.isRestorable = false }
        if isBackground, window.alphaValue != 0 { window.alphaValue = 0 }
    }
}
#endif
