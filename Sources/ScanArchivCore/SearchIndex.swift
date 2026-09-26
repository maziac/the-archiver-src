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
    /// Probleme bei der Verarbeitung (leer = alles in Ordnung)
    public var issues: [DocumentIssue] = []
    /// vollständige Metadaten aus dem PDF (nil bei fremden PDFs)
    public var meta: DocumentMetadata?
    /// Textausschnitt; Treffer sind mit \u{1}…\u{2} markiert.
    public var snippet: String = ""

    public var url: URL { URL(fileURLWithPath: path) }
    public var fileName: String { url.lastPathComponent }
    /// Titel oder, falls leer, der Dateiname
    public var displayTitle: String { title.isEmpty ? fileName : title }
    public var hasIssues: Bool { !issues.isEmpty }
    /// Kategorien aus den Metadaten (leer = keine oder noch nicht kategorisiert)
    public var categories: [String] { meta?.categories ?? [] }

    public static func == (a: DocumentRecord, b: DocumentRecord) -> Bool {
        a.path == b.path && a.number == b.number && a.date == b.date && a.title == b.title && a.summary == b.summary
            && a.issues == b.issues && a.snippet == b.snippet && a.meta == b.meta
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

public enum SearchIndexError: LocalizedError {
    case sqlite(String)
    public var errorDescription: String? {
        if case let .sqlite(message) = self { return "Suchindex: \(message)" }
        return nil
    }
}

/// Volltextindex (SQLite FTS5) über alle Archiv-PDFs. Reiner Cache: Alle Angaben stammen aus den PDFs
/// und lassen sich per `sync(full: true)` vollständig wiederherstellen.
public final class SearchIndex: @unchecked Sendable {
    public static let fileName = ".scanarchiv-index.sqlite"
    static let schemaVersion: Int32 = 5
    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Spalten in fester Reihenfolge (Indizes werden unten beim Lesen verwendet)
    private static let columns = "number, date, path, pages, issues, archivedAt, source, sha256, meta, originalName, title, summary, text, categories"
    private static let textColumn: Int32 = 12

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
                number, date UNINDEXED, path UNINDEXED, pages UNINDEXED, issues UNINDEXED,
                archivedAt UNINDEXED, source UNINDEXED, sha256 UNINDEXED, meta UNINDEXED,
                originalName, title, summary, text, categories,
                tokenize = 'unicode61 remove_diacritics 2')
            """)
        // Wörterbuch aller Begriffe – für Tag-Platzhalter am Wortanfang („*rente“)
        vocabularyAvailable = (try? exec("CREATE VIRTUAL TABLE IF NOT EXISTS docs_vocab USING fts5vocab(docs, row)")) != nil
    }

    /// false, wenn SQLite kein fts5vocab bietet (dann sind führende Platzhalter nicht möglich)
    public private(set) var vocabularyAvailable = false

    private func userVersion() throws -> Int32 {
        try query("PRAGMA user_version", []) { sqlite3_column_int($0, 0) }.first ?? 0
    }

    deinit { sqlite3_close(db) }

    // MARK: Schreiben

    public func add(number: Int, date: Date, url: URL, pages: Int, text: String, title: String = "", summary: String = "",
                    meta: DocumentMetadata? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try run("DELETE FROM docs WHERE path = ?", [url.path])
        try run("INSERT INTO docs(\(SearchIndex.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [SearchIndex.numberField(number), date.timeIntervalSince1970, url.path, pages,
                 DocumentIssue.encode(meta?.issues ?? []),
                 meta?.archivedAt.timeIntervalSince1970 ?? 0, meta?.source.rawValue ?? "", meta?.originalSHA256 ?? "",
                 (try? meta?.encoded()) ?? "", meta?.originalFileName ?? "",
                 title, summary, text, Categories.indexField(meta?.categories) ?? SQLNull()])
    }

    /// Nach Bearbeiten/Umbenennen: Pfad, Datum, Titel, Beschreibung und Metadaten aktualisieren.
    public func update(oldPath: String, newURL: URL, date: Date, title: String, summary: String,
                       meta: DocumentMetadata? = nil, text: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        try run("UPDATE docs SET path = ?, date = ?, title = ?, summary = ? WHERE path = ?",
                [newURL.path, date.timeIntervalSince1970, title, summary, oldPath])
        if let text { try run("UPDATE docs SET text = ? WHERE path = ?", [text, newURL.path]) }
        if let meta {
            try run("UPDATE docs SET meta = ?, issues = ?, categories = ? WHERE path = ?",
                    [(try? meta.encoded()) ?? "", DocumentIssue.encode(meta.issues),
                     Categories.indexField(meta.categories) ?? SQLNull(), newURL.path])
        }
    }

    public func remove(path: String) throws {
        lock.lock(); defer { lock.unlock() }
        try run("DELETE FROM docs WHERE path = ?", [path])
    }

    public func countWithIssues() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT count(*) FROM docs WHERE issues != ''", []) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    /// Bereits archiviertes Dokument mit derselben Prüfsumme der Originaldatei (Duplikaterkennung).
    public func record(forSHA256 sha: String) throws -> (number: Int, path: String)? {
        guard !sha.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT number, path FROM docs WHERE sha256 = ? LIMIT 1", [sha]) {
            (Int(SearchIndex.text($0, 0).split(separator: " ").first ?? "") ?? 0, SearchIndex.text($0, 1))
        }.first
    }

    /// "000123 123", damit auch Suchen ohne führende Nullen treffen.
    static func numberField(_ number: Int) -> String {
        "\(Archive.formatNumber(number)) \(number)"
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

    /// Nimmt ein vorhandenes PDF in den Index auf: Metadaten aus dem PDF, Text via PDFKit.
    public func addExisting(_ url: URL) throws {
        guard let pdf = PDFDocument(url: url) else { return }
        let meta = PDFMetadata.read(pdf)
        let parsed = Archive.parse(fileName: url.lastPathComponent)
        let date = meta?.documentDate ?? parsed?.date
            ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? Date()
        let attributes = pdf.documentAttributes ?? [:]
        var title = attributes[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        var summary = attributes[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
        // Platzhalter (Dateistamm als Titel, Stempeltext als Betreff) gelten als leer.
        if title.wholeMatch(of: #/\d{4}-\d{2}-\d{2}_\d{6,}/#) != nil { title = "" }
        if summary.hasPrefix("Nr. ") { summary = "" }
        try add(number: meta?.number ?? parsed?.number ?? 0, date: date, url: url, pages: pdf.pageCount,
                text: pdf.string ?? "", title: title, summary: summary, meta: meta)
    }

    /// Gleicht den Index mit dem Ordner ab: neue PDFs aufnehmen, gelöschte entfernen.
    /// Mit `full` wird alles neu eingelesen. `migrate` wird für Archiv-PDFs ohne ScanArchiv-Metadaten
    /// aufgerufen (Altbestand) und kann sie vor dem Einlesen ergänzen.
    public func sync(folder: URL, full: Bool = false, migrate: ((URL) -> Void)? = nil) throws {
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
            if let migrate, Archive.parse(fileName: url.lastPathComponent) != nil, PDFMetadata.read(url: url) == nil {
                migrate(url)
            }
            try addExisting(url)
        }
    }

    // MARK: Suchen

    // MARK: Tags

    /// FTS5-Ausdruck eines Tags (Platzhalter am Wortanfang über das Wörterbuch aufgelöst).
    /// Aufrufer hält den Lock.
    private func tagExpression(_ tagQuery: String) throws -> String {
        let node = try TagQuery.parse(tagQuery)
        return try TagQuery.fts(node) { pattern in
            guard vocabularyAvailable else {
                throw TagQuery.ParseError(message: "Platzhalter am Wortanfang werden hier nicht unterstützt – nur am Wortende (rente*)")
            }
            return try query("SELECT term FROM docs_vocab WHERE term LIKE ? ESCAPE '\\' ORDER BY term LIMIT 500", [pattern]) {
                SearchIndex.text($0, 0)
            }
        }
    }

    /// Anzahl der Dokumente, die ein Tag-Ausdruck trifft (wirft bei ungültigem Ausdruck).
    public func count(tagQuery: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let expression = try tagExpression(tagQuery)
        return try query("SELECT count(*) FROM docs WHERE docs MATCH ?", [expression]) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
    }

    /// Stichwortsuche: alle Wörter müssen vorkommen (UND), jeweils als Präfix.
    /// Dazu optional Tags (je ein Suchausdruck) und Kategorien (Pfade, auch Oberkategorien); alles wird UND-verknüpft.
    /// Leere Suche liefert alle Dokumente. Sortiert nach Nummer absteigend.
    /// `onlyIssues`: nur Dokumente mit Problemen.
    /// Markiert werden im Textausschnitt nur Wörter aus `query`, nie die der Tags.
    public func search(_ query: String, tagQueries: [String] = [], categories: [String] = [], onlyIssues: Bool = false,
                       limit: Int = 1000) throws -> [DocumentRecord] {
        lock.lock(); defer { lock.unlock() }
        let filter = SearchIndex.filter(onlyIssues: onlyIssues, categories: categories)
        if !tagQueries.isEmpty {
            return try searchWithTags(query, tagQueries: tagQueries, filter: filter, limit: limit)
        }
        let match = SearchIndex.matchExpression(for: query)
        let issueFilter = filter.sql
        let order = "ORDER BY CAST(substr(number, 1, instr(number, ' ') - 1) AS INTEGER) DESC, path LIMIT ?"
        let map: (OpaquePointer?) -> DocumentRecord = { stmt in
            SearchIndex.record(stmt, snippet: SearchIndex.text(stmt, 8).replacingOccurrences(of: "\n", with: " "))
        }
        let fields = SearchIndex.recordFields
        if let match {
            return try self.query("""
                SELECT \(fields), snippet(docs, \(SearchIndex.textColumn), char(1), char(2), '…', 16)
                FROM docs WHERE docs MATCH ? AND \(issueFilter) \(order)
                """, [match] + filter.params + [limit], map)
        }
        return try self.query("""
            SELECT \(fields), substr(text, 1, 160) FROM docs WHERE \(issueFilter) \(order)
            """, filter.params + [limit], map)
    }

    /// Suche mit Tags: Textausschnitt in Swift, damit Tag-Wörter nicht markiert werden. Aufrufer hält den Lock.
    private func searchWithTags(_ query: String, tagQueries: [String], filter: (sql: String, params: [Any]),
                                limit: Int) throws -> [DocumentRecord] {
        let match = try fullMatch(query, tagQueries: tagQueries)!
        let issueFilter = filter.sql
        let words = SearchIndex.words(in: query)
        return try self.query("""
            SELECT \(SearchIndex.recordFields), text
            FROM docs WHERE docs MATCH ? AND \(issueFilter)
            ORDER BY CAST(substr(number, 1, instr(number, ' ') - 1) AS INTEGER) DESC, path LIMIT ?
            """, [match] + filter.params + [limit]) { stmt in
            SearchIndex.record(stmt, snippet: SearchIndex.snippet(SearchIndex.text(stmt, 8), highlighting: words))
        }
    }

    /// Ein Dokument des Index (ohne Textausschnitt).
    public func record(path: String) throws -> DocumentRecord? {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT \(SearchIndex.recordFields) FROM docs WHERE path = ?", [path]) {
            SearchIndex.record($0, snippet: "")
        }.first
    }

    /// Spalten für `record(_:snippet:)`, in dieser Reihenfolge
    private static let recordFields = "number, date, path, pages, issues, title, summary, meta"

    private static func record(_ stmt: OpaquePointer?, snippet: String) -> DocumentRecord {
        DocumentRecord(
            number: Int(text(stmt, 0).split(separator: " ").first ?? "") ?? 0,
            date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            path: text(stmt, 2),
            pages: Int(sqlite3_column_int(stmt, 3)),
            title: text(stmt, 5),
            summary: text(stmt, 6),
            issues: DocumentIssue.decode(text(stmt, 4)),
            meta: DocumentMetadata.decode(text(stmt, 7)),
            snippet: snippet)
    }

    /// Filter für Probleme und Kategorien (SQL-Bedingung + Parameter).
    static func filter(onlyIssues: Bool, categories: [String]) -> (sql: String, params: [Any]) {
        var conditions = [onlyIssues ? "issues != ''" : "1"]
        conditions += categories.map { _ in "instr(categories, ?) > 0" }
        return (conditions.joined(separator: " AND "), categories.map { "\n" + $0 + "\n" })
    }

    /// FTS-Ausdruck aus Suchfeld und Tags (nil = keine Einschränkung). Aufrufer hält den Lock.
    private func fullMatch(_ query: String, tagQueries: [String]) throws -> String? {
        var parts = try tagQueries.map { "(" + (try tagExpression($0)) + ")" }
        if let free = SearchIndex.matchExpression(for: query) { parts.append("(" + free + ")") }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    // MARK: Kategorien

    /// Trefferzahl je Kategorie (inkl. Oberkategorien) unter dem aktuellen Filter.
    public func categoryCounts(query: String = "", tagQueries: [String] = [], categories: [String] = [],
                               onlyIssues: Bool = false) throws -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let filter = SearchIndex.filter(onlyIssues: onlyIssues, categories: categories)
        let rows: [String]
        if let match = try fullMatch(query, tagQueries: tagQueries) {
            rows = try self.query("SELECT categories FROM docs WHERE docs MATCH ? AND categories != '' AND \(filter.sql)",
                                  [match] + filter.params) { SearchIndex.text($0, 0) }
        } else {
            rows = try self.query("SELECT categories FROM docs WHERE categories != '' AND \(filter.sql)", filter.params) {
                SearchIndex.text($0, 0)
            }
        }
        var counts: [String: Int] = [:]
        for row in rows {
            for category in row.split(separator: "\n") { counts[String(category), default: 0] += 1 }
        }
        return counts
    }

    /// Alle im Archiv vergebenen Kategorien (ohne reine Oberkategorien), sortiert.
    public func allCategories() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        var all = Set<String>()
        for meta in try query("SELECT meta FROM docs WHERE categories != ''", [], { SearchIndex.text($0, 0) }) {
            all.formUnion(DocumentMetadata.decode(meta)?.categories ?? [])
        }
        return all.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Dokumente, die eine Kategorie (oder eine ihrer Unterkategorien) tragen.
    public func records(inCategory category: String) throws -> [DocumentRecord] {
        try search("", categories: [category], limit: 1_000_000)
    }

    /// Dokumente mit ScanArchiv-Metadaten, die noch nicht kategorisiert wurden, samt Volltext.
    public func recordsWithoutCategories() throws -> [(path: String, text: String)] {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT path, text FROM docs WHERE categories IS NULL AND meta != '' ORDER BY path", []) {
            (SearchIndex.text($0, 0), SearchIndex.text($0, 1))
        }
    }

    public func countWithoutCategories() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try query("SELECT count(*) FROM docs WHERE categories IS NULL AND meta != ''", []) {
            Int(sqlite3_column_int($0, 0))
        }.first ?? 0
    }

    static func words(in query: String) -> [String] {
        query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Textausschnitt um die erste Fundstelle eines Suchfeld-Wortes (Wortanfang, ohne Beachtung von
    /// Groß-/Kleinschreibung und Akzenten); Treffer mit \u{1}…\u{2} markiert. Ohne Wörter: Textanfang.
    static func snippet(_ text: String, highlighting words: [String], before: Int = 60, after: Int = 110) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard !words.isEmpty else { return String(flat.prefix(160)) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        var firstHit: Range<String.Index>?
        for word in words {
            var searchStart = flat.startIndex
            while let range = flat.range(of: word, options: options, range: searchStart..<flat.endIndex) {
                // nur am Wortanfang (wie die Suche)
                if range.lowerBound == flat.startIndex || !flat[flat.index(before: range.lowerBound)].isLetter {
                    if firstHit == nil || range.lowerBound < firstHit!.lowerBound { firstHit = range }
                    break
                }
                searchStart = range.upperBound
            }
        }
        guard let hit = firstHit else { return String(flat.prefix(160)) }
        let start = flat.index(hit.lowerBound, offsetBy: -before, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(hit.upperBound, offsetBy: after, limitedBy: flat.endIndex) ?? flat.endIndex
        var result = start > flat.startIndex ? "…" : ""
        result += flat[start..<hit.lowerBound]
        // ganzes Wort markieren
        var wordEnd = hit.upperBound
        while wordEnd < end, flat[wordEnd].isLetter || flat[wordEnd].isNumber { wordEnd = flat.index(after: wordEnd) }
        result += "\u{1}" + flat[hit.lowerBound..<wordEnd] + "\u{2}" + flat[wordEnd..<end]
        if end < flat.endIndex { result += "…" }
        return result
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
            case is SQLNull: sqlite3_bind_null(stmt, idx)
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

    /// Parameter für SQL-NULL
    private struct SQLNull {}

    private static func text(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }
}
