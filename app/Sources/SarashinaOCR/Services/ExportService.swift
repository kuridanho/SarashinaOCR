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

    /// Builds a single Markdown document for the whole-document preview.
    /// Page labels always use the original PDF page number, even when only
    /// some pages were scanned. A trailing standalone page number emitted by
    /// OCR is removed so it does not duplicate the preview's page label.
    /// Running headers and footers that repeat across pages are kept once and
    /// omitted from later pages.
    static func combinedPreviewMarkdown(pages: [PageRecord]) -> String {
        let total = pages.count
        guard total > 0 else { return "" }
        let ordered = pages.sorted(by: { $0.index < $1.index })
        let bodies: [String?] = ordered.map { page in
            guard let result = page.result else { return nil }
            return removingTrailingPageNumber(
                result.markdown,
                pageNumber: page.index + 1,
                total: total
            )
        }
        let repeated = repeatedEdgeBlocks(in: bodies.compactMap { $0 })
        var seenRepeated: Set<String> = []
        var chunks: [String] = []
        var lastRenderedIndex = -1

        for (offset, page) in ordered.enumerated() {
            guard let body = bodies[offset] else { continue }
            if page.index > lastRenderedIndex + 1 {
                chunks.append(
                    missingMarker(
                        from: lastRenderedIndex + 2,
                        to: page.index,
                        total: total
                    )
                )
            }
            let pageNumber = page.index + 1
            let thinned = thinningRepeatedEdges(
                in: body,
                repeated: repeated,
                seen: &seenRepeated
            )
            chunks.append(
                "<div class=\"page-marker\">p.\(pageNumber) / \(total)</div>\n\n\(thinned)"
            )
            lastRenderedIndex = page.index
        }

        if lastRenderedIndex >= 0, lastRenderedIndex < total - 1 {
            chunks.append(
                missingMarker(
                    from: lastRenderedIndex + 2,
                    to: total,
                    total: total
                )
            )
        }
        return chunks.joined(separator: "\n\n")
    }

    private struct EdgeBlock {
        var key: String
        var range: Swift.Range<Int>
    }

    /// Returns the short text blocks at the very top and bottom of a page.
    /// Only blocks of up to three lines that end at a paragraph boundary are
    /// considered, so ordinary body paragraphs are not mistaken for running
    /// headers or footers.
    private static func edgeBlocks(in body: String) -> [EdgeBlock] {
        let lines = body.components(separatedBy: .newlines)
        var blocks: [EdgeBlock] = []

        var top = 0
        while top < lines.count,
              lines[top].trimmingCharacters(in: .whitespaces).isEmpty
                || isHorizontalRule(lines[top]) {
            top += 1
        }
        if top < lines.count {
            var end = top
            while end < lines.count,
                  !lines[end].trimmingCharacters(in: .whitespaces).isEmpty,
                  end - top < 3 {
                end += 1
            }
            let tooLong = end < lines.count
                && !lines[end].trimmingCharacters(in: .whitespaces).isEmpty
            if !tooLong {
                let key = normalizedBlock(Array(lines[top..<end]))
                if key.count >= 3 {
                    blocks.append(EdgeBlock(key: key, range: top..<end))
                }
            }
        }

        var bottom = lines.count
        while bottom > 0, lines[bottom - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            bottom -= 1
        }
        while bottom > 0, isHorizontalRule(lines[bottom - 1]) {
            bottom -= 1
            while bottom > 0, lines[bottom - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                bottom -= 1
            }
        }
        if bottom > 0 {
            var start = bottom
            while start > 0,
                  !lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty,
                  bottom - start < 3 {
                start -= 1
            }
            let tooLong = start > 0
                && !lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty
            if !tooLong {
                let key = normalizedBlock(Array(lines[start..<bottom]))
                if key.count >= 3 {
                    let range = start..<bottom
                    if !blocks.contains(where: { $0.range == range }) {
                        blocks.append(EdgeBlock(key: key, range: range))
                    }
                }
            }
        }
        return blocks
    }

    private static func normalizedBlock(_ lines: [String]) -> String {
        var text = lines.joined(separator: " ")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[*_`#>|]", with: "", options: .regularExpression)
        text = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        text = text.components(separatedBy: .whitespacesAndNewlines).joined()
        text = text.lowercased()
        text = text.replacingOccurrences(
            of: "[。、，．・：；！？「」『』（）()\\[\\]{}<>\"'“”‘’—–\\-]",
            with: "",
            options: .regularExpression
        )
        return text
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let characters = Set(trimmed)
        guard characters.count == 1, let character = characters.first else { return false }
        return character == "-" || character == "*" || character == "_"
    }

    private static func repeatedEdgeBlocks(in bodies: [String]) -> Set<String> {
        guard bodies.count >= 2 else { return [] }
        var positions: [String: [Int]] = [:]
        for (index, body) in bodies.enumerated() {
            for key in Set(edgeBlocks(in: body).map(\.key)) {
                positions[key, default: []].append(index)
            }
        }

        // Running headers usually repeat on consecutive pages, while chapter
        // footers may appear on only a few consecutive pages. A low fraction
        // threshold catches alternating headers and chapter footers without
        // treating an occasional repeated heading as a running element.
        let minRun = bodies.count <= 2 ? 2 : 3
        let minOccurrences = min(10, max(3, Int(ceil(Double(bodies.count) * 0.05))))
        var repeated: Set<String> = []
        for (key, values) in positions {
            let sorted = values.sorted()
            var longestRun = 1
            var currentRun = 1
            if sorted.count > 1 {
                for index in 1..<sorted.count {
                    if sorted[index] == sorted[index - 1] + 1 {
                        currentRun += 1
                    } else {
                        currentRun = 1
                    }
                    longestRun = max(longestRun, currentRun)
                }
            }
            if longestRun >= minRun || sorted.count >= minOccurrences {
                repeated.insert(key)
            }
        }
        return repeated
    }

    private static func thinningRepeatedEdges(
        in body: String,
        repeated: Set<String>,
        seen: inout Set<String>
    ) -> String {
        guard !repeated.isEmpty else { return body }
        let lines = body.components(separatedBy: .newlines)
        var ranges: [Swift.Range<Int>] = []
        for block in edgeBlocks(in: body) {
            guard repeated.contains(block.key) else { continue }
            if seen.contains(block.key) {
                ranges.append(expandedRemovalRange(block.range, in: lines))
            } else {
                seen.insert(block.key)
            }
        }
        guard !ranges.isEmpty else { return body }

        let merged = mergedRanges(ranges)
        var remaining: [String] = []
        var cursor = 0
        for range in merged {
            if cursor < range.lowerBound {
                remaining.append(contentsOf: lines[cursor..<range.lowerBound])
            }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < lines.count {
            remaining.append(contentsOf: lines[cursor..<lines.count])
        }
        let text = remaining.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? body : text
    }

    private static func expandedRemovalRange(
        _ range: Swift.Range<Int>,
        in lines: [String]
    ) -> Swift.Range<Int> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower > 0 {
            let line = lines[lower - 1].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isHorizontalRule(line) {
                lower -= 1
            } else {
                break
            }
        }
        while upper < lines.count {
            let line = lines[upper].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isHorizontalRule(line) {
                upper += 1
            } else {
                break
            }
        }
        return lower..<upper
    }

    private static func mergedRanges(_ ranges: [Swift.Range<Int>]) -> [Swift.Range<Int>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Swift.Range<Int>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func missingMarker(from start: Int, to end: Int, total: Int) -> String {
        let pages = start == end ? "p.\(start)" : "p.\(start)–\(end)"
        return "<div class=\"page-marker missing\">\(pages) / \(total) ・ 未処理</div>"
    }

    private static func removingTrailingPageNumber(
        _ markdown: String,
        pageNumber: Int,
        total: Int
    ) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        var last = lines.count - 1
        while last >= 0, lines[last].trimmingCharacters(in: .whitespaces).isEmpty {
            last -= 1
        }
        guard last >= 0,
              isPageNumberLine(lines[last], pageNumber: pageNumber, total: total)
        else {
            return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        lines.remove(at: last)
        while let lastLine = lines.last,
              lastLine.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isPageNumberLine(_ line: String, pageNumber: Int, total: Int) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        let number = String(pageNumber)
        let accepted = [
            number,
            "- \(number) -",
            "— \(number) —",
            "– \(number) –",
            "－ \(number) －",
            "－\(number)－",
            "\(number) ページ",
            "\(number)ページ",
            "p.\(number)",
            "p. \(number)",
            "P.\(number)",
            "\(number) / \(total)",
            "\(number)/\(total)",
            "Page \(number)",
            "page \(number)"
        ]
        if accepted.contains(text) {
            return true
        }
        // Printed page numbers often differ from the PDF page index (for
        // example, page 1 of a PDF may be printed as 160). Treat a short
        // standalone number at the end of a page as a page number too.
        return text.count <= 4 && !text.isEmpty && text.allSatisfy(\.isNumber)
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
