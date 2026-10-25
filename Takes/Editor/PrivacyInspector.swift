import SwiftUI

struct PrivacyInspector: View {
    @Bindable var model: EditorModel
    @State private var scanning = false
    @State private var progress = 0.0
    @State private var findings: [SensitiveDetector.Finding]?
    @State private var tracking: UUID?
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        InspectorSection(title: "自动检测") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 36, height: 36)
                        .background(Theme.coral.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("扫描敏感信息").font(.system(size: 12, weight: .semibold))
                        Text("邮箱、手机号、身份证、银行卡、密钥、IP").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if scanning {
                    ProgressView(value: progress).controlSize(.small)
                    HStack {
                        Text("正在识别画面文字… \(Int(progress * 100))%").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消") { scanTask?.cancel(); scanning = false }.controlSize(.small)
                    }
                } else {
                    Button {
                        scan()
                    } label: {
                        Label("开始扫描", systemImage: "sparkle.magnifyingglass").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrandButtonStyle())
                }
                Text("全部在本机完成，不会上传任何内容。").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .card(radius: 12)
        }

        if let findings {
            InspectorSection(title: findings.isEmpty ? "没有发现敏感信息" : "发现 \(findings.count) 处") {
                ForEach(findings.indices, id: \.self) { i in
                    let f = findings[i]
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(get: { self.findings?[i].selected ?? false },
                                                 set: { self.findings?[i].selected = $0 }))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                        Image(systemName: f.kind.symbol).foregroundStyle(Theme.coral).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.kind.label).font(.system(size: 11, weight: .semibold))
                            Text(f.masked).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(formatDuration(f.start)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.seek(source: f.start + 0.3) }
                }
                if !findings.isEmpty {
                    Button {
                        applyFindings()
                    } label: {
                        Label("为选中的 \(findings.filter(\.selected).count) 处打码", systemImage: "eye.slash.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(!findings.contains(where: \.selected))
                }
            }
        }

        if case .blur(let id) = model.selection, let i = model.edit.blurs.firstIndex(where: { $0.id == id }) {
            InspectorSection(title: "选中的打码") {
                Picker("", selection: $model.edit.blurs[i].style) {
                    ForEach(BlurRegion.Style.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LabeledSlider(title: "时长", value: $model.edit.blurs[i].duration, range: 0.3...max(30, model.edit.blurs[i].duration),
                              format: { String(format: "%.1f 秒", $0) })
                if tracking == id {
                    ProgressView(value: progress) { Text("正在跟踪…").font(.system(size: 11)) }.controlSize(.small)
                } else {
                    HStack {
                        Button {
                            track(id)
                        } label: {
                            Label(model.edit.blurs[i].keyframes.count > 1 ? "重新跟踪" : "跟随移动", systemImage: "scope")
                        }
                        if model.edit.blurs[i].keyframes.count > 1 {
                            Button("取消跟踪") { model.edit.blurs[i].keyframes = [] }
                        }
                    }
                    .controlSize(.small)
                    Text("内容滚动或窗口移动时，打码区域会自动跟着走。").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                deleteButton("删除打码") { model.deleteSelection() }
            }
        } else {
            InspectorSection(title: "手动打码") {
                Text("在预览上方选择「打码」工具，然后在画面上框选。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }

        InspectorSection(title: "全部 \(model.edit.blurs.count) 处") {
            ForEach(model.edit.blurs.sorted { $0.start < $1.start }) { b in
                ItemRow(symbol: b.keyframes.count > 1 ? "scope" : "eye.slash", title: b.label.isEmpty ? b.style.label : b.label,
                        time: b.start, selected: model.selection == .blur(b.id), tint: .cyan) {
                    model.select(.blur(b.id))
                    model.seek(source: b.start + min(0.4, b.duration / 2))
                }
            }
        }
    }

    private func scan() {
        scanning = true
        progress = 0
        findings = nil
        model.player.pause()
        scanTask = Task { @MainActor in
            let result = await SensitiveDetector.scan(model: model) { p in progress = p }
            if !Task.isCancelled { findings = result }
            scanning = false
        }
    }

    private func applyFindings() {
        guard let findings else { return }
        for f in findings where f.selected {
            var b = BlurRegion(start: f.start, duration: f.end - f.start, rect: f.rect, style: .mosaic)
            b.label = f.kind.label
            model.edit.blurs.append(b)
        }
        self.findings = nil
    }

    private func track(_ id: UUID) {
        guard let region = model.edit.blurs.first(where: { $0.id == id }) else { return }
        tracking = id
        progress = 0
        model.player.pause()
        Task { @MainActor in
            if let frames = await BlurTracker.track(region, model: model, progress: { p in progress = p }),
               let i = model.edit.blurs.firstIndex(where: { $0.id == id }) {
                model.edit.blurs[i].keyframes = frames
            }
            tracking = nil
        }
    }
}
