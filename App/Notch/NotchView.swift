import AppKit
import NotchedCore
import SwiftUI

/// The root view. It fills the fixed canvas and draws one black shape hanging from the top edge,
/// sized by `geometry.size(for: layout)`. Opening springs the shape out first and fades the content
/// in after it; closing fades the content out first. Views read `controller.state` and call
/// `controller.send`; they hold no timer or pointer state of their own.
struct NotchView: View {
    let controller: NotchController

    var body: some View {
        let state = controller.state
        let size = state.geometry.size(for: state.layout)
        let isOpen = state.layout == .expanded
        ZStack(alignment: .top) {
            Color.black
            content(for: state)
                .id(state.layout)
                .transition(.asymmetric(
                    insertion: .blurFade.animation(.easeOut(duration: 0.28).delay(isOpen ? 0.1 : 0.06)),
                    removal: .blurFade.animation(.easeIn(duration: 0.1))))
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(NotchShape(radius: isOpen ? 26 : 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .animation(isOpen ? .spring(response: 0.42, dampingFraction: 0.74) : .spring(response: 0.3, dampingFraction: 0.95),
                   value: state.layout)
        .contextMenu {
            if state.media.nowPlaying != nil {
                Button("Stop Playback") { controller.send(.media(.stop)) }
            }
            Button("Quit Notched") { NSApp.terminate(nil) }
        }
    }

    @ViewBuilder
    private func content(for state: NotchState) -> some View {
        let notch = state.geometry.notch.size
        switch state.layout {
        case .dormant:
            Color.clear.frame(width: 0, height: 0)
        case .peek:
            if case .agentsBusy(let count) = state.wings, let tone = state.agents.tone {
                Wings(notchWidth: notch.width, height: notch.height) {
                    Spinner(color: tone.color).frame(width: 11, height: 11)
                } trailing: {
                    Text("\(count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(tone.color)
                }
                .frame(width: state.geometry.size(for: .peek).width)
            }
        case .callout:
            if case .agentAttention(let session, let others) = state.wings {
                Wings(notchWidth: notch.width, height: notch.height) {
                    PulsingGlyph(status: session.status)
                } trailing: {
                    HStack(spacing: 3) {
                        Text(session.project).lineLimit(1).truncationMode(.tail)
                        if others > 0 { Text("+\(others)").foregroundStyle(.white.opacity(0.5)).fixedSize() }
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .frame(width: state.geometry.size(for: .callout).width)
            }
        case .glance:
            let accent = (state.countdown.phase ?? state.selection).accent
            Wings(notchWidth: notch.width, height: notch.height) {
                ClockText(countdown: state.countdown) { now in
                    ProgressRing(fraction: state.countdown.fractionRemaining(at: now), accent: accent).frame(width: 15, height: 15)
                }
            } trailing: {
                ClockText(countdown: state.countdown) { now in
                    Text(state.countdown.readout(at: now).text).font(.system(size: 13, weight: .semibold).monospacedDigit())
                }
                .opacity(state.countdown.isPaused ? 0.45 : 1)
            }
            .overlay(alignment: .leading) { AgentBadge(tone: state.agentBadge) }
            .frame(width: state.geometry.size(for: .glance).width)
        case .music:
            if let playing = state.media.nowPlaying {
                Wings(notchWidth: notch.width, height: notch.height) {
                    Artwork(image: controller.artwork.image(for: playing.track.artwork), player: playing.player,
                            size: 18, corner: 4)
                } trailing: {
                    Waveform(playing: playing.isPlaying).font(.system(size: 13, weight: .semibold))
                }
                .overlay(alignment: .leading) { AgentBadge(tone: state.agentBadge) }
                .frame(width: state.geometry.size(for: .music).width)
            }
        case .alert:
            let accent = (state.countdown.phase ?? state.selection).accent
            Wings(notchWidth: notch.width, height: notch.height) {
                PulsingDot(color: accent)
            } trailing: {
                Text("Done").font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
            }
            .overlay(alignment: .leading) { AgentBadge(tone: state.agentBadge) }
            .frame(width: state.geometry.size(for: .alert).width)
        case .expanded:
            ExpandedPanel(state: state, artwork: controller.artwork, send: controller.send)
                .frame(width: state.geometry.size(for: .expanded).width, height: state.geometry.size(for: .expanded).height)
        }
    }
}

extension Phase {
    var accent: Color {
        switch self {
        case .focus: Color(red: 1, green: 0.42, blue: 0.34)
        case .rest: Color(red: 0.26, green: 0.84, blue: 0.55)
        case .custom: Color(white: 0.9)
        }
    }

    var name: String {
        switch self {
        case .focus: "Focus"
        case .rest: "Break"
        case .custom: "Custom"
        }
    }

    var doneText: String {
        switch self {
        case .focus: "Focus done"
        case .rest: "Break over"
        case .custom: "Time's up"
        }
    }
}

extension AgentStatus {
    var color: Color {
        switch self {
        case .working: Color(red: 0.5, green: 0.74, blue: 1)
        case .permission, .question: Color(red: 1, green: 0.65, blue: 0.2)
        case .done: Color(red: 0.32, green: 0.86, blue: 0.5)
        case .failed: Color(red: 1, green: 0.36, blue: 0.36)
        }
    }

    var symbol: String {
        switch self {
        case .working: "circle.dotted"
        case .permission: "hand.raised.fill"
        case .question: "questionmark"
        case .done: "checkmark"
        case .failed: "exclamationmark"
        }
    }
}

extension AgentSession {
    /// The row's second column: what the agent is doing or waiting for.
    var detail: String {
        switch status {
        case .working: toolName.map { "Working · \($0)" } ?? "Working"
        case .permission: toolName.map { "Allow \($0)?" } ?? "Needs permission"
        case .question: toolName == "ExitPlanMode" ? "Plan to review" : "Has a question"
        case .done: "Done"
        case .failed: "Failed"
        }
    }

    func elapsed(at now: Instant) -> String {
        let minutes = Int(since.duration(to: now).components.seconds / 60)
        if minutes < 1 { return "now" }
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }
}

private extension Countdown {
    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }
}

/// Opacity, blur and a small lift, for content that appears after the shape has moved.
private struct BlurFade: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content.opacity(hidden ? 0 : 1).blur(radius: hidden ? 6 : 0).offset(y: hidden ? -6 : 0)
    }
}

private extension AnyTransition {
    static var blurFade: AnyTransition { .modifier(active: BlurFade(hidden: true), identity: BlurFade(hidden: false)) }
}

/// The straight top edge is flush with the screen; the bottom corners are rounded, and the top
/// corners flare outwards a little so the shape reads as the notch growing.
struct NotchShape: Shape {
    var flare: CGFloat = 8
    var radius: CGFloat

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

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
    let accent: Color

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 2.4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 9
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(color.opacity(expanded ? 0 : 0.7))
                    .scaleEffect(expanded ? 3 : 1)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { expanded = true }
            }
    }
}

/// The open notch. A strip beside the camera names the phase; below it, the time and round
/// controls; at the bottom, the phase choices while idle, or progress while running.
private struct ExpandedPanel: View {
    let state: NotchState
    let artwork: ArtworkCache
    let send: (NotchEvent) -> Void

    private var isTyping: Bool { state.surface.mode == .editing }
    /// The phase on screen: the run's while one is going, otherwise the one Start would run.
    private var phase: Phase {
        switch state.countdown {
        case .running(let r): r.phase
        case .paused(let p): p.phase
        case .idle, .finished: state.selection
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                switch state.page {
                case .timer: modeLabel
                case .music: state.media.nowPlaying.map { PlayerLabel(player: $0.player) }
                case .agents: Label("Agents", accent: state.agents.tone?.color ?? .white.opacity(0.5), tinted: false)
                }
                Spacer(minLength: state.geometry.notch.width)
                if isTyping {
                    Text("minutes · ⏎").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                } else {
                    HStack(spacing: 4) {
                        ForEach(state.pages.filter { $0 != state.page }, id: \.self) { page in
                            pageChip(page)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(height: state.geometry.notch.height)

            switch state.page {
            case .timer: timerPage
            case .music: state.media.nowPlaying.map { MusicPage(nowPlaying: $0, volume: state.media.volume, artwork: artwork, send: send) }
            case .agents: AgentList(state: state, send: send)
            }
        }
    }

    /// A chip for each other page: the timer, music (moving while it plays), agents with a count.
    @ViewBuilder
    private func pageChip(_ page: PanelPage) -> some View {
        Button { send(.showPage(page)) } label: {
            HStack(spacing: 5) {
                switch page {
                case .timer:
                    Image(systemName: "timer")
                case .music:
                    Waveform(playing: state.media.nowPlaying?.isPlaying == true)
                case .agents:
                    let tone = state.agents.tone ?? .working
                    if state.agents.attention.isEmpty {
                        Spinner(color: tone.color).frame(width: 9, height: 9)
                    } else {
                        PulsingDot(color: tone.color, size: 6)
                    }
                    Text("\(state.agents.visible.count)").monospacedDigit()
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(page == .agents ? (state.agents.tone ?? .working).color : .white.opacity(0.75))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(page.title)
    }

    private var timerPage: some View {
        VStack(spacing: 0) {
            HStack {
                time
                Spacer()
                controls
            }
            .padding(.leading, 24)
            .padding(.trailing, 20)
            .frame(maxHeight: .infinity)

            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .frame(height: 44)
        }
    }

    @ViewBuilder
    private var modeLabel: some View {
        if case .finished(let f) = state.countdown, !isTyping {
            Label(f.phase.doneText, accent: f.phase.accent, tinted: true)
        } else {
            Label(phase.name, accent: phase.accent, tinted: false)
        }
    }

    @ViewBuilder
    private var time: some View {
        let font = Font.system(size: 50, weight: .light, design: .rounded).monospacedDigit()
        switch state.countdown {
        case .running, .paused:
            ClockText(countdown: state.countdown) { now in
                Text(state.countdown.readout(at: now).text).font(font)
            }
        case .idle, .finished:
            Group {
                if isTyping {
                    HStack(alignment: .center, spacing: 2) {
                        if state.entry.minutes > 0 { Text("\(state.entry.minutes)") }
                        Caret(color: phase.accent)
                        Text(state.entry.minutes > 0 ? ":00" : "0:00").foregroundStyle(.white.opacity(0.28))
                    }
                } else {
                    Text(Readout(wholeSeconds: state.startable?.seconds ?? 0).text)
                        .foregroundStyle(state.startable == nil ? .white.opacity(0.28) : .white)
                }
            }
            .font(font)
            .contentShape(Rectangle())
            .onTapGesture { send(.select(.custom)) }
            .help("Click and type minutes. Return starts, Esc closes.")
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 10) {
            switch state.countdown {
            case .running:
                RoundButton(symbol: "arrow.counterclockwise", help: "Reset") { send(.timer(.reset)) }
                RoundButton(symbol: "pause.fill", prominent: true, help: "Pause") { send(.timer(.pause)) }
            case .paused:
                RoundButton(symbol: "arrow.counterclockwise", help: "Reset") { send(.timer(.reset)) }
                RoundButton(symbol: "play.fill", prominent: true, help: "Resume") { send(.timer(.resume)) }
            case .idle, .finished:
                RoundButton(symbol: "play.fill", prominent: true, help: "Start") { send(.timer(.start)) }
                    .disabled(state.startable == nil)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch state.countdown {
        case .running, .paused:
            ClockText(countdown: state.countdown) { now in
                let left = state.countdown.remaining(at: now)
                HStack(spacing: 14) {
                    ProgressBar(done: 1 - state.countdown.fractionRemaining(at: now), accent: phase.accent)
                    Text(state.countdown.isPaused ? "Paused" : "ends \(Date.now.addingTimeInterval(Double(left.components.seconds)).formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.horizontal, 8)
            }
        case .idle, .finished:
            HStack(spacing: 4) {
                ForEach(Phase.choices, id: \.self) { choice in
                    Chip(title: choice.name, detail: detail(for: choice), selected: state.selection == choice) {
                        send(.select(choice))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The minutes shown beside a choice's name.
    private func detail(for choice: Phase) -> String? {
        state.duration(of: choice).map { "\($0.seconds / 60)" }
    }
}

private struct Label: View {
    let text: String
    let accent: Color
    let tinted: Bool

    init(_ text: String, accent: Color, tinted: Bool) {
        self.text = text
        self.accent = accent
        self.tinted = tinted
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text(text).foregroundStyle(tinted ? accent : .white.opacity(0.62))
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }
}

private struct Caret: View {
    let color: Color
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: 2, height: 38)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) { visible = false }
            }
    }
}

private struct ProgressBar: View {
    let done: Double
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(accent).frame(width: proxy.size.width * min(max(done, 0), 1))
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 1), value: done)
    }
}

struct RoundButton: View {
    let symbol: String
    var prominent = false
    var diameter: CGFloat = 40
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.375, weight: .semibold))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(prominent ? .white : .white.opacity(0.12)))
                .foregroundStyle(prominent ? .black : .white)
                .opacity(isEnabled ? 1 : 0.25)
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .help(help)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct Chip: View {
    let title: String
    let detail: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if let detail { Text(detail).opacity(0.55) }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(selected ? 0.13 : 0)))
            .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A turning arc: agents are working.
private struct Spinner: View {
    let color: Color
    @State private var turned = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(turned ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turned = true }
            }
    }
}

/// An agent's status glyph in a pulsing disc, for the callout wings.
private struct PulsingGlyph: View {
    let status: AgentStatus
    @State private var expanded = false

    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.black)
            .frame(width: 16, height: 16)
            .background(Circle().fill(status.color))
            .background(
                Circle()
                    .fill(status.color.opacity(expanded ? 0 : 0.6))
                    .scaleEffect(expanded ? 2.2 : 1)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { expanded = true }
            }
    }
}

/// A dot at the outer edge of the left wing: agents have something to show while the timer owns
/// the wings.
private struct AgentBadge: View {
    let tone: AgentStatus?

    var body: some View {
        if let tone {
            Circle().fill(tone.color).frame(width: 6, height: 6).padding(.leading, 12)
        }
    }
}

/// The Agents page: one row per session, most urgent first. Clicking a row brings its app forward.
private struct AgentList: View {
    let state: NotchState
    let send: (NotchEvent) -> Void

    var body: some View {
        let sessions = state.agents.visible
        if sessions.isEmpty {
            Text("No agents running")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                ScrollView(.vertical) {
                    VStack(spacing: 2) {
                        ForEach(sessions) { session in
                            AgentRow(session: session, seen: state.agents.isSeen(session), now: .now) {
                                send(.agentActivated(session.id))
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let seen: Bool
    let now: Instant
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: session.status.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(session.status.color)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(session.status.color.opacity(0.16)))
                Text(session.project)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(session.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(session.status == .working ? .white.opacity(0.5) : session.status.color)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(session.elapsed(at: now))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(seen ? 0.04 : 0.09)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help("Bring this agent's app to the front")
    }
}
