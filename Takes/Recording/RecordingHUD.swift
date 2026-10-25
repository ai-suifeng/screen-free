import SwiftUI

struct RecordingHUDView: View {
    var session: RecordingSession
    var drawing: Bool
    var onToggleDraw: () -> Void

    var body: some View {
        let paused = session.phase == .paused
        HStack(spacing: 4) {
            HStack(spacing: 9) {
                RecordingDot(paused: paused || session.phase == .countdown)
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text(formatDuration(session.elapsed))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .frame(width: 58, alignment: .leading)
                }
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(paused ? Theme.pauseAmber : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background((paused ? Theme.pauseAmber : Color.primary).opacity(0.12), in: Capsule())
                    .frame(width: 92)
            }
            .padding(.leading, 6)
            .padding(.trailing, 6)

            Rectangle().fill(.separator).frame(width: 1, height: 20).padding(.horizontal, 2)

            if paused {
                Button(action: session.resume) { Image(systemName: "play.fill") }
                    .buttonStyle(HUDButtonStyle(tint: Theme.coral))
                    .help("继续录制 \(HotKeys.pause.display)")
            } else {
                Button(action: session.pause) { Image(systemName: "pause.fill") }
                    .buttonStyle(HUDButtonStyle())
                    .disabled(session.phase != .recording)
                    .help("暂停 \(HotKeys.pause.display)")
            }
            Button(action: session.redoTake) { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(HUDButtonStyle())
                .disabled(!(session.phase == .recording || (paused && session.takeCount > 0)))
                .help(paused ? "删除上一段 \(HotKeys.redo.display)" : "重录这一段 \(HotKeys.redo.display)")
            Button(action: onToggleDraw) { Image(systemName: drawing ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle") }
                .buttonStyle(HUDButtonStyle(tint: drawing ? Theme.violet : nil))
                .help("标注工具 \(HotKeys.draw.display)")
            Button(action: session.stop) { Image(systemName: "stop.fill") }
                .buttonStyle(HUDButtonStyle(tint: Theme.recordRed))
                .help("结束录制 \(HotKeys.record.display)")
            Menu {
                Button("放弃本次录制", role: .destructive, action: session.discard)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glass(in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .padding(20)
        .animation(.snappy, value: session.phase)
    }

    private var statusText: String {
        switch session.phase {
        case .paused: "已暂停 · \(session.takeCount) 段"
        case .countdown: "准备中"
        case .finishing: "保存中…"
        default: "第 \(session.takeCount + 1) 段"
        }
    }
}

/// Countdown over the capture area, with the previous take's last frame as a translucent guide.
struct CountdownOverlayView: View {
    var session: RecordingSession
    /// Capture rect within this overlay, top-left origin.
    var captureRect: CGRect
    var screenSize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(session.ghostImage == nil ? 0.25 : 0.15)
            if let ghost = session.ghostImage {
                Image(decorative: ghost, scale: 1)
                    .resizable()
                    .frame(width: captureRect.width, height: captureRect.height)
                    .opacity(0.38)
                    .offset(x: captureRect.minX, y: captureRect.minY)
            }
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(.black.opacity(0.35)).frame(width: 150, height: 150)
                    Circle().stroke(Theme.brandWide, lineWidth: 5).frame(width: 150, height: 150)
                    Text("\(max(session.countdownValue, 1))")
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                }
                .glass(in: Circle())
                Text(session.ghostImage == nil ? "即将开始录制" : "对齐上一段画面 · 第 \(session.takeCount + 1) 段即将开始")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
            }
            .frame(width: captureRect.width, height: captureRect.height)
            .offset(x: captureRect.minX, y: captureRect.minY)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: session.countdownValue)
        }
        .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

/// Thin dashed border around the recorded area (area mode), outside of the captured pixels.
struct AreaBorderView: View {
    var captureRect: CGRect
    var screenSize: CGSize
    var paused: Bool

    var body: some View {
        ZStack {
            if paused { PausedTint().clipped() }
            RoundedRectangle(cornerRadius: 3)
                .stroke((paused ? Theme.pauseAmber : Theme.recordRed).opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
        }
        .frame(width: captureRect.width + 6, height: captureRect.height + 6)
        .offset(x: captureRect.minX - 3, y: captureRect.minY - 3)
        .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.2), value: paused)
    }
}
