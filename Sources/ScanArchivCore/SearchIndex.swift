import Foundation
import PDFKit
import SQLite3

public struct DocumentRecord: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var number: Int
    public var date: Date
    public var path: String
    public var pages: Int
    public var title: String
    public var summary: String
    /// Textausschnitt; Treffer sind mit \u{1}…\u{2} markiert.
    public var snippet: String

    public var url: URL { URL(fileURLWithPath: path) }
    public var fileName: String { url.lastPathComponent }
    /// Titel oder, falls leer, der Dateiname
    public var displayTitle: String { title.isEmpty ? fileName : title }
}

public enum SearchIndexError: LocalizedError {
    case sqlite(String)
    public var errorDescription: String? {
        if case let .sqlite(message) = self { return "Suchindex: \(message)" }
        return nil
    }
}

/// Volltextindex (SQLite FTS5) über alle Archiv-PDFs.
public final class SearchIndex: @unchecked Sendable {
    public static let fileName = ".scanarchiv-index.sqlite"
    static let schemaVersion: Int32 = 2
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            throw SearchIndexError.sqlite("Datenbank kann nicht geöffnet werden: \(url.path)")
        }
        // Der Index ist nur ein Cache: bei altem Schema neu anlegen, sync() füllt ihn wieder.
        if try userVersion() < SearchIndex.schemaVersion {
            try exec("DROP TABLE IF EXISTS docs")
            try exec("PRAGMA user_version = \(SearchIndex.schemaVersion)")
        }
        // number enthält "000123 123", damit auch Suchen ohne führende Nullen treffen.
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
                number, date UNINDEXED, path UNINDEXED, pages UNINDEXED, title, summary, text,
                tokenize = 'unicode61 remove_diacritics 2')
            """)
    }

    private func userVersion() throws -> Int32 {
        try query("PRAGMA user_version", []) { sqlite3_column_int($0, 0) }.first ?? 0
    }

    deinit { sqlite3_close(db) }

    // MARK: Schreiben

    public func add(number: Int, date: Date, url: URL, pages: Int, text: String, title: String = "", summary: String = "") throws {
        lock.lock(); defer { lock.unlock() }
        try run("DELETE FROM docs WHERE path = ?", [url.path])
        try run("INSERT INTO docs(number, date, path, pages, title, summary, text) VALUES (?, ?, ?, ?, ?, ?, ?)",
                ["\(Archive.formatNumber(number)) \(number)", date.timeIntervalSince1970, url.path, pages, title, summary, text])
    }

    /// Nach Bearbeiten/Umbenennen: Pfad, Datum, Titel und Beschreibung aktualisieren.
    public func update(oldPath: String, newURL: URL, date: Date, title: String, summary: String) throws {
        lock.lock(); defer { lock.unlock() }
        try run("UPDATE docs SET path = ?, date = ?, title = ?, summary = ? WHERE path = ?",
                [newURL.path, date.timeIntervalSince1970, title, summary, oldPath])
    }

    /// Dokumente ohne Titel samt Volltext – für das nachträgliche Erzeugen von Titeln.
    public func recordsWithoutTitle() throws -> [(path: String, text: String)] {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT path, text FROM docs WHERE title = '' ORDER BY path", []) {
            (SearchIndex.text($0, 0), SearchIndex.text($0, 1))
        }
    }

    public func countWithoutTitle() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT count(*) FROM docs WHERE title = ''", []) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    public func fullText(path: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT text FROM docs WHERE path = ?", [path]) { SearchIndex.text($0, 0) }.first ?? ""
    }

    /// Nimmt ein vorhandenes PDF (Text via PDFKit) in den Index auf.
    public func addExisting(_ url: URL) throws {
        guard let pdf = PDFDocument(url: url) else { return }
        let parsed = Archive.parse(fileName: url.lastPathComponent)
        let date = parsed?.date
            ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? Date()
        let attributes = pdf.documentAttributes ?? [:]
        var title = attributes[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        var summary = attributes[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
        // Platzhalter aus Version 1 (Dateistamm als Titel, Stempeltext als Betreff) gelten als leer.
        if title.wholeMatch(of: #/\d{4}-\d{2}-\d{2}_\d{6,}/#) != nil { title = "" }
        if summary.hasPrefix("Nr. ") { summary = "" }
        try add(number: parsed?.number ?? 0, date: date, url: url, pages: pdf.pageCount, text: pdf.string ?? "",
                title: title, summary: summary)
    }

    /// Gleicht den Index mit dem Ordner ab: neue PDFs aufnehmen, gelöschte entfernen.
    /// Mit `full` wird alles neu eingelesen.
    public func sync(folder: URL, full: Bool = false) throws {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "pdf" }
        let onDisk = Set(files.map(\.path))
        let indexed: Set<String> = try {
            lock.lock(); defer { lock.unlock() }
            if full { try exec("DELETE FROM docs"); return [] }
            return Set(try query("SELECT path FROM docs", []) { SearchIndex.text($0, 0) })
        }()
        for path in indexed.subtracting(onDisk) {
            lock.lock(); defer { lock.unlock() }
            try run("DELETE FROM docs WHERE path = ?", [path])
        }
        for url in files where !indexed.contains(url.path) {
            try addExisting(url)
        }
    }

    // MARK: Suchen

    /// Stichwortsuche: alle Wörter müssen vorkommen (UND), jeweils als Präfix.
    /// Leere Suche liefert alle Dokumente. Sortiert nach Nummer absteigend.
    public func search(_ query: String, limit: Int = 1000) throws -> [DocumentRecord] {
        lock.lock(); defer { lock.unlock() }
        let match = SearchIndex.matchExpression(for: query)
        let map: (OpaquePointer?) -> DocumentRecord = { stmt in
            let numberField = SearchIndex.text(stmt, 0)
            return DocumentRecord(
                number: Int(numberField.split(separator: " ").first ?? "") ?? 0,
                date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                path: SearchIndex.text(stmt, 2),
                pages: Int(sqlite3_column_int(stmt, 3)),
                title: SearchIndex.text(stmt, 4),
                summary: SearchIndex.text(stmt, 5),
                snippet: SearchIndex.text(stmt, 6)
                    .replacingOccurrences(of: "\n", with: " "))
        }
        if let match {
            return try self.query("""
                SELECT number, date, path, pages, title, summary, snippet(docs, 6, char(1), char(2), '…', 16)
                FROM docs WHERE docs MATCH ? ORDER BY CAST(substr(number, 1, instr(number, ' ') - 1) AS INTEGER) DESC, path LIMIT ?
                """, [match, limit], map)
        }
        return try self.query("""
            SELECT number, date, path, pages, title, summary, substr(text, 1, 160)
            FROM docs ORDER BY CAST(substr(number, 1, instr(number, ' ') - 1) AS INTEGER) DESC, path LIMIT ?
            """, [limit], map)
    }

    /// Baut aus der Nutzereingabe einen sicheren FTS5-Ausdruck, z. B. `"rechn"* "2024"*`.
    static func matchExpression(for query: String) -> String? {
        let tokens = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: SQLite-Helfer (Aufrufer hält den Lock)

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unbekannter Fehler"
            sqlite3_free(error)
            throw SearchIndexError.sqlite(message)
        }
    }

    private func prepare(_ sql: String, _ params: [Any]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SearchIndexError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        for (i, param) in params.enumerated() {
            let idx = Int32(i + 1)
            switch param {
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            default: sqlite3_bind_text(stmt, idx, "\(param)", -1, SearchIndex.transient)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ params: [Any]) throws {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SearchIndexError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(_ sql: String, _ params: [Any], _ map: (OpaquePointer?) -> T) throws -> [T] {
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { rows.append(map(stmt)); continue }
            if rc == SQLITE_DONE { break }
            throw SearchIndexError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return rows
    }

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }
}
