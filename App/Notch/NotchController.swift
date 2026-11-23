import AppKit
import NotchedCore
import Observation
import SwiftUI

/// What a run of the shell may touch. Production uses the defaults; a scripted test run turns
/// them off so it never reacts to the user's mouse or takes their keyboard.
struct ShellOptions {
    /// Mouse monitors, screen-change and wake observers.
    var followsRealInput = true
    var mayTakeKeyFocus = true
    /// Whether clicking an agent row may bring another app to the front.
    var mayActivateApps = true
    /// Where agent hooks write. A test run points it at its own directory.
    var agentInbox = AgentInboxPath.directory(environment: ProcessInfo.processInfo.environment,
                                              home: FileManager.default.homeDirectoryForCurrentUser)
}

/// The shell. Holds the one `NotchState`, turns every input into a `NotchEvent`, and after each
/// change matches the AppKit world to the state's projections. It makes no decisions: an `if`
/// about timer or opening behaviour belongs in `NotchState.reduce`, not here.
///
/// Inputs → `send`:
///   global + local mouse monitors          → .pointerMoved / .pointerDown
///   panel resignKey                        → .keyFocusLost
///   panel key presses while editing        → .key
///   didChangeScreenParameters              → .screensChanged
///   NSWorkspace.didWake, DeadlineAlarm     → .tick
///   AgentInbox (files, agent exits, wake)  → .agents
///   views                                  → everything else
///
/// Outputs ← `reconcile` (each one does nothing when AppKit already matches):
///   geometry.canvas  → panel frame
///   capturesPointer  → panel.ignoresMouseEvents
///   wantsKeyFocus    → panel key status
///   nextDeadline     → alarm
///   agents.focusRequest → Focuser
///   layout           → SwiftUI, which observes `state` directly
@MainActor
@Observable
final class NotchController {
    /// The only stored copy. Views read it; only `send` writes it.
    private(set) var state: NotchState

    @ObservationIgnored let options: ShellOptions
    @ObservationIgnored private(set) var panel: NotchPanel?
    @ObservationIgnored private let alarm = DeadlineAlarm()
    @ObservationIgnored let focuser: Focuser
    @ObservationIgnored private(set) var inbox: AgentInbox?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var observers: [(NotificationCenter, any NSObjectProtocol)] = []

    init(geometry: NotchGeometry, options: ShellOptions = ShellOptions()) {
        state = NotchState(geometry: geometry, now: .now)
        self.options = options
        focuser = Focuser(mayActivate: options.mayActivateApps)
    }

    /// Creates and shows the panel, installs monitors and observers, and reconciles once.
    func start() {
        guard panel == nil else { return }
        let panel = NotchPanel(
            frame: state.geometry.canvas,
            content: NotchView(controller: self),
            mayBecomeKey: { [weak self] in
                guard let self else { return false }
                return self.options.mayTakeKeyFocus && self.state.wantsKeyFocus
            },
            onKey: { [weak self] key in self?.send(.key(key)) },
            onResignKey: { [weak self] in self?.send(.keyFocusLost) }
        )
        self.panel = panel
        panel.orderFrontRegardless()
        if options.followsRealInput {
            installMonitors()
            installObservers()
        }
        reconcile(from: nil)
        let inbox = AgentInbox(directory: options.agentInbox) { [weak self] in self?.send(.agents($0)) }
        self.inbox = inbox
        inbox.start()
    }

    /// The single entry point for change. Reads the clock once per event, and assigns only on a
    /// change, so 120 Hz mouse moves that do not cross the shape's edge never touch SwiftUI.
    func send(_ event: NotchEvent) {
        var next = state
        next.reduce(event, at: .now)
        guard next != state else { return }
        let old = state
        state = next
        reconcile(from: old)
    }

    private func reconcile(from old: NotchState?) {
        guard let panel else { return }
        if panel.frame != state.geometry.canvas {
            panel.setFrame(state.geometry.canvas, display: true)
        }
        if panel.ignoresMouseEvents == state.capturesPointer {
            panel.ignoresMouseEvents = !state.capturesPointer
        }
        if state.wantsKeyFocus, options.mayTakeKeyFocus, !panel.isKeyWindow {
            panel.makeKey()
        } else if !state.wantsKeyFocus, panel.isKeyWindow {
            // Apple advises against calling resignKey() directly. Ordering the panel out and back,
            // while it may no longer become key, hands the keyboard back to the app that had it.
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        alarm.arm(at: state.nextDeadline) { [weak self] in self?.send(.tick) }
        focuser.reflect(state.agents.focusRequest)

        // The shape changed under a cursor that may not have moved: Esc or Return can shrink it out
        // from under the pointer. Re-sample, or the canvas keeps taking clicks until the next move.
        if options.followsRealInput, let old, old.layout != state.layout {
            send(.pointerMoved(NSEvent.mouseLocation, dragging: NSEvent.pressedMouseButtons != 0))
        }
    }

    private func installMonitors() {
        // Global monitors see events routed to other apps (our panel ignoring the mouse, or the
        // pointer elsewhere); local monitors see events routed to us. Both report
        // `NSEvent.mouseLocation`, so the domain sees one stream. No Accessibility permission needed.
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        let downs: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let handle: @MainActor (NSEvent) -> Void = { [weak self] event in
            let location = NSEvent.mouseLocation
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                self?.send(.pointerDown(location))
            } else {
                self?.send(.pointerMoved(location, dragging: event.type != .mouseMoved))
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves.union(downs), handler: { event in
            MainActor.assumeIsolated { handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves.union(downs), handler: { event in
            MainActor.assumeIsolated { handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func installObservers() {
        let app = NotificationCenter.default
        observers.append((app, app.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let geometry = NotchGeometry.current() { self?.send(.screensChanged(geometry)) }
            }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.send(.tick)
                self?.inbox?.scan()
            }
        }))
    }
}

/// Keeps at most one pending wake-up. Re-arming at the same instant does nothing; a new instant
/// replaces the old one. An early or redundant fire costs one `.tick`, which the reducer absorbs.
@MainActor
final class DeadlineAlarm {
    private var armed: (at: Instant, task: Task<Void, Never>)?

    func arm(at instant: Instant?, fire: @escaping @MainActor () -> Void) {
        guard instant != armed?.at else { return }
        armed?.task.cancel()
        armed = nil
        guard let instant else { return }
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(until: instant, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.armed = nil
            fire()
        }
        armed = (instant, task)
    }
}

extension NotchGeometry {
    /// Reads NSScreen into the domain value. Prefers the built-in notched display even when it is
    /// not the main screen, and falls back to a pill on the main screen. Nil only with no screens.
    static func current() -> NotchGeometry? {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? screens.first else {
            return nil
        }
        return NotchGeometry(screenFrame: screen.frame, topInset: screen.safeAreaInsets.top,
                             auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
                             auxiliaryTopRight: screen.auxiliaryTopRightArea)
    }
}
