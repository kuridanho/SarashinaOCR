import AppKit
import Foundation
import UniformTypeIdentifiers

enum ImportService {
    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "webp", "gif", "pdf"
    ]

    struct ImportOptions {
        var applyDocumentDetection: Bool = true
    }

    static func canImport(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    static func importFile(
        at url: URL,
        options: ImportOptions = ImportOptions()
    ) throws -> DocumentRecord {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw ImportError.unsupportedType(url.lastPathComponent)
        }
        if ext == "pdf" {
            return try importPDF(at: url)
        }
        return try importImages(at: [url], options: options)
    }

    /// Imports a series of image files as one multi-page document. Files are
    /// ordered by their natural filename order so `page-2.png` comes before
    /// `page-10.png`.
    static func importImages(
        at urls: [URL],
        options: ImportOptions = ImportOptions()
    ) throws -> DocumentRecord {
        let images = urls
            .filter { canImport($0) && !isPDF($0) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
        guard !images.isEmpty else {
            throw ImportError.noImages
        }
        try AppPaths.ensureDirectories()

        let id = UUID().uuidString.lowercased()
        let directory = AppPaths.documentDirectory(id: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            var pages: [PageRecord] = []
            pages.reserveCapacity(images.count)
            for (index, url) in images.enumerated() {
                do {
                    pages.append(
                        try makeImagePage(
                            sourceURL: url,
                            documentID: id,
                            directory: directory,
                            pageIndex: index,
                            options: options
                        )
                    )
                } catch {
                    throw ImportError.imageFailed(
                        url.lastPathComponent,
                        error.localizedDescription
                    )
                }
            }

            let now = Date().timeIntervalSince1970
            return DocumentRecord(
                id: id,
                title: seriesTitle(for: images),
                kind: "image",
                sourcePath: pages.first?.imagePath ?? "",
                pageCount: pages.count,
                createdAt: now,
                updatedAt: now,
                pages: pages
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func importPDF(at url: URL) throws -> DocumentRecord {
        let id = UUID().uuidString.lowercased()
        let directory = AppPaths.documentDirectory(id: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let sourceCopy = directory.appendingPathComponent("source.pdf")
            try FileManager.default.copyItem(at: url, to: sourceCopy)
            let rendered = try PreprocessService.rasterizePDF(source: sourceCopy, into: directory)
            guard !rendered.isEmpty else {
                throw ImportError.emptyPDF(url.lastPathComponent)
            }

            let now = Date().timeIntervalSince1970
            let title = url.deletingPathExtension().lastPathComponent
            var document = DocumentRecord(
                id: id,
                title: title.isEmpty ? "無題" : title,
                kind: "pdf",
                sourcePath: sourceCopy.path,
                pageCount: 0,
                createdAt: now,
                updatedAt: now,
                pages: []
            )
            document.pages = rendered.enumerated().map { index, page in
                PageRecord(
                    id: "\(id)-p\(String(format: "%04d", index + 1))",
                    index: index,
                    imagePath: sourceCopy.path,
                    processedPath: page.url.path,
                    width: page.width,
                    height: page.height,
                    ocrState: .pending,
                    result: nil
                )
            }
            document.pageCount = document.pages.count
            document.updatedAt = now
            return document
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func makeImagePage(
        sourceURL: URL,
        documentID: String,
        directory: URL,
        pageIndex: Int,
        options: ImportOptions
    ) throws -> PageRecord {
        let ext = sourceURL.pathExtension.lowercased()
        let number = String(format: "%03d", pageIndex + 1)
        let sourceCopy = directory.appendingPathComponent("source-\(number).\(ext)")
        try FileManager.default.copyItem(at: sourceURL, to: sourceCopy)

        // Keep an uncropped base so the crop can be widened or redone later.
        let base = directory.appendingPathComponent("page-\(number)-base.png")
        let baseImage = try PreprocessService.prepareImage(
            source: sourceCopy,
            destination: base,
            applyDocumentDetection: false
        )
        let processed = directory.appendingPathComponent("page-\(number).png")
        var pageImage = baseImage
        var cropQuad: [CGPoint]?
        if options.applyDocumentDetection,
           let quad = PreprocessService.documentQuad(in: base),
           let corrected = try? PreprocessService.correctPerspective(
               source: base,
               destination: processed,
               quad: quad
           ) {
            pageImage = corrected
            cropQuad = quad
        } else {
            try FileManager.default.copyItem(at: base, to: processed)
        }

        return PageRecord(
            id: "\(documentID)-p\(String(format: "%04d", pageIndex + 1))",
            index: pageIndex,
            imagePath: sourceCopy.path,
            processedPath: processed.path,
            cropBasePath: base.path,
            cropQuad: cropQuad,
            width: pageImage.width,
            height: pageImage.height,
            ocrState: .pending,
            result: nil
        )
    }

    /// Derives a readable title from a numbered image series, for example
    /// `scan-001.png`, `scan-002.png` -> `scan`.
    private static func seriesTitle(for urls: [URL]) -> String {
        let stems = urls.map { $0.deletingPathExtension().lastPathComponent }
        guard let first = stems.first else { return "無題" }
        guard stems.count > 1 else { return first.isEmpty ? "無題" : first }

        var prefix = first
        for stem in stems.dropFirst() {
            prefix = commonPrefix(prefix, stem)
            if prefix.isEmpty { break }
        }
        var trimmed = prefix
        while let last = trimmed.last,
              last.isNumber || last == "-" || last == "_" || last == " " || last == "." {
            trimmed.removeLast()
        }
        if trimmed.count >= 2 {
            return trimmed
        }
        if first.allSatisfy(\.isNumber) {
            return "画像 \(stems.count) 枚"
        }
        return first.isEmpty ? "画像 \(stems.count) 枚" : first
    }

    private static func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        var result = ""
        for (left, right) in zip(lhs, rhs) {
            guard left == right else { break }
            result.append(left)
        }
        return result
    }

    /// Imports an in-memory image (clipboard / screenshot) by round-tripping it
    /// through a temporary PNG file.
    static func importImageData(
        _ data: Data,
        suggestedName: String,
        options: ImportOptions = ImportOptions()
    ) throws -> DocumentRecord {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SarashinaOCR-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let url = tempDirectory.appendingPathComponent("\(Filename.sanitize(suggestedName)).png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        return try importFile(at: url, options: options)
    }

    enum ImportError: LocalizedError {
        case unsupportedType(String)
        case emptyPDF(String)
        case noImages
        case imageFailed(String, String)

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let name): return "対応していない形式です: \(name)"
            case .emptyPDF(let name): return "PDF にページがありません: \(name)"
            case .noImages: return "取り込める画像がありません"
            case .imageFailed(let name, let message): return "\(name): \(message)"
            }
        }
    }
}
