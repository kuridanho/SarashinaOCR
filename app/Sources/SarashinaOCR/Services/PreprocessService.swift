import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Image/PDF rasterization and document detection (spec FR-02, FR-03, FR-04).
enum PreprocessService {
    struct PageImage {
        var url: URL
        var width: Int
        var height: Int
    }

    static let maxPixels: CGFloat = 2_458_624
    static let pdfDPI: CGFloat = 200

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])

    // MARK: - Images

    /// Normalizes EXIF orientation, optionally detects the document quad, and
    /// writes a PNG capped at the high-quality preset resolution.
    static func prepareImage(
        source: URL,
        destination: URL,
        applyDocumentDetection: Bool
    ) throws -> PageImage {
        guard var image = CIImage(
            contentsOf: source,
            options: [.applyOrientationProperty: true, .colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]
        ) else {
            throw PreprocessError.unreadableImage(source.lastPathComponent)
        }

        if applyDocumentDetection, let corrected = detectAndCorrect(image) {
            image = corrected
        }
        image = downscaleIfNeeded(image)
        let extent = image.extent.integral
        guard let cgImage = ciContext.createCGImage(image, from: extent) else {
            throw PreprocessError.renderFailed(source.lastPathComponent)
        }
        try writePNG(cgImage, to: destination)
        return PageImage(url: destination, width: cgImage.width, height: cgImage.height)
    }

    static func detectDocument(in source: URL) -> CGRect? {
        guard let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        guard let observation = rectangleObservation(in: image) else { return nil }
        let extent = image.extent
        let rect = CGRect(
            x: observation.boundingBox.minX * extent.width + extent.minX,
            y: observation.boundingBox.minY * extent.height + extent.minY,
            width: observation.boundingBox.width * extent.width,
            height: observation.boundingBox.height * extent.height
        )
        return rect
    }

    /// Returns the detected document corners in top-left origin unit coordinates,
    /// ordered top-left, top-right, bottom-right, bottom-left.
    static func documentQuad(in source: URL) -> [CGPoint]? {
        guard let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]),
              let observation = rectangleObservation(in: image),
              observation.boundingBox.width * observation.boundingBox.height >= 0.15
        else { return nil }
        func unit(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x, y: 1 - point.y)
        }
        return [
            unit(observation.topLeft),
            unit(observation.topRight),
            unit(observation.bottomRight),
            unit(observation.bottomLeft)
        ]
    }

    /// Applies a perspective correction using top-left origin unit coordinates.
    static func correctPerspective(
        source: URL,
        destination: URL,
        quad: [CGPoint]
    ) throws -> PageImage {
        guard quad.count == 4,
              var image = CIImage(
                contentsOf: source,
                options: [.applyOrientationProperty: true]
              )
        else {
            throw PreprocessError.unreadableImage(source.lastPathComponent)
        }
        let extent = image.extent
        func vector(_ point: CGPoint) -> CIVector {
            CIVector(
                x: extent.minX + point.x * extent.width,
                y: extent.minY + (1 - point.y) * extent.height
            )
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            throw PreprocessError.renderFailed("台形補正")
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(vector(quad[0]), forKey: "inputTopLeft")
        filter.setValue(vector(quad[1]), forKey: "inputTopRight")
        filter.setValue(vector(quad[3]), forKey: "inputBottomLeft")
        filter.setValue(vector(quad[2]), forKey: "inputBottomRight")
        guard let output = filter.outputImage else {
            throw PreprocessError.renderFailed("台形補正")
        }
        image = downscaleIfNeeded(output)
        let outputExtent = image.extent.integral
        guard outputExtent.width > 1, outputExtent.height > 1,
              let cgImage = ciContext.createCGImage(image, from: outputExtent)
        else {
            throw PreprocessError.renderFailed("台形補正")
        }
        try writePNG(cgImage, to: destination)
        return PageImage(url: destination, width: cgImage.width, height: cgImage.height)
    }

    private static func detectAndCorrect(_ image: CIImage) -> CIImage? {
        guard let observation = rectangleObservation(in: image) else { return nil }
        // Reject tiny detections (e.g. a logo) which would destroy the page.
        if observation.boundingBox.width * observation.boundingBox.height < 0.15 { return nil }

        let extent = image.extent
        func convert(_ point: CGPoint) -> CIVector {
            CIVector(
                x: extent.minX + point.x * extent.width,
                y: extent.minY + point.y * extent.height
            )
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(convert(observation.topLeft), forKey: "inputTopLeft")
        filter.setValue(convert(observation.topRight), forKey: "inputTopRight")
        filter.setValue(convert(observation.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(convert(observation.bottomRight), forKey: "inputBottomRight")
        return filter.outputImage
    }

    private static func rectangleObservation(in image: CIImage) -> VNRectangleObservation? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.first
    }

    // MARK: - PDF

    static func pageCount(of url: URL) -> Int {
        PDFDocument(url: url)?.pageCount ?? 0
    }

    /// Rasterizes one PDF page without cropping, for re-editing a crop later.
    static func rasterizePDFPage(
        source: URL,
        index: Int,
        destination: URL
    ) throws -> PageImage {
        guard let document = PDFDocument(url: source),
              let page = document.page(at: index)
        else {
            throw PreprocessError.unreadablePDF(source.lastPathComponent)
        }
        let image = try render(page: page)
        try writePNG(image, to: destination)
        return PageImage(url: destination, width: image.width, height: image.height)
    }

    /// Rasterizes every page at 200dpi into `page-001.png`, `page-002.png`, ...
    static func rasterizePDF(source: URL, into directory: URL) throws -> [PageImage] {
        guard let document = PDFDocument(url: source) else {
            throw PreprocessError.unreadablePDF(source.lastPathComponent)
        }
        var pages: [PageImage] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let image = try render(page: page)
            let name = String(format: "page-%03d.png", index + 1)
            let destination = directory.appendingPathComponent(name)
            try writePNG(image, to: destination)
            pages.append(PageImage(url: destination, width: image.width, height: image.height))
        }
        return pages
    }

    private static func render(page: PDFPage) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let pageWidth = rotated ? bounds.height : bounds.width
        let pageHeight = rotated ? bounds.width : bounds.height
        let scale = pdfDPI / 72.0

        var width = Int(pageWidth * scale)
        var height = Int(pageHeight * scale)
        if CGFloat(width * height) > maxPixels {
            let factor = sqrt(maxPixels / CGFloat(width * height))
            width = max(1, Int(CGFloat(width) * factor))
            height = max(1, Int(CGFloat(height) * factor))
        }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw PreprocessError.renderFailed("PDF ページ")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.saveGState()
        // PDFPage draws in PDF coordinates (origin at bottom-left). A bitmap
        // context uses the same convention, so scaling is enough; flipping the
        // context here rotates every page by 180 degrees.
        context.scaleBy(x: CGFloat(width) / pageWidth, y: CGFloat(height) / pageHeight)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw PreprocessError.renderFailed("PDF ページ")
        }
        return image
    }

    // MARK: - Editing

    static func rotate(imageAt source: URL, quarterTurns: Int, destination: URL) throws -> PageImage {
        guard var image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
            throw PreprocessError.unreadableImage(source.lastPathComponent)
        }
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns != 0 {
            let orientation: CGImagePropertyOrientation = turns == 1 ? .right : turns == 2 ? .down : .left
            image = image.oriented(forExifOrientation: Int32(orientation.rawValue))
        }
        image = downscaleIfNeeded(image)
        let extent = image.extent.integral
        guard let cgImage = ciContext.createCGImage(image, from: extent) else {
            throw PreprocessError.renderFailed("回転")
        }
        try writePNG(cgImage, to: destination)
        return PageImage(url: destination, width: cgImage.width, height: cgImage.height)
    }

    /// Rotates a top-left origin quad 90 degrees clockwise.
    static func rotateQuadClockwise(_ quad: [CGPoint]) -> [CGPoint] {
        guard quad.count == 4 else { return quad }
        func rotated(_ point: CGPoint) -> CGPoint {
            CGPoint(x: 1 - point.y, y: point.x)
        }
        return [rotated(quad[3]), rotated(quad[0]), rotated(quad[1]), rotated(quad[2])]
    }

    // MARK: - Helpers

    private static func downscaleIfNeeded(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let pixels = extent.width * extent.height
        guard pixels > maxPixels else { return image }
        let factor = sqrt(maxPixels / pixels)
        return image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw PreprocessError.renderFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PreprocessError.renderFailed(url.lastPathComponent)
        }
    }

    enum PreprocessError: LocalizedError {
        case unreadableImage(String)
        case unreadablePDF(String)
        case renderFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadableImage(let name): return "画像を読み込めません: \(name)"
            case .unreadablePDF(let name): return "PDF を読み込めません: \(name)"
            case .renderFailed(let name): return "画像を書き出せません: \(name)"
            }
        }
    }
}
