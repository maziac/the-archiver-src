import Foundation
import PDFKit

public enum ArchiveError: LocalizedError {
    case cannotCreateFolder(URL, Error)
    case unreadablePDF(URL)
    case cannotWrite(URL)

    public var errorDescription: String? {
        switch self {
        case let .cannotCreateFolder(url, error):
            return "Archivordner \(url.path) kann nicht angelegt werden: \(error.localizedDescription)"
        case let .unreadablePDF(url):
            return "\(url.lastPathComponent) ist kein lesbares PDF."
        case let .cannotWrite(url):
            return "\(url.lastPathComponent) konnte nicht gespeichert werden."
        }
    }
}

/// Archivordner mit fortlaufender, eindeutiger Dokumentnummer.
///
/// Dateiname: `JJJJ-MM-TT_NNNNNN[_Titel].pdf`. Der Zählerstand liegt in `counter.json` im Archivordner;
/// maßgeblich ist immer das Maximum aus Zähler und höchster Nummer vorhandener Dateien,
/// damit keine Nummer doppelt vergeben wird.
public final class Archive: @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()
    private var counterURL: URL { folder.appendingPathComponent("counter.json") }

    public init(folder: URL) throws {
        self.folder = folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.cannotCreateFolder(folder, error)
        }
    }

    // MARK: Dateinamen

    public static func formatNumber(_ number: Int) -> String {
        String(format: "%06d", number)
    }

    public static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// `JJJJ-MM-TT_NNNNNN.pdf` bzw. mit Titel `JJJJ-MM-TT_NNNNNN_Titel-als-Slug.pdf`.
    public static func fileName(date: Date, number: Int, title: String = "") -> String {
        let slug = slug(title)
        return "\(formatDate(date))_\(formatNumber(number))\(slug.isEmpty ? "" : "_" + slug).pdf"
    }

    /// Dateinamen-tauglicher Titel: Umlaute bleiben, Sonderzeichen fliegen raus, Leerraum wird "-".
    public static func slug(_ title: String, maxLength: Int = 60) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|_.,;#%&{}$!'@+`=~^[]()")
            .union(.controlCharacters)
        let words = title.precomposedStringWithCanonicalMapping
            .components(separatedBy: forbidden).joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && $0 != "-" }
        var result = ""
        for word in words {
            let next = result.isEmpty ? word : result + "-" + word
            if next.count > maxLength { break }
            result = next
        }
        if result.isEmpty, let first = words.first { result = String(first.prefix(maxLength)) }
        return result
    }

    /// Liest Datum und Nummer aus einem Archiv-Dateinamen, sonst nil.
    public static func parse(fileName: String) -> (date: Date, number: Int)? {
        guard let match = fileName.wholeMatch(of: #/(\d{4}-\d{2}-\d{2})_(\d{6,})(?:_.+)?\.pdf/#),
              let number = Int(match.2) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: String(match.1)) else { return nil }
        return (date, number)
    }

    // MARK: Nummernvergabe

    public func highestExistingNumber() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { Archive.parse(fileName: $0)?.number }.max() ?? 0
    }

    private struct Counter: Codable { var lastNumber: Int }

    private func storedCounter() -> Int {
        guard let data = try? Data(contentsOf: counterURL),
              let counter = try? JSONDecoder().decode(Counter.self, from: data) else { return 0 }
        return counter.lastNumber
    }

    /// Die Nummer, die das nächste gespeicherte Dokument bekommt (ohne sie zu reservieren).
    public func peekNextNumber() -> Int {
        lock.lock(); defer { lock.unlock() }
        return max(storedCounter(), highestExistingNumber()) + 1
    }

    /// Vergibt die nächste Nummer, schreibt das PDF und aktualisiert den Zähler.
    /// `makePDF` erhält die vergebene Nummer, damit sie ins Dokument gestempelt werden kann.
    public func save(date: Date, title: String = "", makePDF: (Int) throws -> Data) throws -> (number: Int, url: URL) {
        lock.lock(); defer { lock.unlock() }
        let number = max(storedCounter(), highestExistingNumber()) + 1
        let url = folder.appendingPathComponent(Archive.fileName(date: date, number: number, title: title))
        let data = try makePDF(number)
        try data.write(to: url, options: .withoutOverwriting)
        let counter = try JSONEncoder().encode(Counter(lastNumber: number))
        try counter.write(to: counterURL, options: .atomic)
        return (number, url)
    }

    // MARK: Nachträgliche Bearbeitung

    /// Schreibt Datum, Titel und Beschreibung ins PDF (Standardfelder + ScanArchiv-Metadaten) und benennt
    /// Archivdateien passend um. `change` passt die übrigen Metadaten an (z. B. Probleme, Herkunft).
    /// Liefert die (ggf. neue) URL und die gespeicherten Metadaten. Fremde PDFs behalten ihren Namen.
    @discardableResult
    public func updateMetadata(url: URL, date: Date, title: String, summary: String,
                               change: (inout DocumentMetadata) -> Void = { _ in }) throws -> (url: URL, meta: DocumentMetadata?) {
        lock.lock(); defer { lock.unlock() }
        guard let pdf = PDFDocument(url: url) else { throw ArchiveError.unreadablePDF(url) }
        let parsed = Archive.parse(fileName: url.lastPathComponent)
        let newName = parsed.map { Archive.fileName(date: date, number: $0.number, title: title) } ?? url.lastPathComponent

        var meta = PDFMetadata.read(pdf) ?? parsed.map { _ in Archive.legacyMetadata(url: url, pdf: pdf, issues: []) }
        if var current = meta {
            current.documentDate = date
            change(&current)
            current.updatedWith = DocumentMetadata.appName
            try writeMetadata(current, title: title, summary: summary, pdf: pdf, url: url)
            meta = current
        } else {
            // fremdes PDF: nur Titel/Betreff (PDFKit)
            var attributes = pdf.documentAttributes ?? [:]
            attributes[PDFDocumentAttribute.titleAttribute] = title.isEmpty ? (newName as NSString).deletingPathExtension : title
            attributes[PDFDocumentAttribute.subjectAttribute] = summary
            pdf.documentAttributes = attributes
            try write(pdf, to: url)
        }

        guard newName != url.lastPathComponent else { return (url, meta) }
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: newURL)
        return (newURL, meta)
    }

    /// Altbestand (ohne ScanArchiv-Metadaten): Metadaten aus Dateiname, Titel, Dateidatum und alten
    /// Problem-Vermerken zusammensetzen und ins PDF schreiben.
    public func migrateLegacy(url: URL, issues: [DocumentIssue]) throws {
        lock.lock(); defer { lock.unlock() }
        guard let pdf = PDFDocument(url: url), PDFMetadata.read(pdf) == nil, Archive.parse(fileName: url.lastPathComponent) != nil
        else { return }
        let attributes = pdf.documentAttributes ?? [:]
        var title = attributes[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        if title.wholeMatch(of: #/\d{4}-\d{2}-\d{2}_\d{6,}/#) != nil { title = "" }
        var summary = attributes[PDFDocumentAttribute.subjectAttribute] as? String ?? ""
        if summary.hasPrefix("Nr. ") { summary = "" }
        try writeMetadata(Archive.legacyMetadata(url: url, pdf: pdf, issues: issues), title: title, summary: summary, pdf: pdf, url: url)
    }

    /// Korrigiert Altbestand, der mit einer früheren Fassung der Migration falsch beschriftet wurde
    /// (Erstellversion „ScanArchiv 1.0“, Textherkunft „eigener Text“). Liefert true, wenn geändert.
    @discardableResult
    public func repairLegacyMetadata(url: URL) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let pdf = PDFDocument(url: url), var meta = PDFMetadata.read(pdf),
              meta.source == .unknown, meta.app != DocumentMetadata.legacyAppName else { return false }
        meta.app = DocumentMetadata.legacyAppName
        meta.pages = meta.pages.map { $0 == .embedded ? .unknown : $0 }
        meta.updatedWith = DocumentMetadata.appName
        let attributes = pdf.documentAttributes ?? [:]
        try writeMetadata(meta, title: attributes[PDFDocumentAttribute.titleAttribute] as? String ?? "",
                          summary: attributes[PDFDocumentAttribute.subjectAttribute] as? String ?? "", pdf: pdf, url: url)
        return true
    }

    static func legacyMetadata(url: URL, pdf: PDFDocument, issues: [DocumentIssue]) -> DocumentMetadata {
        let parsed = Archive.parse(fileName: url.lastPathComponent)
        let attributes = pdf.documentAttributes ?? [:]
        let title = attributes[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        let hasTitle = !title.isEmpty && title.wholeMatch(of: #/\d{4}-\d{2}-\d{2}_\d{6,}/#) == nil
        let archivedAt = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date
            ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let pages = (0..<pdf.pageCount).map { i -> DocumentMetadata.TextSource in
            DocumentIssue.hasText(pdf.page(at: i)?.string ?? "") ? .unknown : .none
        }
        return DocumentMetadata(number: parsed?.number ?? 0, documentDate: parsed?.date ?? archivedAt, dateSource: .unknown,
                                titleSource: hasTitle ? .ai : .none, archivedAt: archivedAt, source: .unknown,
                                pages: pages, issues: issues, app: DocumentMetadata.legacyAppName, updatedWith: DocumentMetadata.appName)
    }

    /// Metadaten speichern: bevorzugt **angehängt** (inkrementelles Update, Original bleibt bitgenau),
    /// nur wenn das scheitert oder nicht lesbar ist, durch PDFKit neu geschrieben.
    private func writeMetadata(_ meta: DocumentMetadata, title: String, summary: String, pdf: PDFDocument, url: URL) throws {
        if let original = try? Data(contentsOf: url),
           let appended = try? PDFAppender.updateMetadata(original, meta: meta, title: title, summary: summary),
           let check = PDFDocument(data: appended), check.pageCount == pdf.pageCount, PDFMetadata.read(check) == meta {
            try write(appended, to: url)
            return
        }
        try PDFMetadata.apply(meta, title: title, summary: summary, to: pdf)
        try write(pdf, to: url)
    }

    private func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString).pdf")
        try data.write(to: temp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// Schreibt atomar über eine temporäre Datei im selben Ordner.
    private func write(_ pdf: PDFDocument, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString).pdf")
        guard pdf.write(to: temp) else { throw ArchiveError.cannotWrite(url) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
