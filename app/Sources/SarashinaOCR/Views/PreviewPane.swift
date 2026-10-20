import AppKit
import SwiftUI

struct PreviewPane: View {
    @EnvironmentObject private var app: AppState
    @State private var showCropSheet = false

    var body: some View {
        Group {
            if let document = app.selectedDocument, let page = app.selectedPage {
                VStack(spacing: 0) {
                    header(document: document, page: page)
                    Divider()
                    imageArea(document: document, page: page)
                    Divider()
                    controls(document: document, page: page)
                }
            } else {
                EmptyPreview()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showCropSheet) {
            if let page = app.selectedPage {
                CropSheet(page: page) { quad in
                    app.applyPerspective(quad: quad)
                }
            }
        }
    }

    private func header(document: DocumentRecord, page: PageRecord) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(document.kind == "pdf" ? "PDF" : "画像") ・ \(page.width) × \(page.height) px")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                app.previousPage()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(app.selectedPageIndex <= 0)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            Text("\(app.selectedPageIndex + 1) / \(max(app.pageCount, 1))")
                .monospacedDigit()
                .font(.callout)
            Button {
                app.nextPage()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(app.selectedPageIndex >= app.pageCount - 1)
            .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func imageArea(document: DocumentRecord, page: PageRecord) -> some View {
        let useOriginal = app.showOriginalImage && document.kind == "image"
        let path = useOriginal ? page.imagePath : page.displayPath
        // Bounding boxes belong to the processed image, so never draw them on
        // the uncorrected original.
        let figures = useOriginal ? [] : (app.selectedResult?.figures ?? [])
        return PageCanvas(
            imagePath: path,
            width: page.width,
            height: page.height,
            figures: app.showBBoxOverlay ? figures : [],
            badge: useOriginal ? "元画像" : nil
        )
        .overlay(alignment: .topLeading) {
            if app.isImporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("取り込み中…").font(.caption)
                }
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .padding(12)
            }
        }
    }

    private func controls(document: DocumentRecord, page: PageRecord) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("プリセット", selection: $app.preset) {
                    ForEach(OCRPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .disabled(app.isRunning)

                Text("約 \(app.expectedSeconds) 秒")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    if app.isRunning { app.cancelOCR() } else { app.runOCR() }
                } label: {
                    Label(app.isRunning ? "停止" : "OCR 実行",
                          systemImage: app.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!app.isRunning && !app.canRunOCR)
            }

            HStack(spacing: 8) {
                Toggle("図 bbox", isOn: $app.showBBoxOverlay)
                    .toggleStyle(.checkbox)
                    .disabled(figuresEmpty)
                if document.kind == "image" {
                    Toggle("元画像", isOn: $app.showOriginalImage)
                        .toggleStyle(.checkbox)
                }

                Spacer(minLength: 4)

                Button {
                    showCropSheet = true
                } label: {
                    Label("4隅", systemImage: "rectangle.dashed")
                }
                .help("4隅をドラッグしてトリミング")
                .disabled(app.isRunning)

                Button {
                    app.rotateCurrentPage()
                } label: {
                    Label("回転", systemImage: "rotate.right")
                }
                .help("ページを 90° 回転")
                .disabled(app.isRunning)

                Button {
                    app.redoDocumentDetection()
                } label: {
                    Label("補正", systemImage: "crop")
                }
                .help("書類検出からやり直す")
                .disabled(app.isRunning || document.kind == "pdf")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            if app.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .progressViewStyle(.circular)
                        Text(app.stageText.isEmpty ? "処理中…" : app.stageText)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Text("\(app.statusTokens) tok")
                            .font(.caption.monospacedDigit())
                        Text(Self.duration(app.statusElapsed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                .transition(.opacity)
            } else if let result = app.selectedResult {
                HStack(spacing: 12) {
                    if let seconds = result.stats.seconds {
                        Label(String(format: "%.1f 秒", seconds), systemImage: "clock")
                    }
                    if let tokens = result.stats.outputTokens {
                        Label("\(tokens) tokens", systemImage: "text.alignleft")
                    }
                    if let speed = result.stats.tokPerSec, speed > 0 {
                        Label(String(format: "%.1f tok/s", speed), systemImage: "speedometer")
                    }
                    if let memory = result.stats.peakMemoryMb {
                        Label(String(format: "%.1f GB", memory / 1024), systemImage: "memorychip")
                    }
                    Spacer()
                    Text(result.preset.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("このページはまだ処理されていません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var figuresEmpty: Bool {
        (app.selectedResult?.figures.count ?? 0) == 0
    }

    private static func duration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct PageCanvas: View {
    let imagePath: String
    let width: Int
    let height: Int
    let figures: [FigureInfo]
    let badge: String?

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .padding(10)
                    if !figures.isEmpty {
                        Canvas { context, size in
                            let available = CGSize(
                                width: max(0, size.width - 20),
                                height: max(0, size.height - 20)
                            )
                            let rect = Self.fitRect(
                                width: CGFloat(width), height: CGFloat(height), in: available
                            ).offsetBy(dx: 10, dy: 10)
                            for figure in figures where figure.bbox.count >= 4 {
                                let box = CGRect(
                                    x: rect.minX + CGFloat(figure.bbox[0]) / 1000 * rect.width,
                                    y: rect.minY + CGFloat(figure.bbox[1]) / 1000 * rect.height,
                                    width: (CGFloat(figure.bbox[2]) - CGFloat(figure.bbox[0])) / 1000 * rect.width,
                                    height: (CGFloat(figure.bbox[3]) - CGFloat(figure.bbox[1])) / 1000 * rect.height
                                )
                                context.fill(
                                    Path(roundedRect: box, cornerRadius: 3),
                                    with: .color(.orange.opacity(0.14))
                                )
                                context.stroke(
                                    Path(roundedRect: box, cornerRadius: 3),
                                    with: .color(.orange),
                                    lineWidth: 2
                                )
                                context.draw(
                                    Text("図\(figure.index)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white),
                                    at: CGPoint(x: box.minX + 18, y: box.minY + 11)
                                )
                            }
                        }
                        .allowsHitTesting(false)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                        Text("画像を読み込めません")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                if let badge {
                    Text(badge)
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(16)
                }
            }
            .task(id: "\(imagePath)#\(width)x\(height)") {
                image = NSImage(contentsOfFile: imagePath)
            }
        }
    }

    private static func fitRect(width: CGFloat, height: CGFloat, in size: CGSize) -> CGRect {
        guard width > 0, height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let imageAspect = width / height
        let viewAspect = size.width / size.height
        if imageAspect > viewAspect {
            let w = size.width
            let h = w / imageAspect
            return CGRect(x: 0, y: (size.height - h) / 2, width: w, height: h)
        } else {
            let h = size.height
            let w = h * imageAspect
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: h)
        }
    }
}

private struct EmptyPreview: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("文書を開いてください")
                .font(.title3)
            Text("画像または PDF をドロップするか、⌘O で取り込めます。\n処理はすべてこの Mac の中で完結します。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
