import CoreGraphics
import Foundation

enum OCRPreset: String, CaseIterable, Codable, Identifiable {
    case high
    case standard
    case fast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: return "高精度"
        case .standard: return "標準"
        case .fast: return "高速"
        }
    }

    var maxPixels: Int {
        switch self {
        case .high: return 2_458_624
        case .standard: return 1_324_960
        case .fast: return 705_600
        }
    }

    /// Rough estimate shown in the status bar before inference.
    var estimatedSeconds: Int {
        switch self {
        case .high: return 90
        case .standard: return 55
        case .fast: return 30
        }
    }
}

struct WarningInfo: Codable, Hashable, Identifiable {
    var code: String
    var message: String
    var id: String { code + message }
}

struct FigureInfo: Codable, Hashable, Identifiable {
    var index: Int
    var bbox: [Double]
    var bboxPx: [Int]
    var path: String?
    var absolutePath: String?

    var id: Int { index }
}

struct OCRImageInfo: Codable, Hashable {
    var width: Int
    var height: Int
    var originalWidth: Int
    var originalHeight: Int
    var visualTokens: Int

    static let empty = OCRImageInfo(
        width: 0, height: 0, originalWidth: 0, originalHeight: 0, visualTokens: 0
    )
}

struct OCRStats: Codable, Hashable {
    var promptTokens: Int? = nil
    var outputTokens: Int? = nil
    var seconds: Double? = nil
    var prefillSeconds: Double? = nil
    var decodeSeconds: Double? = nil
    var tokPerSec: Double? = nil
    var peakMemoryMb: Double? = nil
    var truncated: Bool? = nil
    var eosReached: Bool? = nil
    var postprocessSeconds: Double? = nil
    var preset: String? = nil
    var maxNewTokens: Int? = nil
    var maxPixels: Int? = nil
    var modelRevision: String? = nil

    static let empty = OCRStats()
}

struct EngineOCRResult: Codable, Hashable {
    var raw: String
    var markdown: String
    var text: String
    var figures: [FigureInfo]
    var warnings: [WarningInfo]
    var cancelled: Bool
    var image: OCRImageInfo
    var stats: OCRStats

    static let cancelledEmpty = EngineOCRResult(
        raw: "",
        markdown: "",
        text: "",
        figures: [],
        warnings: [WarningInfo(code: "W4001", message: "生成を中断しました")],
        cancelled: true,
        image: .empty,
        stats: .empty
    )
}

struct EngineErrorPayload: Codable, Error, LocalizedError {
    var code: String
    var message: String
    var recoverable: Bool?

    var errorDescription: String? { "\(code): \(message)" }
}

struct StoredResult: Codable, Hashable, Identifiable {
    var id: String
    var markdown: String
    var raw: String
    var text: String
    var preset: String
    var stats: OCRStats
    var figures: [FigureInfo]
    var warnings: [WarningInfo]
    var createdAt: Double

    var outputTokens: Int { stats.outputTokens ?? 0 }
    var seconds: Double { stats.seconds ?? 0 }
    var tokPerSec: Double { stats.tokPerSec ?? 0 }
}

enum PageOCRState: String, Codable {
    case pending
    case running
    case done
    case failed
}

struct PageRecord: Identifiable, Codable, Hashable {
    var id: String
    var index: Int
    var imagePath: String
    var processedPath: String?
    /// Uncropped page image used when the crop is edited again later.
    var cropBasePath: String? = nil
    /// Current crop in top-left origin unit coordinates.
    var cropQuad: [CGPoint]? = nil
    var width: Int
    var height: Int
    var ocrState: PageOCRState
    var result: StoredResult?

    var displayPath: String { processedPath ?? imagePath }
}

struct DocumentRecord: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var kind: String
    var sourcePath: String
    var pageCount: Int
    var createdAt: Double
    var updatedAt: Double
    var pages: [PageRecord]

    var hasResults: Bool { pages.contains { $0.result != nil } }
    var completedPages: Int { pages.filter { $0.result != nil }.count }

    func page(at index: Int) -> PageRecord? {
        guard index >= 0, index < pages.count else { return nil }
        return pages[index]
    }
}

struct EngineHello: Codable {
    var protocolVersion: Int?
    var engine: String?
    var backend: String?
    var device: String?
    var memoryGb: Double?
    var state: String?
    var model: EngineModelState?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case engine, backend, device, memoryGb, state, model
    }
}

struct EngineModelState: Codable {
    var present: Bool?
    var path: String?
    var revision: String?
    var state: String?
}

struct EngineFrame: Decodable {
    var v: Int?
    var id: String
    var event: String
    var data: JSONValue
}

enum EngineClientError: LocalizedError {
    case notRunning
    case writeFailed(String)
    case engine(EngineErrorPayload)
    case terminated(String)
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "推論エンジンが起動していません"
        case .writeFailed(let message):
            return "推論エンジンへ送信できません: \(message)"
        case .engine(let payload):
            return "\(payload.code): \(payload.message)"
        case .terminated(let message):
            return "推論エンジンが終了しました: \(message)"
        case .protocolError(let message):
            return "エンジンの応答を解析できません: \(message)"
        }
    }
}
