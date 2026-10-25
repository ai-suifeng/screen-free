import AVFoundation
import ScreenCaptureKit
import SwiftUI

struct CaptureBarView: View {
    @Bindable var setup: CaptureSetup
    @Bindable var settings = AppSettings.shared
    var onPickWindow: () -> Void
    var onPickArea: () -> Void
    var onStart: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(HUDButtonStyle(size: 28))
                .help("关闭 (esc)")

            divider

            HStack(spacing: 2) {
                modeButton(.display)
                modeButton(.window)
                modeButton(.area)
            }

            targetChip

            divider

            micMenu
            toggleButton(on: settings.recordSystemAudio, symbol: settings.recordSystemAudio ? "speaker.wave.2.fill" : "speaker.slash",
                         help: settings.recordSystemAudio ? "录制系统声音（点击关闭）" : "不录系统声音（点击开启）") { settings.recordSystemAudio.toggle() }
            cameraMenu

            divider

            Button(action: onStart) {
                HStack(spacing: 7) {
                    Circle().fill(.white).frame(width: 9, height: 9)
                    Text("开始录制")
                }
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(setup.target == nil)
            .opacity(setup.target == nil ? 0.5 : 1)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glass(in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .fixedSize()
        // Fixed canvas so the panel never resizes (and drifts) as its content changes.
        .frame(width: 1240, height: 120)
    }

    private var divider: some View {
        Rectangle().fill(.separator).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    private func modeButton(_ kind: CaptureKind) -> some View {
        Button {
            withAnimation(.snappy) { setup.mode = kind }
            if kind == .window { onPickWindow() }
            if kind == .area { onPickArea() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: kind.symbol)
                Text(kind.label).fixedSize()
            }
            .foregroundStyle(setup.mode == kind ? Color.primary : Color.secondary)
        }
        .buttonStyle(ChipButtonStyle(selected: setup.mode == kind))
    }

    @ViewBuilder
    private var targetChip: some View {
        switch setup.mode {
        case .display:
            Menu {
                Picker("录制哪块屏幕", selection: $setup.selectedDisplayID) {
                    ForEach(setup.displays, id: \.displayID) { d in
                        let screen = NSScreen.screen(for: d.displayID)
                        Text((screen?.summary ?? "屏幕 \(d.displayID)") + (screen?.isMain == true ? " · 主屏幕" : ""))
                            .tag(Optional(d.displayID))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                chipLabel(symbol: "display", text: displayText, warning: false)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("选择要录制的屏幕，选中的屏幕会被高亮框出")
        case .window:
            Button(action: onPickWindow) { chipLabel(symbol: "macwindow", text: setup.targetSummary, warning: false) }
                .buttonStyle(.plain)
        case .area:
            Button(action: onPickArea) { chipLabel(symbol: "rectangle.dashed", text: setup.targetSummary, warning: false) }
                .buttonStyle(.plain)
        }
    }

    private var displayText: String {
        guard let id = setup.selectedDisplayID, let screen = NSScreen.screen(for: id) else { return "选择屏幕" }
        return screen.summary
    }

    /// Capsule label: icon, current choice, chevron.
    private func chipLabel(symbol: String, text: String, warning: Bool, dimmed: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            if warning {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 11))
            }
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
        }
        .foregroundStyle(dimmed ? Color.secondary : Color.primary)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .contentShape(Capsule())
    }

    private var micSelection: Binding<String?> {
        Binding(
            get: { settings.recordMic ? (settings.micDeviceID ?? AVCaptureDevice.default(for: .audio)?.uniqueID) : nil },
            set: { id in
                settings.recordMic = id != nil
                if let id {
                    settings.micDeviceID = id
                    Permissions.shared.requestMicrophone()
                }
            })
    }

    private var micName: String {
        guard let id = micSelection.wrappedValue else { return "不录麦克风" }
        return setup.microphones.first { $0.uniqueID == id }?.localizedName ?? "麦克风"
    }

    private var micMenu: some View {
        let needsPermission = settings.recordMic && Permissions.shared.microphone != .granted
        return Menu {
            if needsPermission {
                Button("⚠️ 未授权麦克风，点击授权…") { Permissions.shared.requestMicrophone() }
                Divider()
            }
            Picker("麦克风", selection: micSelection) {
                Text("不录麦克风").tag(String?.none)
                ForEach(setup.microphones) { mic in
                    Text(mic.localizedName).tag(Optional(mic.uniqueID))
                }
            }
            .pickerStyle(.inline)
        } label: {
            chipLabel(symbol: settings.recordMic ? "mic.fill" : "mic.slash", text: micName,
                      warning: needsPermission, dimmed: !settings.recordMic)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(needsPermission ? "麦克风未授权，录制时不会有声音" : "选择麦克风")
    }

    private var cameraSelection: Binding<String?> {
        Binding(
            get: { settings.recordCamera ? (settings.cameraDeviceID ?? setup.cameras.first?.uniqueID) : nil },
            set: { id in
                settings.recordCamera = id != nil
                if let id {
                    settings.cameraDeviceID = id
                    Permissions.shared.requestCamera()
                }
            })
    }

    private var cameraMenu: some View {
        let needsPermission = settings.recordCamera && Permissions.shared.camera != .granted
        return Menu {
            if needsPermission {
                Button("⚠️ 未授权摄像头，点击授权…") { Permissions.shared.requestCamera() }
                Divider()
            }
            Picker("摄像头", selection: cameraSelection) {
                Text("不录摄像头").tag(String?.none)
                ForEach(setup.cameras) { cam in
                    Text(cam.localizedName).tag(Optional(cam.uniqueID))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: settings.recordCamera ? "video.fill" : "video.slash")
                if needsPermission {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 10))
                }
            }
            .foregroundStyle(settings.recordCamera ? Color.primary : .secondary)
            .frame(height: 32)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("摄像头画中画")
    }

    private func toggleButton(on: Bool, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(on ? Color.primary : .secondary)
        }
        .buttonStyle(HUDButtonStyle())
        .help(help)
    }
}

struct WindowPickerView: View {
    @Bindable var setup: CaptureSetup
    var onPick: (SCWindow) -> Void
    var onCancel: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 220), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择要录制的窗口").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark") }.buttonStyle(HUDButtonStyle(size: 26))
            }
            if setup.windows.isEmpty {
                ContentUnavailableView("没有可录制的窗口", systemImage: "macwindow.badge.plus")
                    .frame(height: 200)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(setup.windows, id: \.windowID) { w in
                            WindowTile(window: w, image: setup.windowThumbnails[w.windowID],
                                       selected: setup.selectedWindow?.windowID == w.windowID) {
                                onPick(w)
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: 440)
            }
        }
        .padding(18)
        .frame(width: 720)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
        .padding(30)
        .task { await setup.loadThumbnails() }
    }
}

private struct WindowTile: View {
    let window: SCWindow
    let image: NSImage?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.18))
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(6)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 118)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.coral : (hovering ? Color.primary.opacity(0.35) : .clear), lineWidth: 2))
                HStack(spacing: 6) {
                    if let app = window.owningApplication,
                       let icon = NSRunningApplication(processIdentifier: app.processID)?.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(window.owningApplication?.applicationName ?? "").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(window.title ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.spring(response: 0.3), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Drag-to-select overlay shown on one screen.
struct AreaSelectorView: View {
    let screenSize: CGSize
    var initial: CGRect?
    var onSelect: (CGRect) -> Void
    var onCancel: () -> Void

    @State private var rect: CGRect?
    @State private var dragStart: CGPoint?
    @State private var hover: CGPoint = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dim everything except the selection.
            Path { p in
                p.addRect(CGRect(origin: .zero, size: screenSize))
                if let rect { p.addRect(rect) }
            }
            .fill(.black.opacity(0.45), style: FillStyle(eoFill: true))

            if let rect {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(.white).frame(width: 9, height: 9)
                        .shadow(radius: 2)
                        .offset(x: (i % 2 == 0 ? rect.minX : rect.maxX) - 4.5, y: (i < 2 ? rect.minY : rect.maxY) - 4.5)
                }
                Text("\(Int(rect.width)) × \(Int(rect.height))")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: Capsule())
                    .offset(x: rect.minX, y: max(4, rect.minY - 30))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed").font(.system(size: 34, weight: .light))
                    Text("拖拽选择录制区域").font(.system(size: 16, weight: .semibold))
                    Text("按 esc 取消").font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .padding(22)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                .frame(width: screenSize.width, height: screenSize.height)
                .allowsHitTesting(false)
            }

            // Crosshair guides.
            if dragStart == nil {
                Path { p in
                    p.move(to: CGPoint(x: hover.x, y: 0)); p.addLine(to: CGPoint(x: hover.x, y: screenSize.height))
                    p.move(to: CGPoint(x: 0, y: hover.y)); p.addLine(to: CGPoint(x: screenSize.width, y: hover.y))
                }
                .stroke(.white.opacity(0.35), lineWidth: 0.5)
                .allowsHitTesting(false)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase { hover = p }
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if dragStart == nil { dragStart = v.startLocation }
                    let s = dragStart!
                    rect = CGRect(x: min(s.x, v.location.x), y: min(s.y, v.location.y),
                                  width: abs(v.location.x - s.x), height: abs(v.location.y - s.y))
                }
                .onEnded { _ in
                    dragStart = nil
                    if let r = rect, r.width > 40, r.height > 40 {
                        onSelect(r.integral)
                    } else {
                        rect = nil
                    }
                }
        )
        .onExitCommand(perform: onCancel)
        .onAppear { rect = initial }
    }
}
