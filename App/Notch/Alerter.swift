import AppKit
import NotchedCore
import UserNotifications

/// Completion sound and system notification as a function of `NotchState.ringing`. `reflect`
/// converges to "sounding for run X" or "silent" however often it is called. The domain decides
/// whether to ring; this decides how.
@MainActor
final class Alerter {
    /// The run currently sounding, identified by its deadline. Read by the self-test.
    private(set) var sounding: Instant?

    private let makesNoise: Bool
    private var chime: Task<Void, Never>?
    private var askedForPermission = false
    private static let notificationID = "app.notched.timer"

    init(makesNoise: Bool) {
        self.makesNoise = makesNoise
    }

    /// `ringing == nil` stops the sound and removes the notification. A new run plays Glass up to
    /// three times and posts one notification. The same run does nothing. `starting` asks for
    /// notification permission on the first timer, so the prompt has context.
    func reflect(_ ringing: Countdown.Finished?, starting: Bool) {
        if starting { requestPermissionOnce() }
        guard ringing?.deadline != sounding else { return }
        chime?.cancel()
        chime = nil
        sounding = ringing?.deadline
        guard makesNoise else { return }
        let center = Self.notificationCenter
        if let ringing {
            chime = Task { @MainActor in
                for _ in 0..<3 where !Task.isCancelled {
                    NSSound(named: "Glass")?.play()
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
            let content = UNMutableNotificationContent()
            content.title = "Timer done"
            content.body = "\(Readout(wholeSeconds: ringing.total.seconds).text) is up."
            center?.add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
        } else {
            center?.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        }
    }

    private func requestPermissionOnce() {
        guard makesNoise, !askedForPermission, let center = Self.notificationCenter else { return }
        askedForPermission = true
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// Nil outside an app bundle (UNUserNotificationCenter traps without one). The sound and the
    /// notch's own alert still work.
    private static var notificationCenter: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }
}
