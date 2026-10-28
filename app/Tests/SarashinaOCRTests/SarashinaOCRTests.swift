import AppKit
import SQLite3
import XCTest
@testable import SarashinaOCR

final class ModelsTests: XCTestCase {
    func testEngineFrameDecoding() throws {
        let json = """
        {"v":1,"id":"req-1","event":"token","data":{"text":"こんにちは"}}
        """
        let frame = try JSONDecoder().decode(EngineFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.id, "req-1")
        XCTAssertEqual(frame.event, "token")
        XCTAssertEqual(frame.data.objectValue?["text"]?.stringValue, "こんにちは")
    }

    func testEngineResultDecodingUsesSnakeCase() throws {
        let json = """
        {
          "raw": "# 見出し",
          "markdown": "# 見出し",
          "text": "見出し",
          "figures": [],
          "warnings": [],
          "cancelled": false,
          "image": {"width": 100, "height": 200, "original_width": 100, "original_height": 200, "visual_tokens": 40},
          "stats": {"output_tokens": 12, "tok_per_s": 40.5}
        }
        """
        let result = try JSONDecoder.engine.decode(EngineOCRResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.stats.outputTokens, 12)
        XCTAssertEqual(result.image.visualTokens, 40)
        XCTAssertEqual(result.image.originalHeight, 200)
    }

    func testPresetMaxPixels() {
        XCTAssertEqual(OCRPreset.high.maxPixels, 2_458_624)
        XCTAssertEqual(OCRPreset.standard.maxPixels, 1_324_960)
        XCTAssertEqual(OCRPreset.fast.maxPixels, 705_600)
    }

    func testBundledWebAssetsAndManifest() throws {
        let index = try XCTUnwrap(WebResources.indexURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: index.path))
        let root = try XCTUnwrap(WebResources.rootURL)
        for name in [
            "vendor/markdown-it.min.js",
            "vendor/katex.min.js",
            "vendor/katex.min.css",
            "vendor/texmath.js",
            "vendor/dompurify.min.js"
        ] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                "missing \(name)"
            )
        }
        let manifest = try ModelManifest.bundled()
        XCTAssertEqual(manifest.revision, "6585fb9ed1fbb263eb39c57a2b45c5c21a8aadff")
        XCTAssertFalse(manifest.files.isEmpty)
    }
}

final class DocumentStoreTests: XCTestCase {
    private var databaseURL: URL!

    override func setUpWithError() throws {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarashina-test-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        if let databaseURL {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
        }
    }

    func testRoundTripAndDelete() throws {
        let store = try DocumentStore(url: databaseURL)
        let result = StoredResult(
            id: "result-1",
            markdown: "# 請求書\n\n![図1](assets/p001/fig-001.png)",
            raw: "# 請求書",
            text: "請求書",
            preset: "high",
            stats: OCRStats(outputTokens: 42, seconds: 3.5, tokPerSec: 12),
            figures: [
                FigureInfo(index: 1, bbox: [10, 20, 300, 400], bboxPx: [1, 2, 3, 4],
                           path: "assets/p001/fig-001.png", absolutePath: "/tmp/fig-001.png")
            ],
            warnings: [WarningInfo(code: "W0001", message: "テスト")],
            createdAt: 100
        )
        let page = PageRecord(
            id: "page-1", index: 0, imagePath: "/tmp/source.png",
            processedPath: "/tmp/processed.png",
            cropBasePath: "/tmp/base.png",
            cropQuad: [
                CGPoint(x: 0.1, y: 0.2),
                CGPoint(x: 0.9, y: 0.2),
                CGPoint(x: 0.9, y: 0.8),
                CGPoint(x: 0.1, y: 0.8)
            ],
            width: 100, height: 200,
            ocrState: .done, result: result
        )
        let document = DocumentRecord(
            id: "doc-1", title: "テスト", kind: "image", sourcePath: "/tmp/source.png",
            pageCount: 1, createdAt: 1, updatedAt: 2, pages: [page]
        )

        try store.save(document)
        let loaded = try store.loadDocuments()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.title, "テスト")
        XCTAssertEqual(loaded.first?.pages.first?.result?.stats.outputTokens, 42)
        XCTAssertEqual(loaded.first?.pages.first?.result?.figures.first?.bbox, [10, 20, 300, 400])
        XCTAssertEqual(loaded.first?.pages.first?.result?.warnings.first?.code, "W0001")
        XCTAssertEqual(loaded.first?.pages.first?.cropBasePath, "/tmp/base.png")
        XCTAssertEqual(loaded.first?.pages.first?.cropQuad?.count, 4)
        XCTAssertEqual(loaded.first?.pages.first?.cropQuad?[2], CGPoint(x: 0.9, y: 0.8))

        try store.deleteResult(pageID: "page-1")
        XCTAssertNil(try store.loadDocuments().first?.pages.first?.result)

        try store.delete(documentID: "doc-1")
        XCTAssertTrue(try store.loadDocuments().isEmpty)
    }

    func testMigratesLegacyPagesTableForCropEditing() throws {
        var legacyDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &legacyDB), SQLITE_OK)
        let schema = """
        CREATE TABLE documents(
            id TEXT PRIMARY KEY, title TEXT NOT NULL, kind TEXT NOT NULL,
            source_path TEXT NOT NULL, page_count INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE pages(
            id TEXT PRIMARY KEY, document_id TEXT NOT NULL, idx INTEGER NOT NULL,
            image_path TEXT NOT NULL, processed_path TEXT,
            width INTEGER NOT NULL DEFAULT 0, height INTEGER NOT NULL DEFAULT 0,
            bbox_json TEXT, ocr_state TEXT NOT NULL DEFAULT 'pending',
            updated_at REAL NOT NULL, UNIQUE(document_id, idx)
        );
        INSERT INTO documents VALUES('doc', '旧文書', 'pdf', '/tmp/source.pdf', 1, 1, 1);
        INSERT INTO pages VALUES('page', 'doc', 0, '/tmp/source.pdf', '/tmp/page.png',
                                 100, 200, NULL, 'pending', 1);
        """
        XCTAssertEqual(sqlite3_exec(legacyDB, schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(legacyDB)
        legacyDB = nil

        let store = try DocumentStore(url: databaseURL)
        var document = try XCTUnwrap(try store.loadDocuments().first)
        XCTAssertNil(document.pages.first?.cropBasePath)
        XCTAssertNil(document.pages.first?.cropQuad)

        document.pages[0].cropBasePath = "/tmp/base.png"
        document.pages[0].cropQuad = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0, y: 1)
        ]
        try store.save(document)
        let reloaded = try XCTUnwrap(try store.loadDocuments().first)
        XCTAssertEqual(reloaded.pages.first?.cropBasePath, "/tmp/base.png")
        XCTAssertEqual(reloaded.pages.first?.cropQuad?.count, 4)
    }
}

final class ExportServiceTests: XCTestCase {
    func testCombinedMarkdownAndText() {
        let pages = [
            PageRecord(
                id: "p1", index: 0, imagePath: "/tmp/a", processedPath: nil,
                width: 1, height: 1, ocrState: .done,
                result: StoredResult(
                    id: "r1", markdown: "# 一", raw: "# 一", text: "一",
                    preset: "high", stats: .empty, figures: [], warnings: [], createdAt: 0
                )
            ),
            PageRecord(
                id: "p2", index: 1, imagePath: "/tmp/b", processedPath: nil,
                width: 1, height: 1, ocrState: .done,
                result: StoredResult(
                    id: "r2", markdown: "# 二", raw: "# 二", text: "二",
                    preset: "high", stats: .empty, figures: [], warnings: [], createdAt: 0
                )
            )
        ]
        let markdown = ExportService.combinedMarkdown(pages: pages)
        XCTAssertTrue(markdown.contains("## p.1"))
        XCTAssertTrue(markdown.contains("## p.2"))
        XCTAssertTrue(markdown.contains("---"))
        let text = ExportService.combinedText(pages: pages)
        XCTAssertTrue(text.contains("一"))
        XCTAssertTrue(text.contains("二"))
    }

    func testCombinedPreviewUsesOriginalPageNumbersAndDropsOCRPageNumber() throws {
        func page(index: Int, markdown: String?) -> PageRecord {
            let result = markdown.map {
                StoredResult(
                    id: "r\(index)", markdown: $0, raw: $0, text: $0,
                    preset: "high", stats: .empty, figures: [], warnings: [], createdAt: 0
                )
            }
            return PageRecord(
                id: "p\(index)", index: index, imagePath: "/tmp/\(index)",
                processedPath: nil, width: 100, height: 100,
                ocrState: result == nil ? .pending : .done, result: result
            )
        }

        let pages = [
            page(index: 0, markdown: "一\n\n1"),
            page(index: 1, markdown: nil),
            page(index: 2, markdown: "三\n\n3"),
            page(index: 3, markdown: nil)
        ]
        let markdown = ExportService.combinedPreviewMarkdown(pages: pages)

        XCTAssertTrue(markdown.contains("p.1 / 4"))
        XCTAssertTrue(markdown.contains("p.2 / 4 ・ 未処理"))
        XCTAssertTrue(markdown.contains("p.3 / 4"))
        XCTAssertTrue(markdown.contains("p.4 / 4 ・ 未処理"))
        XCTAssertFalse(markdown.contains("一\n\n1"))
        XCTAssertFalse(markdown.contains("三\n\n3"))
        let firstPage = try XCTUnwrap(markdown.range(of: "p.1 / 4")?.lowerBound)
        let thirdPage = try XCTUnwrap(markdown.range(of: "p.3 / 4")?.lowerBound)
        XCTAssertLessThan(firstPage, thirdPage)
    }
}

final class BatchOCRPlanningTests: XCTestCase {
    func testBatchSkipsPagesThatAlreadyHaveResults() {
        let doneResult = StoredResult(
            id: "r1", markdown: "# 完了", raw: "# 完了", text: "完了",
            preset: "high", stats: .empty, figures: [], warnings: [], createdAt: 0
        )
        let pages = [
            PageRecord(
                id: "p1", index: 0, imagePath: "/tmp/1", processedPath: nil,
                width: 100, height: 100, ocrState: .done, result: doneResult
            ),
            PageRecord(
                id: "p2", index: 1, imagePath: "/tmp/2", processedPath: nil,
                width: 100, height: 100, ocrState: .pending, result: nil
            ),
            PageRecord(
                id: "p3", index: 2, imagePath: "/tmp/3", processedPath: nil,
                width: 100, height: 100, ocrState: .failed, result: nil
            )
        ]
        let document = DocumentRecord(
            id: "doc", title: "PDF", kind: "pdf", sourcePath: "/tmp/source.pdf",
            pageCount: 3, createdAt: 0, updatedAt: 0, pages: pages
        )
        XCTAssertEqual(AppState.pagesForBatch(in: document).map(\.index), [1, 2])
    }
}

final class PreprocessServiceTests: XCTestCase {
    func testPerspectiveCorrectionWritesImage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarashina-preprocess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.png")
        try makeImage(width: 400, height: 300).write(to: source)

        let destination = directory.appendingPathComponent("corrected.png")
        let quad = [
            CGPoint(x: 0.05, y: 0.05),
            CGPoint(x: 0.95, y: 0.05),
            CGPoint(x: 0.95, y: 0.95),
            CGPoint(x: 0.05, y: 0.95)
        ]
        let output = try PreprocessService.correctPerspective(
            source: source, destination: destination, quad: quad
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertGreaterThan(output.width, 100)
        XCTAssertGreaterThan(output.height, 100)
    }

    func testCropQuadRotationKeepsCornerOrder() {
        let quad = [
            CGPoint(x: 0.1, y: 0.2),
            CGPoint(x: 0.8, y: 0.2),
            CGPoint(x: 0.8, y: 0.9),
            CGPoint(x: 0.1, y: 0.9)
        ]
        var rotated = quad
        for _ in 0..<4 {
            rotated = PreprocessService.rotateQuadClockwise(rotated)
        }
        for (actual, expected) in zip(rotated, quad) {
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.000_001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.000_001)
        }

        let once = PreprocessService.rotateQuadClockwise(quad)
        let expected = [
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.8, y: 0.1),
            CGPoint(x: 0.8, y: 0.8),
            CGPoint(x: 0.1, y: 0.8)
        ]
        for (actual, point) in zip(once, expected) {
            XCTAssertEqual(actual.x, point.x, accuracy: 0.000_001)
            XCTAssertEqual(actual.y, point.y, accuracy: 0.000_001)
        }
    }

    func testRotationSwapsDimensions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarashina-rotate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("page.png")
        try makeImage(width: 400, height: 300).write(to: imageURL)
        let rotated = try PreprocessService.rotate(
            imageAt: imageURL, quarterTurns: 1, destination: imageURL
        )
        XCTAssertEqual(rotated.width, 300)
        XCTAssertEqual(rotated.height, 400)
    }

    func testFigureCropUsesTopLeftCoordinates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarashina-figure-crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("page.png")
        try makeCornerMarkerImage(width: 400, height: 300).write(to: source)

        let topLeftURL = directory.appendingPathComponent("top-left.png")
        let topLeft = try PreprocessService.cropImage(
            source: source,
            destination: topLeftURL,
            normalizedRect: CGRect(x: 0, y: 0, width: 0.25, height: 0.25)
        )
        XCTAssertEqual(topLeft.image.width, 100)
        XCTAssertEqual(topLeft.image.height, 75)
        XCTAssertEqual(topLeft.pixelRect, [0, 0, 100, 75])

        let topLeftImage = try XCTUnwrap(NSImage(contentsOf: topLeftURL))
        var topLeftRect = CGRect(origin: .zero, size: topLeftImage.size)
        let topLeftCG = try XCTUnwrap(
            topLeftImage.cgImage(forProposedRect: &topLeftRect, context: nil, hints: nil)
        )
        XCTAssertTrue(isDark(topLeftCG, x: 50, y: 37))

        let bottomRightURL = directory.appendingPathComponent("bottom-right.png")
        let bottomRight = try PreprocessService.cropImage(
            source: source,
            destination: bottomRightURL,
            normalizedRect: CGRect(x: 0.75, y: 0.75, width: 0.25, height: 0.25)
        )
        XCTAssertEqual(bottomRight.image.width, 100)
        XCTAssertEqual(bottomRight.image.height, 75)
        XCTAssertEqual(bottomRight.pixelRect, [300, 225, 400, 300])

        let bottomRightImage = try XCTUnwrap(NSImage(contentsOf: bottomRightURL))
        var bottomRightRect = CGRect(origin: .zero, size: bottomRightImage.size)
        let bottomRightCG = try XCTUnwrap(
            bottomRightImage.cgImage(
                forProposedRect: &bottomRightRect, context: nil, hints: nil
            )
        )
        XCTAssertFalse(isDark(bottomRightCG, x: 50, y: 37))
    }

    func testPDFRasterizationKeepsPageUpright() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarashina-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdfURL = directory.appendingPathComponent("marker.pdf")
        try makeMarkerPDF(at: pdfURL)
        let pages = try PreprocessService.rasterizePDF(source: pdfURL, into: directory)
        XCTAssertEqual(pages.count, 1)

        let singleURL = directory.appendingPathComponent("single-page.png")
        let single = try PreprocessService.rasterizePDFPage(
            source: pdfURL, index: 0, destination: singleURL
        )
        XCTAssertEqual(single.width, pages[0].width)
        XCTAssertEqual(single.height, pages[0].height)

        let image = try XCTUnwrap(NSImage(contentsOf: pages[0].url))
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(
            image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        )
        XCTAssertTrue(
            isDark(cgImage, x: cgImage.width / 2, y: cgImage.height / 8),
            "the marker drawn at the top of the PDF must stay at the top"
        )
        XCTAssertFalse(
            isDark(cgImage, x: cgImage.width / 2, y: cgImage.height * 7 / 8),
            "the bottom of the page must stay blank"
        )
    }

    private func makeMarkerPDF(at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 300)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "test", code: 4)
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: 220, width: 160, height: 60))
        context.endPDFPage()
        context.closePDF()
    }

    private func isDark(_ image: CGImage, x: Int, y: Int) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return false }
        let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
        guard offset + 2 < CFDataGetLength(data) else { return false }
        return bytes[offset] < 64 && bytes[offset + 1] < 64 && bytes[offset + 2] < 64
    }

    private func makeCornerMarkerImage(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 100, width: 100, height: 100))
        guard let image = context.makeImage() else {
            throw NSError(domain: "test", code: 2)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "test", code: 3)
        }
        return data
    }

    private func makeImage(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "test", code: 1)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 320, height: 220))
        guard let image = context.makeImage() else {
            throw NSError(domain: "test", code: 2)
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "test", code: 3)
        }
        return data
    }
}

final class ImportServiceTests: XCTestCase {
    private var importedIDs: [String] = []

    override func tearDownWithError() throws {
        for id in importedIDs {
            try? FileManager.default.removeItem(at: AppPaths.documentDirectory(id: id))
        }
        importedIDs.removeAll()
    }

    func testImportsImageSeriesAsOneDocumentInNaturalOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarashina-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let names = ["scan-10.png", "scan-2.png", "scan-1.png"]
        for name in names {
            try makeImage(width: 400, height: 300)
                .write(to: directory.appendingPathComponent(name))
        }
        let urls = names.map { directory.appendingPathComponent($0) }
        let document = try ImportService.importImages(
            at: urls,
            options: ImportService.ImportOptions(applyDocumentDetection: false)
        )
        importedIDs.append(document.id)

        XCTAssertEqual(document.kind, "image")
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(document.pages.map(\.index), [0, 1, 2])
        XCTAssertEqual(document.title, "scan")
        XCTAssertEqual(
            document.pages.map { URL(fileURLWithPath: $0.imagePath).lastPathComponent },
            ["source-001.png", "source-002.png", "source-003.png"]
        )

        // Natural sort: scan-1, scan-2, scan-10.
        let thirdPageData = try Data(contentsOf: URL(fileURLWithPath: document.pages[2].imagePath))
        let scan10Data = try Data(contentsOf: directory.appendingPathComponent("scan-10.png"))
        XCTAssertEqual(thirdPageData, scan10Data)

        for page in document.pages {
            let processed = try XCTUnwrap(page.processedPath)
            let base = try XCTUnwrap(page.cropBasePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: processed))
            XCTAssertTrue(FileManager.default.fileExists(atPath: base))
        }
    }

    private func makeImage(width: Int, height: Int) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw NSError(domain: "test", code: 1) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: width - 80, height: height - 80))
        guard let image = context.makeImage() else { throw NSError(domain: "test", code: 2) }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "test", code: 3)
        }
        return data
    }
}

final class ExportPreviewThinningTests: XCTestCase {
    func testPreviewThinsRepeatedRunningHeadersAndFooters() {
        let pages = [
            page(0, "本文1\n\nPART II  \n組織のなかの人間心理  \n\n160"),
            page(1, "本文2\n\nCHAPTER 4  \nモチベーションの迷宮への招待  \n\n161"),
            page(2, "本文3\n\nPART II  \n組織のなかの人間心理  \n\n162"),
            page(3, "本文4\n\nCHAPTER 4  \nモチベーションの迷宮への招待  \n\n163"),
            page(4, "本文5\n\n---\n\n**PART II  \n組織のなかの人間心理**\n\n164"),
            page(5, "本文6\n\nCHAPTER 4  \nモチベーションの迷宮への招待  \n\n165")
        ]
        let preview = ExportService.combinedPreviewMarkdown(pages: pages)

        XCTAssertEqual(preview.components(separatedBy: "PART II").count - 1, 1)
        XCTAssertEqual(
            preview.components(separatedBy: "モチベーションの迷宮への招待").count - 1,
            1
        )
        for index in 1...6 {
            XCTAssertTrue(preview.contains("本文\(index)"))
        }
        XCTAssertFalse(preview.contains("160"))
        XCTAssertFalse(preview.contains("165"))
    }

    func testPreviewThinsThreeConsecutiveFooters() {
        let pages = [
            page(0, "本文1\n\n共通フッター"),
            page(1, "本文2\n\n共通フッター"),
            page(2, "本文3\n\n共通フッター")
        ]
        let preview = ExportService.combinedPreviewMarkdown(pages: pages)
        XCTAssertEqual(preview.components(separatedBy: "共通フッター").count - 1, 1)
    }

    func testPreviewKeepsRepeatedTextInTheBody() {
        let pages = [
            page(0, "固有1\n\n同じ本文\n\n末尾1"),
            page(1, "固有2\n\n同じ本文\n\n末尾2"),
            page(2, "固有3\n\n同じ本文\n\n末尾3")
        ]
        let preview = ExportService.combinedPreviewMarkdown(pages: pages)
        XCTAssertEqual(preview.components(separatedBy: "同じ本文").count - 1, 3)
    }

    func testPreviewThinsAlternatingFooterInLongDocument() {
        // A chapter footer that appears every other page (22 of 105 pages in
        // the real document) is not a consecutive run, so the occurrence
        // threshold has to catch it.
        let pages = (0..<40).map { index in
            if index.isMultiple(of: 2) {
                return page(index, "本文\(index)\n\nCHAPTER 4  \n交互フッター  \n\n\(index + 1)")
            }
            return page(index, "本文\(index)\n\n別の本文\(index)")
        }
        let preview = ExportService.combinedPreviewMarkdown(pages: pages)
        XCTAssertEqual(preview.components(separatedBy: "交互フッター").count - 1, 1)
        for index in 0..<40 {
            XCTAssertTrue(preview.contains("本文\(index)"))
        }
    }

    private func page(_ index: Int, _ markdown: String) -> PageRecord {
        PageRecord(
            id: "p\(index)",
            index: index,
            imagePath: "/tmp/\(index).png",
            processedPath: nil,
            width: 100,
            height: 100,
            ocrState: .done,
            result: StoredResult(
                id: "r\(index)",
                markdown: markdown,
                raw: markdown,
                text: markdown,
                preset: "high",
                stats: .empty,
                figures: [],
                warnings: [],
                createdAt: 0
            )
        )
    }
}
