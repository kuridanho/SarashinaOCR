import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum ResultTab: String, CaseIterable, Identifiable {
    case preview
    case raw
    case figures

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preview: return "プレビュー"
        case .raw: return "生テキスト"
        case .figures: return "図"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    // Documents
    @Published private(set) var documents: [DocumentRecord] = []
    @Published var selectedDocumentID: String? {
        didSet {
            if oldValue != selectedDocumentID {
                selectedPageIndex = 0
                resultTab = .preview
            }
        }
    }
    @Published private(set) var selectedPageIndex: Int = 0

    // Runtime
    @Published private(set) var isRunning = false
    @Published private(set) var isImporting = false
    @Published private(set) var streamingMarkdown = ""
    @Published private(set) var stageText = ""
    @Published private(set) var statusTokens = 0
    @Published private(set) var statusTokPerSec: Double = 0
    @Published private(set) var statusElapsed: Double = 0
    @Published private(set) var engineReady = false
    @Published var statusMessage = "待機中"
    @Published var lastError: String?
    @Published var showSetup = false
    @Published var lastExport: URL?

    // Display
    @Published var resultTab: ResultTab = .preview
    @Published var showBBoxOverlay = true
    @Published var showOriginalImage = false
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }

    // Settings
    @Published var preset: OCRPreset {
        didSet { UserDefaults.standard.set(preset.rawValue, forKey: "ocrPreset") }
    }
    @Published var maxNewTokens: Int {
        didSet { UserDefaults.standard.set(maxNewTokens, forKey: "maxNewTokens") }
    }
    @Published var applyDocumentDetection: Bool {
        didSet { UserDefaults.standard.set(applyDocumentDetection, forKey: "applyDocumentDetection") }
    }
    @Published var autoLoadModel: Bool {
        didSet { UserDefaults.standard.set(autoLoadModel, forKey: "autoLoadModel") }
    }
    @Published var idleUnloadMinutes: Int {
        didSet { UserDefaults.standard.set(idleUnloadMinutes, forKey: "idleUnloadMinutes") }
    }
    @Published var includePageHeadings: Bool {
        didSet { UserDefaults.standard.set(includePageHeadings, forKey: "includePageHeadings") }
    }

    let engine = EngineClient()
    let modelManager = ModelManager()

    private var store: DocumentStore?
    private var currentRequestID: String?
    private var tokenBuffer = ""
    private var lastFlush = Date.distantPast
    private var startedAt = Date()
    private var tickTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var loadTask: Task<Void, Error>?
    private var didStart = false
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let defaults = UserDefaults.standard
        let presetRaw = defaults.string(forKey: "ocrPreset") ?? OCRPreset.high.rawValue
        preset = OCRPreset(rawValue: presetRaw) ?? .high
        maxNewTokens = defaults.object(forKey: "maxNewTokens") as? Int ?? 6000
        applyDocumentDetection = defaults.object(forKey: "applyDocumentDetection") as? Bool ?? true
        autoLoadModel = defaults.object(forKey: "autoLoadModel") as? Bool ?? true
        let idle = defaults.object(forKey: "idleUnloadMinutes") as? Int ?? 10
        idleUnloadMinutes = idle
        includePageHeadings = defaults.object(forKey: "includePageHeadings") as? Bool ?? true
        let storedFont = defaults.object(forKey: "fontSize") as? Double ?? 100
        fontSize = storedFont

        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        modelManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

#if DEBUG
        if ProcessInfo.processInfo.environment["SARASHINA_DEV_LOG"] == "1" {
            engine.onLog = { line in
                FileHandle.standardError.write(Data("[engine] \(line)\n".utf8))
            }
        }
#endif

        engine.onUnexpectedExit = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.engineReady = false
                self.statusMessage = message
                self.engine.restartIfConfigured()
                if self.engine.state == .running {
                    self.statusMessage = "エンジンを再起動しました。もう一度実行してください"
                } else if case .failed(let reason) = self.engine.state {
                    self.lastError = "推論エンジンを再起動できませんでした: \(reason)"
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .sarashinaOpenDocuments,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let urls = notification.object as? [URL] else { return }
            Task { @MainActor in self?.importFiles(urls) }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.shutdown() }
        }
    }

    // MARK: - Derived state

    var selectedDocument: DocumentRecord? {
        guard let id = selectedDocumentID else { return nil }
        return documents.first { $0.id == id }
    }

    var selectedPage: PageRecord? {
        selectedDocument?.page(at: selectedPageIndex)
    }

    var selectedResult: StoredResult? {
        selectedPage?.result
    }

    var previewMarkdown: String {
        if isRunning { return streamingMarkdown }
        return selectedResult?.markdown ?? ""
    }

    var previewBaseDirectory: URL? {
        selectedDocument.map { AppPaths.documentDirectory(id: $0.id) }
    }

    var currentFigures: [FigureInfo] {
        selectedResult?.figures ?? []
    }

    var pageCount: Int {
        selectedDocument?.pageCount ?? 0
    }

    var expectedSeconds: Int {
        preset.estimatedSeconds
    }

    var canRunOCR: Bool {
        !isRunning && selectedPage != nil && modelManager.modelDirectory != nil && !isImporting
    }

    // MARK: - Lifecycle

    func start() {
        guard !didStart else { return }
        didStart = true
        do {
            try AppPaths.ensureDirectories()
            store = try DocumentStore()
            documents = try store?.loadDocuments() ?? []
            if selectedDocumentID == nil {
                selectedDocumentID = documents.first?.id
            }
        } catch {
            lastError = error.localizedDescription
        }
        modelManager.refresh()
        if modelManager.modelDirectory == nil {
            showSetup = true
        } else if autoLoadModel {
            Task {
                do {
                    try await ensureEngineReady()
                } catch {
                    statusMessage = "モデルの読み込みに失敗しました"
                }
            }
        }
    }

    func shutdown() {
        tickTask?.cancel()
        idleTask?.cancel()
        engine.stop()
    }

    /// Releases the resident model so it can be replaced or deleted safely.
    func unloadModel() async {
        idleTask?.cancel()
        idleTask = nil
        guard engineReady else { return }
        _ = try? await engine.request("unload")
        engineReady = false
        statusMessage = "モデルをアンロードしました"
    }

    func openSetup() {
        showSetup = true
        NSApp.activate(ignoringOtherApps: true)
    }

    func loadResidentModelNow() {
        guard modelManager.modelDirectory != nil else {
            openSetup()
            return
        }
        Task {
            do {
                try await ensureEngineReady()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Documents

    func importFiles(_ urls: [URL]) {
        let urls = urls.filter { ImportService.canImport($0) }
        guard !urls.isEmpty else {
            lastError = "対応しているファイルがありません（PNG / JPEG / HEIC / TIFF / PDF）"
            return
        }
        isImporting = true
        statusMessage = "取り込み中…"
        let options = ImportService.ImportOptions(applyDocumentDetection: applyDocumentDetection)
        Task {
            var imported: [DocumentRecord] = []
            var errors: [String] = []
            for url in urls {
                do {
                    let document = try await Task.detached(priority: .userInitiated) {
                        try ImportService.importFile(at: url, options: options)
                    }.value
                    imported.append(document)
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                for document in imported {
                    do {
                        try self.store?.save(document)
                    } catch {
                        errors.append("保存に失敗: \(error.localizedDescription)")
                    }
                }
                self.documents.insert(contentsOf: imported, at: 0)
                if let first = imported.first {
                    self.selectedDocumentID = first.id
                    self.selectedPageIndex = 0
                }
                self.isImporting = false
                self.statusMessage = imported.isEmpty ? "取り込みに失敗しました" : "取り込みました"
                if !errors.isEmpty {
                    self.lastError = errors.joined(separator: "\n")
                }
#if DEBUG
                if ProcessInfo.processInfo.environment["SARASHINA_DEV_AUTORUN"] == "1",
                   let first = imported.first {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self.selectedDocumentID = first.id
                        self.selectedPageIndex = 0
                        self.runOCR()
                    }
                }
#endif
            }
        }
    }

    func importFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "画像または PDF を選択"
        var types: [UTType] = [.pdf, .png, .jpeg, .tiff, .bmp, .gif, .heic, .webP]
        for ext in ["heif", "tif"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK {
            importFiles(panel.urls)
        }
    }

    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            importFiles([first])
            return
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            lastError = "クリップボードに画像がありません"
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "クリップボード-\(formatter.string(from: Date()))"
        isImporting = true
        let options = ImportService.ImportOptions(applyDocumentDetection: applyDocumentDetection)
        Task {
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try ImportService.importImageData(data, suggestedName: name, options: options)
                }.value
                await MainActor.run {
                    try? self.store?.save(document)
                    self.documents.insert(document, at: 0)
                    self.selectedDocumentID = document.id
                    self.selectedPageIndex = 0
                    self.isImporting = false
                    self.statusMessage = "貼り付けました"
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func deleteSelectedDocument() {
        guard let document = selectedDocument else { return }
        do {
            try store?.delete(documentID: document.id)
            try? FileManager.default.removeItem(at: AppPaths.documentDirectory(id: document.id))
            documents.removeAll { $0.id == document.id }
            selectedDocumentID = documents.first?.id
            selectedPageIndex = 0
            statusMessage = "削除しました"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectPage(_ index: Int) {
        guard index >= 0, index < pageCount else { return }
        selectedPageIndex = index
    }

    func nextPage() { selectPage(selectedPageIndex + 1) }
    func previousPage() { selectPage(selectedPageIndex - 1) }

    // MARK: - Page editing

    /// Removes a page's stale OCR result after the page image itself changes.
    private func clearPageOutputs(for page: PageRecord) {
        try? store?.deleteResult(pageID: page.id)
        let documentDirectory = URL(fileURLWithPath: page.imagePath).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: documentDirectory.appendingPathComponent("result.md"))
        try? FileManager.default.removeItem(at: documentDirectory.appendingPathComponent("raw.md"))
        let assets = documentDirectory
            .appendingPathComponent("assets")
            .appendingPathComponent(String(format: "p%03d", page.index + 1))
        try? FileManager.default.removeItem(at: assets)
    }

    func rotateCurrentPage() {
        guard var document = selectedDocument, let page = selectedPage,
              !isRunning
        else { return }
        do {
            let updated = try ImportService.rasterizePage(document: document, page: page, quarterTurns: 1)
            clearPageOutputs(for: page)
            document.pages[selectedPageIndex] = updated
            document.updatedAt = Date().timeIntervalSince1970
            replaceDocument(document)
            try store?.save(document)
            statusMessage = "ページを回転しました"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func applyPerspective(quad: [CGPoint]) {
        guard !isRunning, var document = selectedDocument, let page = selectedPage,
              let processedPath = page.processedPath
        else { return }
        let url = URL(fileURLWithPath: processedPath)
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try PreprocessService.correctPerspective(
                        source: url, destination: url, quad: quad
                    )
                }.value
                await MainActor.run {
                    var updated = page
                    updated.width = image.width
                    updated.height = image.height
                    updated.result = nil
                    updated.ocrState = .pending
                    self.clearPageOutputs(for: page)
                    document.pages[self.selectedPageIndex] = updated
                    document.updatedAt = Date().timeIntervalSince1970
                    self.replaceDocument(document)
                    try? self.store?.save(document)
                    self.statusMessage = "台形補正を適用しました"
                }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    func redoDocumentDetection() {
        guard var document = selectedDocument, let page = selectedPage,
              !isRunning, document.kind == "image", page.processedPath != nil
        else { return }
        let source = URL(fileURLWithPath: document.sourcePath)
        let destination = URL(fileURLWithPath: page.processedPath!)
        Task {
            do {
                let image = try await Task.detached {
                    try PreprocessService.prepareImage(
                        source: source,
                        destination: destination,
                        applyDocumentDetection: true
                    )
                }.value
                await MainActor.run {
                    var updated = page
                    updated.width = image.width
                    updated.height = image.height
                    updated.result = nil
                    updated.ocrState = .pending
                    self.clearPageOutputs(for: page)
                    document.pages[self.selectedPageIndex] = updated
                    document.updatedAt = Date().timeIntervalSince1970
                    self.replaceDocument(document)
                    try? self.store?.save(document)
                    self.statusMessage = "書類検出を再実行しました"
                }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
        }
    }

    // MARK: - Engine

    private func ensureEngineReady() async throws {
        if engineReady, engine.isRunning { return }
        if let loadTask {
            try await loadTask.value
            return
        }
        let task = Task { try await self.performLoad() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func performLoad() async throws {
        guard let modelDirectory = modelManager.modelDirectory else {
            throw EngineSetupError.modelMissing
        }
        let paths = try resolveEnginePaths()
        statusMessage = "エンジンを起動しています…"
        if !engine.isRunning {
            try engine.start(
                python: paths.python,
                engineDir: paths.engine,
                modelDir: modelDirectory
            )
        }
        _ = try await engine.request("load", onEvent: { [weak self] frame in
            guard frame.event == "stage" else { return }
            guard let data = frame.data.objectValue else { return }
            if let stage = data["stage"]?.stringValue {
                self?.stageText = Self.stageLabel(stage, data: data)
            }
        })
        engineReady = true
        statusMessage = "モデル準備完了"
        scheduleIdleUnload()
    }

    private struct EnginePaths {
        var python: URL
        var engine: URL
    }

    private func resolveEnginePaths() throws -> EnginePaths {
        let environment = ProcessInfo.processInfo.environment
        if let python = environment["SARASHINA_ENGINE_PYTHON"],
           let engine = environment["SARASHINA_ENGINE_DIR"] {
            return EnginePaths(
                python: URL(fileURLWithPath: python),
                engine: URL(fileURLWithPath: engine)
            )
        }
        if let resources = Bundle.main.resourceURL {
            let python = resources.appendingPathComponent("engine-venv/bin/python3")
            let engine = resources.appendingPathComponent("engine")
            if FileManager.default.isExecutableFile(atPath: python.path),
               FileManager.default.fileExists(atPath: engine.appendingPathComponent("ocr_engine").path) {
                return EnginePaths(python: python, engine: engine)
            }
        }
        let roots = [Bundle.main.bundleURL, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        for root in roots {
            var current = root
            for _ in 0..<7 {
                let python = current.appendingPathComponent(".venv/bin/python")
                let engine = current.appendingPathComponent("engine")
                if FileManager.default.isExecutableFile(atPath: python.path),
                   FileManager.default.fileExists(atPath: engine.appendingPathComponent("ocr_engine").path) {
                    return EnginePaths(python: python, engine: engine)
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        if let python = Bundle.main.resourceURL?.appendingPathComponent("engine-venv/bin/python3"),
           FileManager.default.isExecutableFile(atPath: python.path) {
            return EnginePaths(python: python, engine: AppPaths.appSupport.appendingPathComponent("engine"))
        }
        throw EngineSetupError.engineMissing
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        let minutes = idleUnloadMinutes
        guard minutes > 0 else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.isRunning, self.engineReady else { return }
            _ = try? await self.engine.request("unload")
            self.engineReady = false
            self.statusMessage = "モデルをアンロードしました"
        }
    }

    // MARK: - OCR

    func runOCR() {
        guard !isRunning, let document = selectedDocument, let page = selectedPage else { return }
        guard modelManager.modelDirectory != nil else {
            showSetup = true
            return
        }
        tokenBuffer = ""
        streamingMarkdown = ""
        lastFlush = .distantPast
        isRunning = true
        resultTab = .preview
        statusTokens = 0
        statusTokPerSec = 0
        statusElapsed = 0
        stageText = "前処理"
        statusMessage = "OCR を開始しています…"
        startedAt = Date()
        startTicker()

        let requestID = engine.makeRequestID()
        currentRequestID = requestID
        let figuresDirectory = AppPaths.documentDirectory(id: document.id)
            .appendingPathComponent("assets/p\(String(format: "%03d", page.index + 1))", isDirectory: true)
        let assetPrefix = "assets/p\(String(format: "%03d", page.index + 1))"

        Task {
            do {
                try await ensureEngineReady()
                try await executeOCR(
                    requestID: requestID,
                    document: document,
                    page: page,
                    figuresDirectory: figuresDirectory,
                    assetPrefix: assetPrefix,
                    didRetryMemory: false
                )
            } catch {
                await MainActor.run {
                    self.finishRun()
                    self.handleOCR(error: error, document: document, page: page)
                }
            }
        }
    }

    private func executeOCR(
        requestID: String,
        document: DocumentRecord,
        page: PageRecord,
        figuresDirectory: URL,
        assetPrefix: String,
        didRetryMemory: Bool
    ) async throws {
        if currentRequestID != requestID {
            currentRequestID = requestID
        }
        var params: [String: Any] = [
            "image": page.displayPath,
            "preset": preset.rawValue,
            "max_new_tokens": maxNewTokens,
            "figures_dir": figuresDirectory.path,
            "asset_prefix": assetPrefix
        ]
        params["max_pixels"] = preset.maxPixels

        let data: JSONValue
        do {
            data = try await engine.request("ocr", params: params, id: requestID, onEvent: { [weak self] frame in
                self?.handleOCRFrame(frame)
            })
        } catch {
            if let engineError = error as? EngineClientError,
               case .engine(let payload) = engineError,
               payload.code == "E3001",
               !didRetryMemory {
                _ = try? await engine.request("unload")
                engineReady = false
                preset = .standard
                statusMessage = "メモリ不足のため標準プリセットで再試行します"
                try await ensureEngineReady()
                try await executeOCR(
                    requestID: engine.makeRequestID(),
                    document: document,
                    page: page,
                    figuresDirectory: figuresDirectory,
                    assetPrefix: assetPrefix,
                    didRetryMemory: true
                )
                return
            }
            throw error
        }

        let result = try data.decode(EngineOCRResult.self)
        guard var document = documents.first(where: { $0.id == document.id }),
              page.index < document.pages.count
        else { return }

        let stored = StoredResult(
            id: UUID().uuidString.lowercased(),
            markdown: result.markdown,
            raw: result.raw,
            text: result.text,
            preset: preset.rawValue,
            stats: result.stats,
            figures: result.figures,
            warnings: result.warnings,
            createdAt: Date().timeIntervalSince1970
        )
        var updatedPage = document.pages[page.index]
        updatedPage.result = stored
        updatedPage.ocrState = result.cancelled ? .pending : .done
        document.pages[page.index] = updatedPage
        document.updatedAt = Date().timeIntervalSince1970
        replaceDocument(document)
        try? store?.save(document)

        let documentDirectory = AppPaths.documentDirectory(id: document.id)
        try? result.markdown.write(
            to: documentDirectory.appendingPathComponent("result.md"),
            atomically: true,
            encoding: .utf8
        )
        try? result.raw.write(
            to: documentDirectory.appendingPathComponent("raw.md"),
            atomically: true,
            encoding: .utf8
        )

        await MainActor.run {
            self.statusTokens = result.stats.outputTokens ?? 0
            self.statusTokPerSec = result.stats.tokPerSec ?? 0
            self.statusElapsed = result.stats.seconds ?? 0
            self.statusMessage = result.cancelled ? "中断しました（部分結果を保存）" : "完了"
            self.finishRun()
            if let warning = result.warnings.first {
                self.statusMessage += " ・ \(warning.message)"
            }
            self.scheduleIdleUnload()
        }
    }

    func cancelOCR() {
        guard isRunning, let requestID = currentRequestID else { return }
        engine.sendCancel(target: requestID)
        stageText = "停止しています…"
        statusMessage = "停止を要求しました"
    }

    private func handleOCRFrame(_ frame: EngineFrame) {
        switch frame.event {
        case "token":
            guard let text = frame.data.objectValue?["text"]?.stringValue else { return }
            tokenBuffer += text
            let now = Date()
            if now.timeIntervalSince(lastFlush) > 0.12 {
                lastFlush = now
                streamingMarkdown = tokenBuffer
            }
        case "stage":
            guard let data = frame.data.objectValue,
                  let stage = data["stage"]?.stringValue
            else { return }
            stageText = Self.stageLabel(stage, data: data)
            if stage == "decode", let tokens = data["prompt_tokens"]?.numberInt {
                statusTokens = tokens
            }
        case "warning":
            if let message = frame.data.objectValue?["message"]?.stringValue {
                statusMessage = message
            }
        default:
            break
        }
    }

    private func handleOCR(error: Error, document: DocumentRecord, page: PageRecord) {
        var document = document
        if page.index < document.pages.count {
            var updated = document.pages[page.index]
            updated.ocrState = .failed
            document.pages[page.index] = updated
            replaceDocument(document)
            try? store?.save(document)
        }
        if let engineError = error as? EngineClientError, case .engine(let payload) = engineError {
            lastError = "\(payload.code): \(payload.message)"
            if payload.code == "E3001" {
                statusMessage = "メモリ不足です。標準プリセットで再実行してください"
            } else if payload.code == "E1001" {
                showSetup = true
            }
        } else {
            lastError = error.localizedDescription
        }
        statusMessage = "失敗しました"
    }

    private func finishRun() {
        if !tokenBuffer.isEmpty {
            streamingMarkdown = tokenBuffer
        }
        isRunning = false
        currentRequestID = nil
        tickTask?.cancel()
        tickTask = nil
        stageText = ""
        streamingMarkdown = ""
        tokenBuffer = ""
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isRunning else { return }
                self.statusElapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
    }

    // MARK: - Export / clipboard

    func copyCurrentMarkdown() {
        let markdown: String
        if selectedResult != nil {
            markdown = selectedResult?.markdown ?? ""
        } else if isRunning {
            markdown = streamingMarkdown
        } else {
            markdown = ""
        }
        guard !markdown.isEmpty else { return }
        ExportService.copyMarkdownToPasteboard(markdown)
        statusMessage = "Markdown をコピーしました"
    }

    func copyAllPages() {
        guard let document = selectedDocument else { return }
        let markdown = ExportService.combinedMarkdown(
            pages: document.pages.filter { $0.result != nil },
            includePageHeadings: includePageHeadings
        )
        guard !markdown.isEmpty else { return }
        ExportService.copyMarkdownToPasteboard(markdown)
        statusMessage = "全ページをコピーしました"
    }

    func export(format: ExportService.Format, range: ExportService.Range) {
        guard let document = selectedDocument else { return }
        let pages: [PageRecord]
        switch range {
        case .currentPage:
            guard let page = selectedPage, page.result != nil else {
                lastError = "書き出す結果がありません"
                return
            }
            pages = [page]
        case .allPages:
            pages = document.pages.filter { $0.result != nil }
            guard !pages.isEmpty else {
                lastError = "書き出す結果がありません"
                return
            }
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "書き出す"
        panel.message = "保存先フォルダを選択してください"
        panel.title = "書き出し"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        do {
            let output = try ExportService.export(
                document: document,
                pages: pages,
                format: format,
                to: directory,
                includePageHeadings: includePageHeadings
            )
            lastExport = output.url
            statusMessage = "書き出しました: \(output.url.lastPathComponent)"
            ExportService.reveal(output.url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveEditedResult(_ markdown: String) {
        guard var document = selectedDocument, var page = selectedPage,
              var result = page.result
        else { return }
        result.markdown = markdown
        page.result = result
        document.pages[selectedPageIndex] = page
        document.updatedAt = Date().timeIntervalSince1970
        replaceDocument(document)
        try? store?.save(document)
        statusMessage = "編集を保存しました"
    }

    // MARK: - Helpers

    private func replaceDocument(_ document: DocumentRecord) {
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            documents[index] = document
        }
    }

    private static func stageLabel(_ stage: String, data: [String: JSONValue]) -> String {
        switch stage {
        case "preprocess": return "前処理"
        case "preprocess_done":
            if let width = data["width"]?.numberInt, let height = data["height"]?.numberInt,
               let tokens = data["visual_tokens"]?.numberInt {
                return "前処理完了 ・ \(width)×\(height) ・ \(tokens) visual tokens"
            }
            return "前処理完了"
        case "model_load": return "モデルを読み込み中…"
        case "prefill":
            if let tokens = data["prompt_tokens"]?.numberInt {
                return "画像を解析中 ・ \(tokens) prompt tokens"
            }
            return "画像を解析中"
        case "first_token": return "読み取り中"
        case "decode": return "読み取り中"
        case "postprocess": return "後処理"
        default: return stage
        }
    }

    enum EngineSetupError: LocalizedError {
        case modelMissing
        case engineMissing

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                return "モデルが導入されていません。セットアップ画面からダウンロードしてください"
            case .engineMissing:
                return "推論エンジンが見つかりません。README のセットアップ手順を確認してください"
            }
        }
    }
}

private extension JSONValue {
    var numberInt: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }
}
