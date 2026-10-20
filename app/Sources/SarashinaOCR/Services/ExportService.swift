import AppKit
import Foundation
import UniformTypeIdentifiers

enum ExportService {
    enum Format: String, CaseIterable, Identifiable {
        case markdown
        case plainText
        case json

        var id: String { rawValue }

        var title: String {
            switch self {
            case .markdown: return "Markdown + assets"
            case .plainText: return "プレーンテキスト"
            case .json: return "構造化 JSON"
            }
        }

        var fileExtension: String {
            switch self {
            case .markdown: return "md"
            case .plainText: return "txt"
            case .json: return "json"
            }
        }
    }

    enum Range {
        case currentPage
        case allPages
    }

    struct ExportResult {
        var url: URL
        var isDirectory: Bool
    }

    static func combinedMarkdown(pages: [PageRecord], includePageHeadings: Bool = true) -> String {
        var chunks: [String] = []
        for page in pages {
            guard let result = page.result else { continue }
            if includePageHeadings {
                chunks.append("## p.\(page.index + 1)\n\n" + result.markdown)
            } else {
                chunks.append(result.markdown)
            }
        }
        return chunks.joined(separator: "\n\n---\n\n")
    }

    static func combinedText(pages: [PageRecord], includePageHeadings: Bool = true) -> String {
        var chunks: [String] = []
        for page in pages {
            guard let result = page.result else { continue }
            if includePageHeadings {
                chunks.append("p.\(page.index + 1)\n\n" + result.text)
            } else {
                chunks.append(result.text)
            }
        }
        return chunks.joined(separator: "\n\n")
    }

    @discardableResult
    static func export(
        document: DocumentRecord,
        pages: [PageRecord],
        format: Format,
        to parentDirectory: URL,
        includePageHeadings: Bool = true
    ) throws -> ExportResult {
        let baseName = Filename.sanitize(document.title)
        let folder = uniqueDirectory(
            parentDirectory.appendingPathComponent(baseName, isDirectory: true)
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let documentDirectory = AppPaths.documentDirectory(id: document.id)
        let assetsSource = documentDirectory.appendingPathComponent("assets", isDirectory: true)
        if FileManager.default.fileExists(atPath: assetsSource.path) {
            try? FileManager.default.copyItem(
                at: assetsSource, to: folder.appendingPathComponent("assets", isDirectory: true)
            )
        }

        let file: URL
        switch format {
        case .markdown:
            file = folder.appendingPathComponent("\(baseName).md")
            try combinedMarkdown(pages: pages, includePageHeadings: includePageHeadings)
                .write(to: file, atomically: true, encoding: .utf8)
        case .plainText:
            file = folder.appendingPathComponent("\(baseName).txt")
            try combinedText(pages: pages, includePageHeadings: includePageHeadings)
                .write(to: file, atomically: true, encoding: .utf8)
        case .json:
            file = folder.appendingPathComponent("\(baseName).json")
            let payload: [String: Any] = [
                "document": [
                    "id": document.id,
                    "title": document.title,
                    "kind": document.kind,
                    "page_count": document.pageCount,
                    "created_at": document.createdAt,
                    "updated_at": document.updatedAt
                ],
                "pages": pages.map { page -> [String: Any] in
                    var value: [String: Any] = [
                        "index": page.index,
                        "width": page.width,
                        "height": page.height,
                        "state": page.ocrState.rawValue
                    ]
                    if let result = page.result {
                        value["markdown"] = result.markdown
                        value["text"] = result.text
                        value["figures"] = result.figures.map { figure in
                            ["index": figure.index, "bbox": figure.bbox, "path": figure.path ?? ""]
                        }
                        value["warnings"] = result.warnings.map { ["code": $0.code, "message": $0.message] }
                        value["stats"] = (try? JSONSerialization.jsonObject(
                            with: JSONEncoder().encode(result.stats)
                        )) ?? [:]
                    }
                    return value
                }
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: file)
        }
        return ExportResult(url: folder, isDirectory: true)
    }

    static func copyMarkdownToPasteboard(_ markdown: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
    }

    static func copyRichTextToPasteboard(_ markdown: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        if let attributed = try? NSAttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            pasteboard.setData(
                attributed.rtf(from: NSRange(location: 0, length: attributed.length)),
                forType: .rtf
            )
        }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func uniqueDirectory(_ url: URL) -> URL {
        var candidate = url
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent)-\(index)", isDirectory: true)
            index += 1
        }
        return candidate
    }
}

extension NSAttributedString {
    func rtf(from range: NSRange) -> Data? {
        try? data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
}
