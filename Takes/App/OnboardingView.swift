import SwiftUI

struct OnboardingView: View {
    var onDone: () -> Void
    private var permissions = Permissions.shared
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.brandWide.opacity(0.9)
                VStack(spacing: 12) {
                    AppGlyph(size: 76)
                    Text("欢迎使用 Takes").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                    Text("随时暂停、分段重录、点一下就框出重点").font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 20)
            }
            .frame(height: 230)

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "需要以下权限")
                PermissionRow(symbol: "rectangle.dashed.badge.record", title: "屏幕录制", detail: "录制屏幕画面（必需）",
                              state: permissions.screen, action: permissions.requestScreen)
                PermissionRow(symbol: "cursorarrow.click.2", title: "辅助功能", detail: "点击自动框选按钮、显示快捷键",
                              state: permissions.accessibility, action: permissions.requestAccessibility)
                PermissionRow(symbol: "mic", title: "麦克风", detail: "录制讲解声音",
                              state: permissions.microphone, action: permissions.requestMicrophone)
                PermissionRow(symbol: "video", title: "摄像头", detail: "画中画头像（可选）",
                              state: permissions.camera, action: permissions.requestCamera)

                if permissions.screen != .granted {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                        Text("在系统设置中打开屏幕录制权限后，可能需要重新启动 Takes。")
                        Spacer()
                        Button("重新启动") { relaunch() }.controlSize(.small)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }
            .padding(24)

            Spacer(minLength: 0)

            HStack {
                Text("所有录制只保存在本机").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onDone) {
                    Text(permissions.canRecord ? "开始使用" : "稍后设置")
                }
                .buttonStyle(BrandButtonStyle(large: true))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
        }
        .frame(width: 620, height: 640)
        .ignoresSafeArea()
        .onReceive(timer) { _ in permissions.refresh() }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

private struct PermissionRow: View {
    var symbol: String
    var title: String
    var detail: String
    var state: Permissions.State
    var action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.coral)
                .frame(width: 38, height: 38)
                .background(Theme.coral.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Button("授权", action: action).controlSize(.regular)
            }
        }
        .padding(12)
        .card(radius: 12)
    }
}

/// The app's mark: a gradient squircle with a record dot and stacked "takes".
struct AppGlyph: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(.white.opacity(0.22))
                .frame(width: size * 0.78, height: size * 0.62)
                .offset(x: size * 0.08, y: -size * 0.1)
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(.white)
                .frame(width: size * 0.82, height: size * 0.64)
                .shadow(color: .black.opacity(0.2), radius: size * 0.06, y: size * 0.03)
                .overlay(Circle().fill(Theme.brand).frame(width: size * 0.26, height: size * 0.26))
                .offset(x: -size * 0.04, y: size * 0.06)
        }
        .frame(width: size, height: size)
    }
}
