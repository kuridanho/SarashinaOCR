import CryptoKit
import Foundation

struct ModelManifest: Codable {
    struct File: Codable, Identifiable {
        var path: String
        var size: Int64
        var sha256: String
        var url: String

        var id: String { path }
    }

    var name: String
    var repo: String
    var revision: String
    var totalBytes: Int64
    var license: String?
    var files: [File]

    enum CodingKeys: String, CodingKey {
        case name
        case repo
        case revision
        case totalBytes = "total_bytes"
        case license
        case files
    }

    static func bundled() throws -> ModelManifest {
        guard let url = Bundle.module.url(
            forResource: "model_manifest",
            withExtension: "json",
            subdirectory: "Resources"
        ) else {
            throw ModelManager.ModelError.manifestMissing
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ModelManifest.self, from: data)
    }
}

final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    enum DownloadError: Error {
        case paused
        case moveFailed(String)
        case invalidResponse
    }

    private let url: URL
    private let destination: URL
    private let resumeData: Data?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var paused = false
    private var finished = false
    private var moveError: Error?

    var onProgress: ((Int64, Int64) -> Void)?
    private(set) var producedResumeData: Data?

    init(url: URL, destination: URL, resumeData: Data? = nil) {
        self.url = url
        self.destination = destination
        self.resumeData = resumeData
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 3600
            configuration.waitsForConnectivity = true
            let session = URLSession(
                configuration: configuration, delegate: self, delegateQueue: nil
            )
            self.session = session
            let task: URLSessionDownloadTask
            if let resumeData {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: url)
            }
            self.task = task
            task.resume()
        }
    }

    func pause() {
        paused = true
        task?.cancel(byProducingResumeData: { [weak self] data in
            self?.producedResumeData = data
        })
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = DownloadError.moveFailed(error.localizedDescription)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !finished else { return }
        finished = true
        session.invalidateAndCancel()
        if let moveError {
            continuation?.resume(throwing: moveError)
        } else if let error {
            continuation?.resume(throwing: paused ? DownloadError.paused : error)
        } else {
            continuation?.resume(returning: destination)
        }
        continuation = nil
    }
}

@MainActor
final class ModelManager: ObservableObject {
    enum Status: Equatable {
        case unknown
        case missing
        case ready(URL)
        case downloading
        case paused
        case verifying
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .unknown: return "確認中"
            case .missing: return "未導入"
            case .ready: return "準備完了"
            case .downloading: return "ダウンロード中"
            case .paused: return "一時停止"
            case .verifying: return "検証中"
            case .failed(let message): return "エラー: \(message)"
            }
        }
    }

    enum ModelError: LocalizedError {
        case manifestMissing
        case notEnoughSpace(required: Int64, available: Int64)
        case checksumMismatch(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .manifestMissing:
                return "モデルマニフェストが同梱されていません"
            case .notEnoughSpace(let required, let available):
                let formatter = ByteCountFormatter()
                return "空き容量が不足しています（必要 \(formatter.string(fromByteCount: required)) / 空き \(formatter.string(fromByteCount: available))）"
            case .checksumMismatch(let path):
                return "チェックサムが一致しません: \(path)"
            case .cancelled:
                return "ダウンロードを中止しました"
            }
        }
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressText: String = ""
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var manifest: ModelManifest?
    @Published private(set) var modelDirectory: URL?

    private var activeDownload: FileDownloader?
    private var resumeData: [String: Data] = [:]
    private var pauseRequested = false
    private var cancelRequested = false
    private var downloadTask: Task<Void, Never>?

    private static let appSupport: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("SarashinaOCR", isDirectory: true)
    }()

    var modelsRoot: URL { Self.appSupport.appendingPathComponent("models/sarashina2.2-ocr") }
    var currentLink: URL { modelsRoot.appendingPathComponent("current") }

    /// True when the active model lives in the app-managed download folder.
    /// Development builds may instead use `models/` inside the repository.
    var isManagedModel: Bool {
        guard let directory = modelDirectory else { return false }
        let root = modelsRoot.standardizedFileURL.path + "/"
        return directory.standardizedFileURL.path.hasPrefix(root)
    }

    init() {
        manifest = try? ModelManifest.bundled()
        totalBytes = manifest?.totalBytes ?? 0
        refresh()
    }

    // MARK: - Discovery

    func refresh() {
        if let env = ProcessInfo.processInfo.environment["SARASHINA_MODEL_DIR"] {
            let url = URL(fileURLWithPath: env).expandingTildeInPath
            if isUsableModel(at: url) {
                markReady(url)
                return
            }
        }
        if let revision = manifest?.revision {
            let url = modelsRoot.appendingPathComponent(revision)
            if isUsableModel(at: url) {
                markReady(url)
                return
            }
        }
        if isUsableModel(at: currentLink) {
            markReady(currentLink.resolvingSymlinksInPath())
            return
        }
        if let dev = Self.developmentModelDirectory(), isUsableModel(at: dev) {
            markReady(dev)
            return
        }
        status = .missing
        modelDirectory = nil
        progress = 0
    }

    private func markReady(_ url: URL) {
        modelDirectory = url
        status = .ready(url)
        progress = 1
        progressText = "モデル準備完了"
        downloadedBytes = totalBytes
    }

    private func isUsableModel(at url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.appendingPathComponent("config.json").path),
              fileManager.fileExists(atPath: url.appendingPathComponent("model.safetensors").path)
        else { return false }
        let custom = url.appendingPathComponent("sarashina2_vision")
        return fileManager.fileExists(atPath: custom.path)
    }

    static func developmentModelDirectory() -> URL? {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        ]
        for start in candidates {
            var current = start
            for _ in 0..<6 {
                let candidate = current.appendingPathComponent("models/sarashina2.2-ocr-mlx-4bit")
                if FileManager.default.fileExists(
                    atPath: candidate.appendingPathComponent("model.safetensors").path
                ) {
                    return candidate
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }
        return nil
    }

    func modelRevision() -> String {
        manifest?.revision ?? "unknown"
    }

    // MARK: - Download

    func startDownload() {
        guard downloadTask == nil else { return }
        pauseRequested = false
        cancelRequested = false
        downloadTask = Task { [weak self] in
            await self?.runDownload()
            await MainActor.run { self?.downloadTask = nil }
        }
    }

    func pauseDownload() {
        pauseRequested = true
        activeDownload?.pause()
    }

    func resumeDownload() {
        startDownload()
    }

    func cancelDownload() {
        cancelRequested = true
        pauseRequested = false
        activeDownload?.pause()
        downloadTask?.cancel()
        status = .missing
        progress = 0
        progressText = ""
    }

    private func runDownload() async {
        guard let manifest else {
            status = .failed("マニフェストがありません")
            return
        }
        let revision = manifest.revision
        let target = modelsRoot.appendingPathComponent(revision)

        let available = Self.availableBytes(at: modelsRoot)
        if available > 0 && available < manifest.totalBytes {
            status = .failed(
                ModelError.notEnoughSpace(
                    required: manifest.totalBytes, available: available
                ).localizedDescription
            )
            return
        }

        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            status = .failed("保存先を作成できません: \(error.localizedDescription)")
            return
        }

        status = .downloading
        var completedBytes: Int64 = 0
        for (index, file) in manifest.files.enumerated() {
            if cancelRequested {
                status = .missing
                progress = 0
                progressText = ""
                return
            }
            if pauseRequested {
                status = .paused
                return
            }
            let destination = target.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: destination.path),
               (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(file.size) {
                // Verify files left over from a previous run before trusting them.
                if let digest = try? await Self.sha256(of: destination), digest == file.sha256 {
                    completedBytes += file.size
                    updateOverall(completed: completedBytes, current: 0, currentTotal: 0,
                                  fileIndex: index, fileCount: manifest.files.count)
                    continue
                }
                try? FileManager.default.removeItem(at: destination)
            }
            guard let url = URL(string: file.url) else { continue }

            activeDownload = nil
            let downloader = FileDownloader(
                url: url, destination: destination, resumeData: resumeData[file.path]
            )
            activeDownload = downloader
            let baseBytes = completedBytes
            downloader.onProgress = { [weak self] written, expected in
                Task { @MainActor in
                    self?.updateOverall(
                        completed: baseBytes,
                        current: written,
                        currentTotal: expected > 0 ? expected : file.size,
                        fileIndex: index,
                        fileCount: manifest.files.count
                    )
                }
            }

            do {
                _ = try await downloader.start()
                resumeData.removeValue(forKey: file.path)
                status = .verifying
                progressText = "検証中: \(file.path)"
                let digest = try await Self.sha256(of: destination)
                guard digest == file.sha256 else {
                    try? FileManager.default.removeItem(at: destination)
                    throw ModelError.checksumMismatch(file.path)
                }
                completedBytes += file.size
                status = .downloading
            } catch FileDownloader.DownloadError.paused {
                if cancelRequested {
                    status = .missing
                    progress = 0
                    progressText = ""
                    return
                }
                if let data = downloader.producedResumeData {
                    resumeData[file.path] = data
                }
                status = .paused
                return
            } catch {
                if cancelRequested {
                    status = .missing
                    progress = 0
                    progressText = ""
                    return
                }
                status = .failed(error.localizedDescription)
                return
            }
            activeDownload = nil
        }

        if cancelRequested {
            status = .missing
            progress = 0
            progressText = ""
            return
        }

        let revisionFile = target.appendingPathComponent(".revision")
        try? (manifest.revision + "\n").write(to: revisionFile, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: currentLink)
        try? FileManager.default.createSymbolicLink(
            at: currentLink, withDestinationURL: target
        )
        activeDownload = nil
        markReady(target)
    }

    private func updateOverall(
        completed: Int64, current: Int64, currentTotal: Int64, fileIndex: Int, fileCount: Int
    ) {
        let total = max(totalBytes, 1)
        let value = min(Double(completed + current) / Double(total), 1)
        progress = value
        downloadedBytes = completed + current
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        progressText = "\(formatter.string(fromByteCount: downloadedBytes)) / \(formatter.string(fromByteCount: total)) ・ \(fileIndex + 1)/\(fileCount) ファイル"
    }

    // MARK: - Import / verify / delete

    func importModel(from directory: URL) async {
        guard let manifest else { return }
        let target = modelsRoot.appendingPathComponent(manifest.revision)
        status = .verifying
        progressText = "モデルをコピーしています…"
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let items = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix(".") || name == "__pycache__" { continue }
                let destination = target.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: item, to: destination)
            }
            try? (manifest.revision + "\n").write(
                to: target.appendingPathComponent(".revision"),
                atomically: true, encoding: .utf8
            )
            try? FileManager.default.removeItem(at: currentLink)
            try? FileManager.default.createSymbolicLink(
                at: currentLink, withDestinationURL: target
            )
            let report = try await verify(directory: target, manifest: manifest)
            if report.isEmpty {
                markReady(target)
            } else {
                status = .failed("検証に失敗しました: \(report.prefix(3).joined(separator: ", "))")
            }
        } catch {
            status = .failed("インポートに失敗しました: \(error.localizedDescription)")
        }
    }

    func verifyInstalledModel() async {
        guard let manifest, let directory = modelDirectory else { return }
        status = .verifying
        progressText = "チェックサムを検証しています…"
        let problems = (try? await verify(directory: directory, manifest: manifest)) ?? ["検証エラー"]
        if problems.isEmpty {
            markReady(directory)
            progressText = "検証に成功しました"
        } else {
            status = .failed("検証に失敗しました: \(problems.prefix(3).joined(separator: ", "))")
        }
    }

    private func verify(directory: URL, manifest: ModelManifest) async throws -> [String] {
        var problems: [String] = []
        for file in manifest.files {
            let url = directory.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                problems.append("\(file.path) がありません")
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if Int64(size) != file.size {
                problems.append("\(file.path) のサイズが不正")
                continue
            }
            let digest = try await Self.sha256(of: url)
            if digest != file.sha256 {
                problems.append("\(file.path) のハッシュが不正")
            }
        }
        return problems
    }

    func deleteModel() {
        guard let manifest else { return }
        let target = modelsRoot.appendingPathComponent(manifest.revision)
        try? FileManager.default.removeItem(at: currentLink)
        try? FileManager.default.removeItem(at: target)
        refresh()
    }

    // MARK: - Helpers

    private static func availableBytes(at url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    nonisolated private static func sha256(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                let data = try handle.read(upToCount: 8 * 1024 * 1024) ?? Data()
                if data.isEmpty { break }
                hasher.update(data: data)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }
}

private extension URL {
    var expandingTildeInPath: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
