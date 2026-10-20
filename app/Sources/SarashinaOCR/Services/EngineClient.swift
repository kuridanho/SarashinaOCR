import Foundation

/// Owns the Python sidecar process and speaks JSON Lines over stdio.
@MainActor
final class EngineClient: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "停止"
            case .starting: return "起動中"
            case .running: return "稼働中"
            case .failed(let message): return "エラー: \(message)"
            }
        }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var lastLogLine: String = ""

    var onLog: ((String) -> Void)?
    var onUnexpectedExit: ((String) -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readBuffer = Data()
    private var stderrBuffer = Data()
    private var continuations: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventHandlers: [String: (EngineFrame) -> Void] = [:]
    private var counter = 0
    private var restartAttempts = 0
    private var intentionalStop = false
    private var processGeneration = 0
    private var launchConfiguration: (python: URL, engineDir: URL, modelDir: URL?)?

    var isRunning: Bool {
        process?.isRunning == true
    }

    // MARK: - Process lifecycle

    func start(python: URL, engineDir: URL, modelDir: URL?) throws {
        if isRunning { return }
        launchConfiguration = (python, engineDir, modelDir)
        state = .starting
        intentionalStop = false
        processGeneration += 1
        let generation = processGeneration

        let process = Process()
        process.executableURL = python
        var arguments = ["-m", "ocr_engine", "--backend", "mlx", "--log-level", "INFO"]
        if let modelDir {
            arguments += ["--model-dir", modelDir.path]
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = engineDir.path
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment.removeValue(forKey: "PYTHONHOME")
        process.environment = environment
        process.currentDirectoryURL = engineDir

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingestStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingestStderr(data) }
        }

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                self?.handleTermination(
                    status: terminated.terminationStatus,
                    generation: generation
                )
            }
        }

        do {
            try process.run()
        } catch {
            state = .failed("起動できません: \(error.localizedDescription)")
            throw error
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        state = .running
        lastLogLine = "エンジンを起動しました"
    }

    func restartIfConfigured() {
        guard let configuration = launchConfiguration, restartAttempts < 1 else { return }
        restartAttempts += 1
        stop(gracefully: false)
        do {
            try start(
                python: configuration.python,
                engineDir: configuration.engineDir,
                modelDir: configuration.modelDir
            )
            state = .running
        } catch {
            state = .failed("再起動できません: \(error.localizedDescription)")
        }
    }

    func stop(gracefully: Bool = true) {
        intentionalStop = true
        processGeneration += 1
        if gracefully, isRunning {
            sendOnly(method: "shutdown")
        }
        failAll(with: EngineClientError.terminated("停止しました"))
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        state = .stopped
    }

    // MARK: - Requests

    func request(
        _ method: String,
        params: [String: Any] = [:],
        id requestedID: String? = nil,
        onEvent: ((EngineFrame) -> Void)? = nil
    ) async throws -> JSONValue {
        let id = requestedID ?? nextID()
        if let onEvent {
            eventHandlers[id] = onEvent
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
            do {
                try sendFrame(method: method, params: params, id: id)
            } catch {
                continuations.removeValue(forKey: id)
                eventHandlers.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    func sendCancel(target: String) {
        sendOnly(method: "cancel", params: ["target": target])
    }

    func sendPing() {
        sendOnly(method: "ping")
    }

    func sendOnly(method: String, params: [String: Any] = [:]) {
        try? sendFrame(method: method, params: params, id: nextID())
    }

    private func nextID() -> String {
        counter += 1
        return "req-\(counter)-\(Int(Date().timeIntervalSince1970 * 1000))"
    }

    func makeRequestID() -> String {
        nextID()
    }

    private func sendFrame(method: String, params: [String: Any], id: String) throws {
        guard let stdinPipe, process?.isRunning == true else {
            throw EngineClientError.notRunning
        }
        let frame: [String: Any] = [
            "v": 1,
            "id": id,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: frame, options: [])
        var line = data
        line.append(0x0A)
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: line)
        } catch {
            throw EngineClientError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Stream handling

    private func ingestStdout(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let lineData = readBuffer[readBuffer.startIndex..<newline]
            readBuffer.removeSubrange(readBuffer.startIndex...newline)
            guard !lineData.isEmpty else { continue }
            do {
                let frame = try JSONDecoder().decode(EngineFrame.self, from: Data(lineData))
                handle(frame: frame)
            } catch {
                onLog?("[protocol] \(error.localizedDescription): \(String(decoding: lineData, as: UTF8.self))")
            }
        }
    }

    private func ingestStderr(_ data: Data) {
        stderrBuffer.append(data)
        while let newline = stderrBuffer.firstIndex(of: 0x0A) {
            let lineData = stderrBuffer[stderrBuffer.startIndex..<newline]
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            lastLogLine = line
            onLog?(line)
        }
    }

    private func handle(frame: EngineFrame) {
        eventHandlers[frame.id]?(frame)

        switch frame.event {
        case "done":
            eventHandlers.removeValue(forKey: frame.id)
            if let continuation = continuations.removeValue(forKey: frame.id) {
                continuation.resume(returning: frame.data)
            }
        case "error":
            eventHandlers.removeValue(forKey: frame.id)
            let payload = (try? frame.data.decode(EngineErrorPayload.self))
                ?? EngineErrorPayload(code: "E3002", message: "不明なエラー", recoverable: true)
            if let continuation = continuations.removeValue(forKey: frame.id) {
                continuation.resume(throwing: EngineClientError.engine(payload))
            }
        default:
            break
        }
    }

    private func handleTermination(status: Int32, generation: Int) {
        guard generation == processGeneration else { return }
        let wasIntentional = intentionalStop
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        failAll(with: EngineClientError.terminated("終了コード \(status)"))
        if wasIntentional {
            state = .stopped
        } else {
            state = .failed("エンジンが終了しました (code \(status))")
            onUnexpectedExit?("推論エンジンが終了しました。再起動します…")
        }
    }

    private func failAll(with error: Error) {
        for (_, continuation) in continuations {
            continuation.resume(throwing: error)
        }
        continuations.removeAll()
        eventHandlers.removeAll()
    }
}
