import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel
    @State private var exporting = false
    @State private var renaming = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolStrip
                    ZStack {
                        Rectangle().fill(Color(nsColor: .underPageBackgroundColor))
                        if model.isReady {
                            PreviewCanvas(model: model).padding(28)
                        } else {
                            ProgressView("正在载入…").controlSize(.large)
                        }
                    }
                }
                Divider()
                InspectorView(model: model)
            }
            Divider()
            EditorTimeline(model: model).frame(height: 300)
        }
        .toolbar { toolbar }
        .navigationTitle(model.meta.name)
        .navigationSubtitle("\(model.meta.segments.count) 段 · \(formatDuration(model.duration))")
        .background(shortcuts)
        .sheet(isPresented: $exporting) { ExportSheet(model: model) }
        .sheet(isPresented: $renaming) {
            RenameField(name: model.meta.name) { model.renameProject($0) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { renaming = true } label: { Label("重命名", systemImage: "pencil") }
            Button(action: model.undo) { Label("撤销", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
            Button(action: model.redo) { Label("重做", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
            Button {
                model.player.pause()
                exporting = true
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(BrandButtonStyle())
            .disabled(!model.isReady)
        }
    }

    private var toolStrip: some View {
        HStack(spacing: 4) {
            ForEach(CanvasTool.allCases, id: \.self) { tool in
                Button {
                    model.tool = tool
                    if tool != .select { model.player.pause() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tool.symbol)
                        if model.tool == tool { Text(tool.label).font(.system(size: 11, weight: .medium)) }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .foregroundStyle(model.tool == tool ? .white : .primary)
                    .background {
                        if model.tool == tool {
                            Capsule().fill(tool == .blur ? AnyShapeStyle(Color.cyan.gradient) : AnyShapeStyle(Theme.brand))
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tool.label)
                if tool == .select || tool == .text {
                    Rectangle().fill(.separator).frame(width: 1, height: 18).padding(.horizontal, 4)
                }
            }
        }
        .padding(4)
        .glass(in: Capsule())
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .animation(.snappy(duration: 0.2), value: model.tool)
    }

    /// Invisible buttons carrying the editor's keyboard shortcuts.
    private var shortcuts: some View {
        ZStack {
            Button("", action: model.undo).keyboardShortcut("z", modifiers: .command)
            Button("", action: model.redo).keyboardShortcut("z", modifiers: [.command, .shift])
            Button("") { exporting = true }.keyboardShortcut("e", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}

private struct RenameField: View {
    @State var name: String
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名").font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).frame(width: 320)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { onSave(name); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
