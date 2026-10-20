import AppKit
import SwiftUI

struct ResultPane: View {
    @EnvironmentObject private var app: AppState

    private var result: StoredResult? { app.selectedResult }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if app.resultTab != .document, let result, !result.warnings.isEmpty {
                WarningBanner(warnings: result.warnings)
                Divider()
            }
            content
            if app.resultTab == .document {
                Divider()
                documentFooter
            } else if let result {
                Divider()
                footer(result)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("表示", selection: $app.resultTab) {
                ForEach(ResultTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)

            Spacer()

            if app.resultTab == .preview || app.resultTab == .document {
                Button {
                    app.fontSize = max(80, app.fontSize - 10)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                }
                .buttonStyle(.borderless)
                .help("文字を小さく (⌘-)")

                Text("\(Int(app.fontSize))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38)

                Button {
                    app.fontSize = min(200, app.fontSize + 10)
                } label: {
                    Image(systemName: "textformat.size.larger")
                }
                .buttonStyle(.borderless)
                .help("文字を大きく (⌘+)")
            }

            Button {
                app.copyCurrentMarkdown()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .disabled(app.copyableMarkdown.isEmpty)
            .help(app.resultTab == .document
                  ? "全ページの Markdown をクリップボードへコピー (⌘C)"
                  : "Markdown をクリップボードへコピー (⌘C)")
            .accessibilityLabel("Markdown をコピー")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if app.resultTab == .document {
            if !app.documentPreviewMarkdown.isEmpty {
                MarkdownWebView(
                    markdown: app.documentPreviewMarkdown,
                    baseDirectory: app.previewBaseDirectory,
                    zoom: app.fontSize / 100
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if app.isRunning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("最初のページが完了すると全体を表示します")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ResultEmptyView()
            }
        } else if app.isStreamingSelectedPage {
            switch app.resultTab {
            case .preview, .document:
                MarkdownWebView(
                    markdown: app.streamingMarkdown,
                    baseDirectory: app.previewBaseDirectory,
                    zoom: app.fontSize / 100
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .raw:
                StreamingRawView(text: app.streamingMarkdown)
            case .figures:
                ProgressView("生成中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let result {
            switch app.resultTab {
            case .preview, .document:
                MarkdownWebView(
                    markdown: result.markdown,
                    baseDirectory: app.previewBaseDirectory,
                    zoom: app.fontSize / 100
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .raw:
                RawEditor(
                    text: result.markdown,
                    onSave: { app.saveEditedResult($0) }
                )
                .id(result.id)
            case .figures:
                FigureGallery(figures: result.figures)
            }
        } else if app.isRunning {
            VStack(spacing: 10) {
                ProgressView()
                Text(app.isBatchRunning ? "連続スキャン中…" : "処理中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ResultEmptyView()
        }
    }

    private var documentFooter: some View {
        let document = app.selectedDocument
        let completed = document?.completedPages ?? 0
        let total = document?.pageCount ?? 0
        return HStack(spacing: 12) {
            Label("\(completed)/\(total) ページ", systemImage: "doc.text")
            Spacer()
            Text("ページ番号は原本に準拠")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func footer(_ result: StoredResult) -> some View {
        HStack(spacing: 12) {
            if result.stats.truncated == true {
                Label("出力上限に達しました", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if app.maxNewTokens < 8192 {
                    Button("上限を上げて再実行") {
                        app.maxNewTokens = min(8192, app.maxNewTokens + 1000)
                        app.runOCR()
                    }
                    .buttonStyle(.link)
                    .help("最大出力トークン数を増やして、このページを再実行します")
                }
            }
            if result.warnings.contains(where: { $0.code == "W4001" }) {
                Label("部分結果", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(result.preset.uppercased())
            if let seconds = result.stats.seconds {
                Text(String(format: "%.1f 秒", seconds))
            }
            if let tokens = result.stats.outputTokens {
                Text("\(tokens) tokens")
            }
            if let speed = result.stats.tokPerSec, speed > 0 {
                Text(String(format: "%.1f tok/s", speed))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct WarningBanner: View {
    let warnings: [WarningInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning.message)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.09))
    }
}

private struct StreamingRawView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "生成中…" : text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }
}

private struct RawEditor: View {
    @State private var draft: String
    @State private var savedText: String
    @State private var isDirty = false
    let onSave: (String) -> Void

    init(text: String, onSave: @escaping (String) -> Void) {
        _draft = State(initialValue: text)
        _savedText = State(initialValue: text)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Markdown を直接編集できます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isDirty {
                    Button("元に戻す") {
                        draft = savedText
                        isDirty = false
                    }
                    .buttonStyle(.borderless)
                }
                Button("保存") {
                    onSave(draft)
                    savedText = draft
                    isDirty = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isDirty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            TextEditor(text: Binding(
                get: { draft },
                set: {
                    draft = $0
                    isDirty = true
                }
            ))
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
        }
    }
}

private struct FigureGallery: View {
    let figures: [FigureInfo]
    @EnvironmentObject private var app: AppState
    @State private var editingFigure: FigureInfo?
    @State private var didRunDevFigureCropHook = false

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 14)]

    var body: some View {
        Group {
            if figures.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("このページに図はありません")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(figures) { figure in
                            FigureCard(
                                figure: figure,
                                imageURL: imageURL(for: figure),
                                revision: app.figureCropRevision,
                                onEdit: canEdit && destinationURL(for: figure) != nil
                                    ? { editingFigure = figure }
                                    : nil
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
        .sheet(item: $editingFigure) { figure in
            if let page = app.selectedPage {
                FigureCropSheet(page: page, figure: figure) { bbox in
                    app.applyFigureCrop(figureIndex: figure.index, bbox: bbox)
                }
            }
        }
#if DEBUG
        .onAppear {
            guard !didRunDevFigureCropHook,
                  ProcessInfo.processInfo.environment["SARASHINA_DEV_FIGURE_CROP"] == "1",
                  let first = figures.first
            else { return }
            didRunDevFigureCropHook = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                editingFigure = first
            }
        }
#endif
    }

    private var canEdit: Bool {
        !app.isRunning && app.selectedPage?.processedPath != nil
    }

    private func destinationURL(for figure: FigureInfo) -> URL? {
        guard let document = app.selectedDocument else { return nil }
        if let path = figure.path {
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path)
            }
            return AppPaths.documentDirectory(id: document.id)
                .appendingPathComponent(path)
        }
        if let absolute = figure.absolutePath {
            return URL(fileURLWithPath: absolute)
        }
        return nil
    }

    private func imageURL(for figure: FigureInfo) -> URL? {
        guard let url = destinationURL(for: figure),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }
}

private struct FigureCardLoadID: Hashable {
    let url: URL?
    let figure: FigureInfo
    let revision: Int
}

private struct FigureCard: View {
    let figure: FigureInfo
    let imageURL: URL?
    let revision: Int
    let onEdit: (() -> Void)?
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .underPageBackgroundColor))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)

            HStack {
                Text("図\(figure.index)")
                    .font(.caption.bold())
                Spacer()
                if let onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "crop")
                    }
                    .buttonStyle(.borderless)
                    .help("図の切り取り範囲を修正")
                }
                if let imageURL {
                    Button {
                        saveFigure(url: imageURL)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderless)
                    .help("図を保存")
                }
            }
            .font(.caption)
        }
        .task(id: FigureCardLoadID(url: imageURL, figure: figure, revision: revision)) {
            guard let imageURL else {
                image = nil
                return
            }
            image = NSImage(contentsOf: imageURL)
        }
    }

    private func saveFigure(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = url.lastPathComponent
        panel.title = "図を保存"
        if panel.runModal() == .OK, let destination = panel.url {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                presentError(error)
            }
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "図を保存できません"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private struct ResultEmptyView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("OCR 結果がここに表示されます")
                .font(.headline)
            Text(app.selectedDocument == nil
                 ? "左の文書を選び、⌘R で読み取りを開始してください。\n表・数式は整形され、図は切り出されます。"
                 : "このページはまだ読み取られていません。⌘R で OCR を開始してください。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}
