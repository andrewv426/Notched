import AppKit
import NotchedCore
import SwiftUI

/// A borderless, transparent, non-activating panel over the menu bar at the notch. Its frame is the
/// fixed canvas and changes only when screens change; the visible shape animates inside it in
/// SwiftUI. Click-through is `ignoresMouseEvents` alone, set by the controller.
final class NotchPanel: NSPanel {
    private let mayBecomeKey: @MainActor () -> Bool
    private let onKey: @MainActor (EntryKey) -> Void
    private let onResignKey: @MainActor () -> Void

    init<Content: View>(frame: CGRect, content: Content,
                        mayBecomeKey: @escaping @MainActor () -> Bool,
                        onKey: @escaping @MainActor (EntryKey) -> Void,
                        onResignKey: @escaping @MainActor () -> Void) {
        self.mayBecomeKey = mayBecomeKey
        self.onKey = onKey
        self.onResignKey = onResignKey
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // Above the menu bar (.mainMenu), so the shape draws over it next to the notch.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isRestorable = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        becomesKeyOnlyIfNeeded = false
        let host = ClickThroughHostingView(rootView: content)
        // SwiftUI must never resize the window: the canvas is fixed.
        host.sizingOptions = []
        contentView = host
    }

    /// Key only while the user is typing a duration, so hovering never takes keystrokes from the
    /// app in front. Non-activating, so that app stays in front either way.
    override var canBecomeKey: Bool { mayBecomeKey() }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey()
    }

    /// Key presses go straight to the domain while editing. The display is not a text field, so
    /// there is no SwiftUI focus to manage and the mapping is the same in tests and in use.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let key = EntryKey(event) {
            onKey(key)
            return
        }
        super.sendEvent(event)
    }
}

/// Takes the first click even though the panel is not key, so buttons work on hover without
/// a click to focus the panel first.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension EntryKey {
    /// Boundary parse of a key press. Shortcuts with ⌘, ⌃ or ⌥ are not entry keys.
    init?(_ event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
        switch event.keyCode {
        case 53: self = .cancel                 // Esc
        case 36, 76: self = .submit             // Return, keypad Enter
        case 51, 117: self = .backspace         // Delete, forward delete
        default:
            guard let character = event.charactersIgnoringModifiers?.first, let digit = Digit(character) else {
                return nil
            }
            self = .digit(digit)
        }
    }
}
