import AppKit
import NotchedCore
import SwiftUI

/// The root view. It fills the fixed canvas and draws one black shape hanging from the top edge,
/// sized by `geometry.size(for: layout)`, springing between sizes when the layout changes. Views
/// read `controller.state` and call `controller.send`; they hold no timer or hover state of their
/// own. There is no `.onHover`: hover comes from the mouse monitors, so it works while the panel
/// ignores the mouse.
struct NotchView: View {
    let controller: NotchController

    var body: some View {
        let state = controller.state
        let size = state.geometry.size(for: state.layout)
        ZStack(alignment: .top) {
            NotchShape()
                .fill(.black)
                .frame(width: size.width, height: size.height)
            content(for: state)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.layout)
        .contextMenu {
            Button("Quit Notched") { NSApp.terminate(nil) }
        }
    }

    @ViewBuilder
    private func content(for state: NotchState) -> some View {
        let notch = state.geometry.notch.size
        switch state.layout {
        case .dormant:
            EmptyView()
        case .glance:
            Wings(notchWidth: notch.width, height: notch.height) {
                ClockText(countdown: state.countdown) { now in
                    ProgressRing(fraction: state.countdown.fractionRemaining(at: now)).frame(width: 14, height: 14)
                }
            } trailing: {
                ClockText(countdown: state.countdown) { now in
                    Text(state.countdown.readout(at: now).text).font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
            }
            .opacity(isPaused(state.countdown) ? 0.6 : 1)
        case .alert:
            Wings(notchWidth: notch.width, height: notch.height) {
                Image(systemName: "bell.fill").font(.system(size: 12)).symbolEffect(.wiggle, options: .repeating)
            } trailing: {
                Text("Done").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.orange)
        case .expanded:
            ExpandedPanel(state: state, send: controller.send)
                // The camera sits in the top strip; controls start below it.
                .padding(.top, notch.height)
        }
    }

    private func isPaused(_ countdown: Countdown) -> Bool {
        if case .paused = countdown { return true }
        return false
    }
}

/// The straight top edge is flush with the screen; the bottom corners are rounded, and the top
/// corners flare outwards a little so the shape reads as the notch growing.
struct NotchShape: Shape {
    var flare: CGFloat = 6
    var radius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width / 4)
        let f = min(flare, rect.width / 8)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f), control: CGPoint(x: rect.minX + f, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f + r, y: rect.maxY), control: CGPoint(x: rect.minX + f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r), control: CGPoint(x: rect.maxX - f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - f, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Content either side of the camera: `leading` left of the cutout, `trailing` right of it.
private struct Wings<Leading: View, Trailing: View>: View {
    let notchWidth: CGFloat
    let height: CGFloat
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            trailing.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 8)
        .frame(height: height)
    }
}

/// Redraws its content on each whole-second boundary of a running countdown, so the readout flips
/// exactly on the second. Paused or idle content is drawn once.
private struct ClockText<Content: View>: View {
    let countdown: Countdown
    @ViewBuilder let content: (Instant) -> Content

    var body: some View {
        if let deadline = countdown.deadline {
            TimelineView(.periodic(from: Self.boundary(before: deadline), by: 1)) { _ in
                content(.now)
            }
        } else {
            content(.now)
        }
    }

    /// A recent past date a whole number of seconds before the deadline, so the schedule's grid
    /// lines up with the moments the rounded-up readout changes: with n.f seconds left, the next
    /// change is f seconds from now.
    private static func boundary(before deadline: Instant) -> Date {
        let fraction = Double(ContinuousClock.now.duration(to: deadline).components.attoseconds) / 1e18
        return Date.now.addingTimeInterval(fraction - 1)
    }
}

private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
        }
    }
}

/// The open panel. By countdown phase:
///   idle      → the HH:MM:SS display, presets and Start
///   running   → the readout and ring, Pause and Reset
///   paused    → the readout and ring, Resume and Reset
///   finished  → Done, Restart and Dismiss
private struct ExpandedPanel: View {
    let state: NotchState
    let send: (NotchEvent) -> Void

    var body: some View {
        VStack(spacing: 12) {
            switch state.countdown {
            case .idle:
                DurationDisplay(entry: state.entry, isEditing: state.surface.mode == .editing) { send(.beginEditing) }
                HStack(spacing: 8) {
                    ForEach(TimerDuration.presets, id: \.self) { preset in
                        PillButton(title: "\(preset.seconds / 60)m") { send(.preset(preset)) }
                    }
                    PillButton(title: "Start", prominent: true) { send(.timer(.start)) }
                        .disabled(state.entry.duration == nil)
                }
            case .running, .paused:
                HStack(spacing: 14) {
                    ClockText(countdown: state.countdown) { now in
                        ProgressRing(fraction: state.countdown.fractionRemaining(at: now)).frame(width: 34, height: 34)
                    }
                    ClockText(countdown: state.countdown) { now in
                        Text(state.countdown.readout(at: now).text)
                            .font(.system(size: 40, weight: .medium).monospacedDigit())
                    }
                }
                HStack(spacing: 8) {
                    if case .running = state.countdown {
                        PillButton(title: "Pause", prominent: true) { send(.timer(.pause)) }
                    } else {
                        PillButton(title: "Resume", prominent: true) { send(.timer(.resume)) }
                    }
                    PillButton(title: "Reset") { send(.timer(.reset)) }
                }
            case .finished(let finished):
                Text("Done · \(Readout(wholeSeconds: finished.total.seconds).text)")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.orange)
                HStack(spacing: 8) {
                    PillButton(title: "Restart", prominent: true) { send(.timer(.start)) }
                    PillButton(title: "Dismiss") { send(.timer(.reset)) }
                }
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
    }
}

/// HH:MM:SS from `entry.fields`. A click starts editing; while editing, typed digits fill it from
/// the right (see `NotchPanel.sendEvent`).
private struct DurationDisplay: View {
    let entry: DurationEntry
    let isEditing: Bool
    let onTap: () -> Void

    var body: some View {
        let f = entry.fields
        Text(String(format: "%02d:%02d:%02d", f.hours, f.minutes, f.seconds))
            .font(.system(size: 34, weight: .medium).monospacedDigit())
            .foregroundStyle(entry.digits.isEmpty && !isEditing ? .white.opacity(0.45) : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(isEditing ? 0.16 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(isEditing ? 0.5 : 0), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .help("Click, then type digits. Return starts, Esc closes.")
    }
}

private struct PillButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(prominent ? .white.opacity(isEnabled ? 0.92 : 0.3) : .white.opacity(0.14)))
                .foregroundStyle(prominent ? .black : .white)
        }
        .buttonStyle(.plain)
    }
}
