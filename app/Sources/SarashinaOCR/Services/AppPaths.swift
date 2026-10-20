import Foundation

enum AppPaths {
    static let appSupport: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("SarashinaOCR", isDirectory: true)
    }()

    static var documentsRoot: URL {
        appSupport.appendingPathComponent("documents", isDirectory: true)
    }

    static var modelsRoot: URL {
        appSupport.appendingPathComponent("models/sarashina2.2-ocr", isDirectory: true)
    }

    static var databaseURL: URL {
        appSupport.appendingPathComponent("db.sqlite")
    }

    static var logsRoot: URL {
        appSupport.appendingPathComponent("logs", isDirectory: true)
    }

    static func documentDirectory(id: String) -> URL {
        documentsRoot.appendingPathComponent(id, isDirectory: true)
    }

    static func ensureDirectories() throws {
        for url in [appSupport, documentsRoot, modelsRoot, logsRoot] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

enum Filename {
    static func sanitize(_ value: String, fallback: String = "document") -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        name = name.components(separatedBy: forbidden).joined(separator: "-")
        name = name.replacingOccurrences(of: "\u{0}", with: "")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { return fallback }
        if name.count > 120 { name = String(name.prefix(120)) }
        return name
    }
}
