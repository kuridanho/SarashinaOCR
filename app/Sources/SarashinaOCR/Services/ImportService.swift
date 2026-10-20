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

    static func importFile(
        at url: URL,
        options: ImportOptions = ImportOptions()
    ) throws -> DocumentRecord {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw ImportError.unsupportedType(url.lastPathComponent)
        }
        try AppPaths.ensureDirectories()

        let id = UUID().uuidString.lowercased()
        let directory = AppPaths.documentDirectory(id: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let now = Date().timeIntervalSince1970
        let title = url.deletingPathExtension().lastPathComponent
        var document = DocumentRecord(
            id: id,
            title: title.isEmpty ? "無題" : title,
            kind: ext == "pdf" ? "pdf" : "image",
            sourcePath: "",
            pageCount: 0,
            createdAt: now,
            updatedAt: now,
            pages: []
        )

        if ext == "pdf" {
            let sourceCopy = directory.appendingPathComponent("source.pdf")
            try FileManager.default.copyItem(at: url, to: sourceCopy)
            document.sourcePath = sourceCopy.path
            let rendered = try PreprocessService.rasterizePDF(source: sourceCopy, into: directory)
            guard !rendered.isEmpty else {
                throw ImportError.emptyPDF(url.lastPathComponent)
            }
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
        } else {
            let sourceCopy = directory.appendingPathComponent("source.\(ext)")
            try FileManager.default.copyItem(at: url, to: sourceCopy)
            document.sourcePath = sourceCopy.path
            // Keep an uncropped base so the crop can be widened or redone later.
            let base = directory.appendingPathComponent("page-001-base.png")
            let baseImage = try PreprocessService.prepareImage(
                source: sourceCopy,
                destination: base,
                applyDocumentDetection: false
            )
            let processed = directory.appendingPathComponent("page-001.png")
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
            document.pages = [
                PageRecord(
                    id: "\(id)-p0001",
                    index: 0,
                    imagePath: sourceCopy.path,
                    processedPath: processed.path,
                    cropBasePath: base.path,
                    cropQuad: cropQuad,
                    width: pageImage.width,
                    height: pageImage.height,
                    ocrState: .pending,
                    result: nil
                )
            ]
        }

        document.pageCount = document.pages.count
        document.updatedAt = now
        return document
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

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let name): return "対応していない形式です: \(name)"
            case .emptyPDF(let name): return "PDF にページがありません: \(name)"
            }
        }
    }
}
