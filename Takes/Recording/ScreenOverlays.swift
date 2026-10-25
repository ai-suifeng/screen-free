import AppKit
import SwiftUI

extension NSScreen {
    /// "CB27U1 · 1920×1080", in points as macOS reports the resolution.
    var summary: String {
        "\(localizedName) · \(Int(frame.width))×\(Int(frame.height))"
    }

    var isMain: Bool { displayID == CGMainDisplayID() }
}

/// Shown on every display while choosing which screen to record.
struct ScreenPickOverlayView: View {
    var setup: CaptureSetup
    let screen: NSScreen
    var onPick: () -> Void

    private var selected: Bool { setup.selectedDisplayID == screen.displayID }

    var body: some View {
        ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.brandWide, lineWidth: 5)
                    .shadow(color: Theme.coral.opacity(0.6), radius: 12)
                VStack {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.recordRed).frame(width: 9, height: 9)
                        Text("将录制这块屏幕").font(.system(size: 14, weight: .bold))
                        Text(screen.summary).font(.system(size: 12, weight: .medium)).opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Theme.brand, in: Capsule())
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    .padding(.top, 46)
                    Spacer()
                }
            } else {
                Color.black.opacity(0.35)
                Button(action: onPick) {
                    VStack(spacing: 10) {
                        Image(systemName: "display").font(.system(size: 40, weight: .light))
                        Text("录制这块屏幕").font(.system(size: 17, weight: .semibold))
                        Text(screen.summary + (screen.isMain ? " · 主屏幕" : ""))
                            .font(.system(size: 12)).opacity(0.8)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 34).padding(.vertical, 24)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .ignoresSafeArea()
        .animation(.snappy, value: selected)
    }
}

/// Outline around the display being recorded, so it's obvious which screen is live.
struct RecordingScreenBorderView: View {
    var session: RecordingSession

    var body: some View {
        let paused = session.phase == .paused
        ZStack {
            if paused { PausedTint() }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((paused ? Theme.pauseAmber : Theme.recordRed).opacity(0.9), lineWidth: 3)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: paused)
    }
}

/// Grays out what's being recorded while paused, so nobody keeps talking into a paused recording.
/// The overlay ignores the mouse, so the screen stays usable.
struct PausedTint: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill").font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.pauseAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("已暂停，没有在录制").font(.system(size: 16, weight: .bold))
                    Text("按 ⌥⌘P 或工具条上的继续按钮").font(.system(size: 12)).opacity(0.8)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.black.opacity(0.6), in: Capsule())
            .overlay(Capsule().stroke(Theme.pauseAmber.opacity(0.6)))
        }
        .transition(.opacity)
    }
}
