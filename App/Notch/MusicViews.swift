import AppKit
import NotchedCore
import SwiftUI

extension PanelPage {
    var title: String {
        switch self {
        case .timer: "Timer"
        case .music: "Music"
        case .agents: "Agents"
        }
    }
}

/// The music page: artwork, title and transport on top; the scrubber and the Mac's volume below.
/// Stop is in the right-click menu.
struct MusicPage: View {
    let nowPlaying: NowPlaying
    let volume: OutputVolume?
    let artwork: ArtworkCache
    let send: (NotchEvent) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Artwork(image: artwork.image(for: nowPlaying.track.artwork), player: nowPlaying.player, size: 46, corner: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nowPlaying.track.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text([nowPlaying.track.artist, nowPlaying.track.album].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 8) {
                    RoundButton(symbol: "backward.fill", diameter: 34, help: "Previous") { send(.media(.previous)) }
                    RoundButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", prominent: true,
                                help: nowPlaying.isPlaying ? "Pause" : "Play") { send(.media(.togglePlayPause)) }
                    RoundButton(symbol: "forward.fill", diameter: 34, help: "Next") { send(.media(.next)) }
                }
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)

            HStack(spacing: 14) {
                if nowPlaying.canSeek {
                    Scrubber(nowPlaying: nowPlaying) { send(.media(.seek(to: $0))) }
                } else {
                    Text("Live").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    Spacer(minLength: 0)
                }
                if let volume {
                    VolumeSlider(volume: volume) { send(.media(.setVolume($0))) }
                        .frame(width: 96)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .frame(height: 44)
        }
    }
}

/// The player's icon and name, for the music page's top strip.
struct PlayerLabel: View {
    let player: Player

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: AppIcons.icon(for: player.bundleID)).resizable().frame(width: 14, height: 14)
            Text(player.name).foregroundStyle(.white.opacity(0.62))
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }
}

/// The track's artwork, or the player's icon when the player sends none.
struct Artwork: View {
    let image: NSImage?
    let player: Player
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: corner))
        } else {
            Image(nsImage: AppIcons.icon(for: player.bundleID)).resizable().frame(width: size, height: size)
        }
    }
}

/// Moves while music plays and dims while it is paused.
struct Waveform: View {
    let playing: Bool

    var body: some View {
        Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, isActive: playing)
            .opacity(playing ? 1 : 0.45)
    }
}

/// Elapsed time, a bar to click or drag, and time left. A drag is shown locally and seeks once,
/// on release, so one drag starts one adapter process.
private struct Scrubber: View {
    let nowPlaying: NowPlaying
    let seek: (Duration) -> Void
    @State private var dragged: Double?

    var body: some View {
        if nowPlaying.isPlaying, dragged == nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in bar(at: .now) }
        } else {
            bar(at: .now)
        }
    }

    private func bar(at now: Instant) -> some View {
        let duration = nowPlaying.track.duration ?? .zero
        let fraction = dragged ?? nowPlaying.fractionPlayed(at: now) ?? 0
        let elapsed = Int((duration * fraction).components.seconds)
        return HStack(spacing: 8) {
            Text(Readout(wholeSeconds: elapsed).text)
                .frame(width: 34, alignment: .trailing)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(.white.opacity(dragged == nil ? 0.85 : 1)).frame(width: proxy.size.width * fraction)
                }
                .frame(height: dragged == nil ? 4 : 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragged = min(max($0.location.x / proxy.size.width, 0), 1) }
                    .onEnded { _ in
                        if let dragged { seek(duration * dragged) }
                        dragged = nil
                    })
            }
            .frame(height: 18)
            Text("-" + Readout(wholeSeconds: Int(duration.components.seconds) - elapsed).text)
                .frame(width: 40, alignment: .leading)
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.5))
        .animation(.easeOut(duration: 0.12), value: dragged == nil)
    }
}

/// The Mac's output volume. It follows a drag continuously, as the system slider does.
private struct VolumeSlider: View {
    let volume: OutputVolume
    let set: (Double) -> Void
    @State private var dragged: Double?

    var body: some View {
        let level = dragged ?? (volume.isMuted ? 0 : volume.level)
        HStack(spacing: 7) {
            Image(systemName: level == 0 ? "speaker.slash.fill" : level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 16)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(.white.opacity(0.85)).frame(width: proxy.size.width * level)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged {
                        let value = min(max($0.location.x / proxy.size.width, 0), 1)
                        dragged = value
                        set(value)
                    }
                    .onEnded { _ in dragged = nil })
            }
            .frame(height: 18)
        }
        .help("Mac volume")
    }
}

/// App icons by bundle id, looked up once.
@MainActor
enum AppIcons {
    private static var icons: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage {
        if let icon = icons[bundleID] { return icon }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSWorkspace.shared.icon(for: .application)
        icons[bundleID] = icon
        return icon
    }
}
