import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite persistence for documents, pages, results, and figures (spec 8.5).
final class DocumentStore {
    enum StoreError: LocalizedError {
        case open(String)
        case sqlite(String)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .open(let message): return "データベースを開けません: \(message)"
            case .sqlite(let message): return "データベースエラー: \(message)"
            case .decode(let message): return "保存データを復元できません: \(message)"
            }
        }
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "jp.sarashina.ocr.documentstore")

    init(url: URL = AppPaths.databaseURL) throws {
        try AppPaths.ensureDirectories()
        if sqlite3_open_v2(
            url.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw StoreError.open(message)
        }
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try createSchema()
    }

    deinit {
        sqlite3_close(db)
    }

    private func createSchema() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS documents(
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            kind TEXT NOT NULL,
            source_path TEXT NOT NULL,
            page_count INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS pages(
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            idx INTEGER NOT NULL,
            image_path TEXT NOT NULL,
            processed_path TEXT,
            crop_base_path TEXT,
            crop_json TEXT,
            width INTEGER NOT NULL DEFAULT 0,
            height INTEGER NOT NULL DEFAULT 0,
            bbox_json TEXT,
            ocr_state TEXT NOT NULL DEFAULT 'pending',
            updated_at REAL NOT NULL,
            UNIQUE(document_id, idx)
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS results(
            id TEXT PRIMARY KEY,
            page_id TEXT NOT NULL,
            markdown TEXT NOT NULL,
            raw TEXT NOT NULL,
            text TEXT,
            preset TEXT,
            model_revision TEXT,
            prompt_tokens INTEGER,
            output_tokens INTEGER,
            seconds REAL,
            truncated INTEGER DEFAULT 0,
            created_at REAL NOT NULL,
            stats_json TEXT,
            warnings_json TEXT,
            figures_json TEXT
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS figures(
            id TEXT PRIMARY KEY,
            result_id TEXT NOT NULL,
            idx INTEGER NOT NULL,
            bbox_json TEXT,
            image_path TEXT,
            caption TEXT
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS pages_document ON pages(document_id, idx);")
        try execute("CREATE INDEX IF NOT EXISTS results_page ON results(page_id, created_at);")
        try addColumnIfNeeded(table: "pages", column: "crop_base_path", type: "TEXT")
        try addColumnIfNeeded(table: "pages", column: "crop_json", type: "TEXT")
    }

    /// Adds a column to an existing database without disturbing saved documents.
    private func addColumnIfNeeded(table: String, column: String, type: String) throws {
        let statement = try prepare("PRAGMA table_info(\(table));")
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column {
                exists = true
                break
            }
        }
        sqlite3_finalize(statement)
        guard !exists else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(type);")
    }

    // MARK: - Public API

    func save(_ document: DocumentRecord) throws {
        try queue.sync {
            try execute("BEGIN IMMEDIATE;")
            do {
                try upsertDocument(document)
                for page in document.pages {
                    try upsertPage(page, documentID: document.id)
                    if let result = page.result {
                        try upsertResult(result, pageID: page.id)
                    }
                }
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    func loadDocuments(limit: Int = 200) throws -> [DocumentRecord] {
        try queue.sync {
            let sql = """
            SELECT id, title, kind, source_path, page_count, created_at, updated_at
            FROM documents ORDER BY updated_at DESC LIMIT ?;
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            var documents: [DocumentRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = text(statement, 0)
                documents.append(
                    DocumentRecord(
                        id: id,
                        title: text(statement, 1),
                        kind: text(statement, 2),
                        sourcePath: text(statement, 3),
                        pageCount: Int(sqlite3_column_int(statement, 4)),
                        createdAt: sqlite3_column_double(statement, 5),
                        updatedAt: sqlite3_column_double(statement, 6),
                        pages: try loadPages(documentID: id)
                    )
                )
            }
            return documents
        }
    }

    func deleteResult(pageID: String) throws {
        try queue.sync {
            try execute("BEGIN IMMEDIATE;")
            do {
                for sql in [
                    "DELETE FROM figures WHERE result_id IN (SELECT id FROM results WHERE page_id = ?);",
                    "DELETE FROM results WHERE page_id = ?;"
                ] {
                    let statement = try prepare(sql)
                    sqlite3_bind_text(statement, 1, pageID, -1, SQLITE_TRANSIENT)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        sqlite3_finalize(statement)
                        throw StoreError.sqlite(lastError)
                    }
                    sqlite3_finalize(statement)
                }
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    func delete(documentID: String) throws {
        try queue.sync {
            try execute("BEGIN IMMEDIATE;")
            do {
                for (sql, index) in [
                    ("DELETE FROM results WHERE page_id IN (SELECT id FROM pages WHERE document_id = ?);", 1),
                    ("DELETE FROM figures WHERE result_id NOT IN (SELECT id FROM results);", 0),
                    ("DELETE FROM pages WHERE document_id = ?;", 1),
                    ("DELETE FROM documents WHERE id = ?;", 1)
                ] {
                    let statement = try prepare(sql)
                    if index == 1 {
                        sqlite3_bind_text(statement, 1, documentID, -1, SQLITE_TRANSIENT)
                    }
                    if sqlite3_step(statement) != SQLITE_DONE {
                        sqlite3_finalize(statement)
                        throw StoreError.sqlite(lastError)
                    }
                    sqlite3_finalize(statement)
                }
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    // MARK: - Writes

    private func upsertDocument(_ document: DocumentRecord) throws {
        let statement = try prepare("""
        INSERT INTO documents(id, title, kind, source_path, page_count, created_at, updated_at)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title, kind=excluded.kind, source_path=excluded.source_path,
            page_count=excluded.page_count, updated_at=excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, document.id)
        bind(statement, 2, document.title)
        bind(statement, 3, document.kind)
        bind(statement, 4, document.sourcePath)
        sqlite3_bind_int(statement, 5, Int32(document.pageCount))
        sqlite3_bind_double(statement, 6, document.createdAt)
        sqlite3_bind_double(statement, 7, document.updatedAt)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sqlite(lastError) }
    }

    private func upsertPage(_ page: PageRecord, documentID: String) throws {
        let statement = try prepare("""
        INSERT INTO pages(id, document_id, idx, image_path, processed_path,
                          crop_base_path, crop_json, width, height, ocr_state, updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            image_path=excluded.image_path, processed_path=excluded.processed_path,
            crop_base_path=excluded.crop_base_path, crop_json=excluded.crop_json,
            width=excluded.width, height=excluded.height, ocr_state=excluded.ocr_state,
            updated_at=excluded.updated_at;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, page.id)
        bind(statement, 2, documentID)
        sqlite3_bind_int(statement, 3, Int32(page.index))
        bind(statement, 4, page.imagePath)
        bind(statement, 5, page.processedPath)
        bind(statement, 6, page.cropBasePath)
        bind(statement, 7, try page.cropQuad.map(encode))
        sqlite3_bind_int(statement, 8, Int32(page.width))
        sqlite3_bind_int(statement, 9, Int32(page.height))
        bind(statement, 10, page.ocrState.rawValue)
        sqlite3_bind_double(statement, 11, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sqlite(lastError) }
    }

    private func upsertResult(_ result: StoredResult, pageID: String) throws {
        let stats = try encode(result.stats)
        let warnings = try encode(result.warnings)
        let figures = try encode(result.figures)
        let statement = try prepare("""
        INSERT INTO results(id, page_id, markdown, raw, text, preset, model_revision,
                            prompt_tokens, output_tokens, seconds, truncated, created_at,
                            stats_json, warnings_json, figures_json)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            markdown=excluded.markdown, raw=excluded.raw, text=excluded.text,
            stats_json=excluded.stats_json, warnings_json=excluded.warnings_json,
            figures_json=excluded.figures_json, created_at=excluded.created_at;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, result.id)
        bind(statement, 2, pageID)
        bind(statement, 3, result.markdown)
        bind(statement, 4, result.raw)
        bind(statement, 5, result.text)
        bind(statement, 6, result.preset)
        bind(statement, 7, result.stats.modelRevision)
        sqlite3_bind_int(statement, 8, Int32(result.stats.promptTokens ?? 0))
        sqlite3_bind_int(statement, 9, Int32(result.stats.outputTokens ?? 0))
        sqlite3_bind_double(statement, 10, result.stats.seconds ?? 0)
        sqlite3_bind_int(statement, 11, (result.stats.truncated ?? false) ? 1 : 0)
        sqlite3_bind_double(statement, 12, result.createdAt)
        bind(statement, 13, stats)
        bind(statement, 14, warnings)
        bind(statement, 15, figures)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.sqlite(lastError) }

        let deleteFigures = try prepare("DELETE FROM figures WHERE result_id = ?;")
        bind(deleteFigures, 1, result.id)
        sqlite3_step(deleteFigures)
        sqlite3_finalize(deleteFigures)

        for figure in result.figures {
            let insert = try prepare("""
            INSERT INTO figures(id, result_id, idx, bbox_json, image_path, caption)
            VALUES(?,?,?,?,?,?);
            """)
            bind(insert, 1, "\(result.id)-fig-\(figure.index)")
            bind(insert, 2, result.id)
            sqlite3_bind_int(insert, 3, Int32(figure.index))
            bind(insert, 4, try encode(figure.bbox))
            bind(insert, 5, figure.absolutePath ?? figure.path)
            bind(insert, 6, "図\(figure.index)")
            sqlite3_step(insert)
            sqlite3_finalize(insert)
        }
    }

    // MARK: - Reads

    private func loadPages(documentID: String) throws -> [PageRecord] {
        let statement = try prepare("""
        SELECT id, idx, image_path, processed_path, crop_base_path, crop_json,
               width, height, ocr_state
        FROM pages WHERE document_id = ? ORDER BY idx;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, documentID)
        let decoder = JSONDecoder()
        var pages: [PageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let pageID = text(statement, 0)
            pages.append(
                PageRecord(
                    id: pageID,
                    index: Int(sqlite3_column_int(statement, 1)),
                    imagePath: text(statement, 2),
                    processedPath: optionalText(statement, 3),
                    cropBasePath: optionalText(statement, 4),
                    cropQuad: decode(
                        [CGPoint].self,
                        from: optionalText(statement, 5),
                        decoder: decoder
                    ),
                    width: Int(sqlite3_column_int(statement, 6)),
                    height: Int(sqlite3_column_int(statement, 7)),
                    ocrState: PageOCRState(rawValue: text(statement, 8)) ?? .pending,
                    result: try loadResult(pageID: pageID)
                )
            )
        }
        return pages
    }

    private func loadResult(pageID: String) throws -> StoredResult? {
        let statement = try prepare("""
        SELECT id, markdown, raw, text, preset, created_at, stats_json, warnings_json, figures_json
        FROM results WHERE page_id = ? ORDER BY created_at DESC LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, pageID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let decoder = JSONDecoder()
        let stats = decode(OCRStats.self, from: optionalText(statement, 6), decoder: decoder) ?? .empty
        let warnings = decode([WarningInfo].self, from: optionalText(statement, 7), decoder: decoder) ?? []
        let figures = decode([FigureInfo].self, from: optionalText(statement, 8), decoder: decoder) ?? []
        return StoredResult(
            id: text(statement, 0),
            markdown: text(statement, 1),
            raw: text(statement, 2),
            text: optionalText(statement, 3) ?? "",
            preset: optionalText(statement, 4) ?? "high",
            stats: stats,
            figures: figures,
            warnings: warnings,
            createdAt: sqlite3_column_double(statement, 5)
        )
    }

    // MARK: - SQLite helpers

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    private func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorPointer) != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? lastError
            sqlite3_free(errorPointer)
            throw StoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw StoreError.sqlite(lastError)
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        optionalText(statement, column) ?? ""
    }

    private func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: pointer)
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decode<T: Decodable>(
        _ type: T.Type, from string: String?, decoder: JSONDecoder
    ) -> T? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
