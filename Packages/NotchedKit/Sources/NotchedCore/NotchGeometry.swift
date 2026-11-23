import CoreGraphics

/// What the notch is drawn as. Derived from state (`NotchState.layout`), never stored.
/// `CaseIterable` so the panel's canvas is computed from every case instead of a hand-kept maximum.
public enum NotchLayout: Hashable, Sendable, CaseIterable {
    /// Idle and closed: exactly the hardware notch (or the fallback pill).
    case dormant
    /// Running or paused and closed: wings either side of the notch, a ring on the left and the
    /// remaining time on the right.
    case glance
    /// Finished, not yet seen, and closed: the same wings, pulsing "Done".
    case alert
    /// Open: the full panel hanging below the notch.
    case expanded
}

/// Where the notch is and how big each layout is, in global AppKit coordinates (origin bottom-left).
/// Built once per screen configuration and replaced whole when screens change. It owns the only
/// conversion from a layout to a screen rect, so drawing and hit-testing cannot disagree.
public struct NotchGeometry: Equatable, Sendable {
    /// The screen the notch is on.
    public let screenFrame: CGRect
    /// The camera cutout, or a pill flush with the top centre when the screen has none.
    public let notch: CGRect
    public let hasHardwareNotch: Bool

    /// `hardwareNotch == nil` (an external display, a closed lid, a VM) → a pill of
    /// `Metrics.fallbackNotch` size at the top centre of `screenFrame`.
    public init(screenFrame: CGRect, hardwareNotch: CGRect?) {
        self.screenFrame = screenFrame
        if let hardwareNotch {
            notch = hardwareNotch
            hasHardwareNotch = true
        } else {
            let size = Metrics.fallbackNotch
            notch = CGRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
                           width: size.width, height: size.height)
            hasHardwareNotch = false
        }
    }

    /// From what `NSScreen` reports: the top safe-area inset is the notch's height, and the gap
    /// between the two auxiliary top areas (the menu bar either side) is its width. Without an inset
    /// or either area, the screen has no notch.
    public init(screenFrame: CGRect, topInset: CGFloat, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?) {
        var cutout: CGRect?
        if topInset > 0, let left = auxiliaryTopLeft, let right = auxiliaryTopRight, right.minX > left.maxX {
            cutout = CGRect(x: left.maxX, y: screenFrame.maxY - topInset, width: right.minX - left.maxX, height: topInset)
        }
        self.init(screenFrame: screenFrame, hardwareNotch: cutout)
    }

    /// Size of the black shape for a layout. Every layout hangs from the top edge, centred on the notch.
    public func size(for layout: NotchLayout) -> CGSize {
        switch layout {
        case .dormant: notch.size
        case .glance, .alert: CGSize(width: notch.width + 2 * Metrics.wing, height: notch.height)
        case .expanded: CGSize(width: max(notch.width + 2 * Metrics.panelWing, Metrics.panelMinWidth),
                               height: notch.height + Metrics.panelBody)
        }
    }

    /// The panel's fixed frame: the union of every layout's rect. The window never resizes when the
    /// notch opens or closes; SwiftUI animates the shape inside it, and `ignoresMouseEvents` keeps
    /// the rest of the canvas click-through.
    public var canvas: CGRect {
        NotchLayout.allCases.map(activeRect(for:)).reduce(CGRect.null) { $0.union($1) }
    }

    /// The shape's rect for a layout. One rect decides both "is the pointer on the notch" and
    /// "does the window take this click".
    public func activeRect(for layout: NotchLayout) -> CGRect {
        let s = size(for: layout)
        return CGRect(x: notch.midX - s.width / 2, y: screenFrame.maxY - s.height, width: s.width, height: s.height)
    }

    enum Metrics {
        static let fallbackNotch = CGSize(width: 180, height: 26)
        /// Fits a ring on the left and "1:02:03" on the right.
        static let wing: CGFloat = 56
        static let panelWing: CGFloat = 90
        static let panelMinWidth: CGFloat = 400
        static let panelBody: CGFloat = 104
    }
}
