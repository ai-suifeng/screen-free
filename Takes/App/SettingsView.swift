import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            HighlightSettings().tabItem { Label("标注", systemImage: "square.dashed") }
            PrivacySettings().tabItem { Label("隐私", systemImage: "hand.raised") }
        }
        .frame(width: 540)
    }
}

private struct GeneralSettings: View {
    @Bindable var settings = AppSettings.shared
    @Bindable var updater = Updater.shared

    var body: some View {
        Form {
            Section("存储") {
                LabeledContent("保存位置") {
                    HStack {
                        Text(settings.saveFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("更改…") { chooseFolder() }
                    }
                }
            }
            Section("录制") {
                Picker("帧率", selection: $settings.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("开始前倒计时", selection: $settings.countdown) {
                    Text("无").tag(0)
                    Text("1 秒").tag(1)
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                }
                Toggle("继续录制前显示上一段画面，帮助对齐", isOn: $settings.showGhostOnResume)
            }
            Section("更新") {
                LabeledContent("当前版本", value: Updater.currentVersion)
                Toggle("自动检查更新", isOn: $updater.automaticChecks)
                HStack {
                    Button("立即检查更新") {
                        Task { await updater.check(userInitiated: true) }
                    }
                    Button("下载页面") { NSWorkspace.shared.open(Updater.releasesPage) }
                }
            }
            Section("快捷键") {
                LabeledContent("开始 / 结束录制", value: HotKeys.record.display)
                LabeledContent("暂停 / 继续", value: HotKeys.pause.display)
                LabeledContent("重录这一段", value: HotKeys.redo.display)
                LabeledContent("标注工具", value: HotKeys.draw.display)
            }
        }
        .formStyle(.grouped)
        .frame(height: 600)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolder = url
            LibraryStore.shared.reload()
        }
    }
}

private struct HighlightSettings: View {
    @Bindable var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("按住此键再点击", selection: $settings.highlightTrigger) {
                    ForEach(HighlightTrigger.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("效果", selection: $settings.highlightKind) {
                    ForEach([Annotation.Kind.box, .spotlight, .magnify], id: \.self) { k in
                        Label(k.label, systemImage: k.symbol).tag(k)
                    }
                }
                LabeledContent("颜色") {
                    HStack(spacing: 8) {
                        ForEach(RGBA.palette, id: \.self) { c in
                            Circle().fill(c.color).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.primary, lineWidth: settings.highlightColor == c ? 2 : 0).padding(-3))
                                .onTapGesture { settings.highlightColor = c }
                        }
                    }
                }
                Toggle("自动编号步骤 ①②③", isOn: $settings.stepNumbers)
            } header: {
                Text("点击高亮")
            } footer: {
                Text("录制时按住触发键点击按钮，Takes 会通过辅助功能读取按钮的真实边界，自动画出贴合的高亮框。需要辅助功能权限。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 600)
    }
}

private struct PrivacySettings: View {
    @Bindable var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                ForEach(settings.excludedApps) { app in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 18, height: 18)
                        }
                        Text(app.name)
                        Spacer()
                        Button {
                            settings.excludedApps.removeAll { $0.id == app.id }
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                    }
                }
                Button("添加 App…", action: addApp)
            } header: {
                Text("录制时隐藏这些 App")
            } footer: {
                Text("全屏和区域录制时，这些 App 的窗口不会出现在画面里。").foregroundStyle(.secondary)
            }
            Section {
                Toggle("隐藏系统通知横幅", isOn: $settings.hideNotifications)
                Toggle("记录所有按键（用于按键显示）", isOn: $settings.recordAllKeys)
            } footer: {
                Text("默认只记录 ⌘ ⌃ ⌥ 组合键，避免把输入的密码等内容记下来。").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 600)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !settings.excludedApps.contains(where: { $0.bundleID == id }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            settings.excludedApps.append(ExcludedApp(bundleID: id, name: name))
        }
    }
}
