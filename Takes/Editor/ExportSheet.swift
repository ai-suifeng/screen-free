import AppKit
import SwiftUI

struct ExportSheet: View {
    var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions()
    @State private var phase: Phase = .options
    @State private var progress = 0.0
    @State private var task: Task<Void, Never>?
    @State private var copied = false
    @State private var fileName = ""
    @State private var folder = Exporter.defaultFolder()

    enum Phase: Equatable {
        case options, exporting, done(URL), failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("导出").font(.system(size: 17, weight: .bold))
                    Text("\(model.meta.name) · \(formatDuration(model.duration))")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            switch phase {
            case .options: optionsView
            case .exporting: exportingView
            case .done(let url): doneView(url)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                HStack { Spacer(); Button("关闭") { dismiss() } }
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var optionsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledContent("文件名") {
                HStack(spacing: 6) {
                    TextField(model.meta.name, text: $fileName)
                        .textFieldStyle(.roundedBorder)
                    Text(options.format == .mp4 ? ".mp4" : ".gif").foregroundStyle(.secondary)
                }
                .frame(width: 300)
            }
            .onAppear { if fileName.isEmpty { fileName = model.meta.name } }
            LabeledContent("位置") {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.coral)
                    Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(folder.path)
                    Button("更改…", action: chooseFolder)
                }
                .frame(width: 300)
            }
            HStack(spacing: 10) {
                ForEach(ExportFormat.allCases, id: \.self) { f in
                    formatCard(f)
                }
            }
            if options.format == .mp4 {
                LabeledContent("分辨率") {
                    Picker("", selection: $options.resolution) {
                        ForEach(ExportResolution.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                LabeledContent("帧率") {
                    Picker("", selection: $options.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }
            } else {
                LabeledContent("宽度") {
                    Picker("", selection: $options.gifWidth) {
                        Text("640").tag(640)
                        Text("960").tag(960)
                        Text("1280").tag(1280)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                LabeledContent("帧率") {
                    Picker("", selection: $options.gifFPS) {
                        Text("10").tag(10)
                        Text("15").tag(15)
                        Text("24").tag(24)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }
                if model.duration > 30 {
                    Label("GIF 适合 30 秒以内的短片，长视频文件会很大。", systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导出", action: start).buttonStyle(BrandButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .font(.system(size: 13))
    }

    private func formatCard(_ f: ExportFormat) -> some View {
        let selected = options.format == f
        return Button {
            options.format = f
        } label: {
            HStack(spacing: 10) {
                Image(systemName: f == .mp4 ? "film" : "photo.stack")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Theme.coral : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.label).font(.system(size: 13, weight: .semibold))
                    Text(f == .mp4 ? "高画质，含声音" : "无声，便于粘贴").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(selected ? Theme.coral.opacity(0.1) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.coral : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private var exportingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: progress)
            HStack {
                Text("正在渲染… \(Int(progress * 100))%").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    task?.cancel()
                    phase = .options
                }
            }
        }
    }

    private func doneView(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("导出完成").font(.system(size: 14, weight: .semibold))
                    Text(url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: 12)
            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                    copied = true
                } label: {
                    Label(copied ? "已拷贝" : "拷贝文件", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: { Label("在访达中显示", systemImage: "folder") }
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(BrandButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            // Remembered for next time.
            AppSettings.shared.exportFolder = url
        }
    }

    private func start() {
        let ext = options.format == .mp4 ? "mp4" : "gif"
        let url = Exporter.uniqueURL(name: Exporter.safeFileName(fileName, fallback: model.meta.name), ext: ext, in: folder)
        phase = .exporting
        progress = 0
        task = Task { @MainActor in
            do {
                try await Exporter.export(model: model, options: options, to: url) { p in progress = p }
                guard !Task.isCancelled else { return }
                model.recordExport(url)
                // Copy to the clipboard right away so it can be pasted into chats or docs.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
                copied = true
                phase = .done(url)
            } catch is CancellationError {
                phase = .options
            } catch {
                if !Task.isCancelled { phase = .failed("导出失败：\(error.localizedDescription)") }
            }
        }
    }
}
