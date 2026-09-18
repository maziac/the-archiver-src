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

    /// Schreibt Titel/Beschreibung in die PDF-Metadaten und benennt Archivdateien passend zu
    /// Datum und Titel um. Liefert die (ggf. neue) URL. Fremde PDFs behalten ihren Namen.
    public func updateMetadata(url: URL, date: Date, title: String, summary: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let pdf = PDFDocument(url: url) else { throw ArchiveError.unreadablePDF(url) }
        let parsed = Archive.parse(fileName: url.lastPathComponent)
        let newName = parsed.map { Archive.fileName(date: date, number: $0.number, title: title) } ?? url.lastPathComponent

        var attributes = pdf.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title.isEmpty ? (newName as NSString).deletingPathExtension : title
        attributes[PDFDocumentAttribute.subjectAttribute] = summary
        pdf.documentAttributes = attributes

        let temp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString).pdf")
        guard pdf.write(to: temp) else { throw ArchiveError.cannotWrite(url) }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)

        guard newName != url.lastPathComponent else { return url }
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: newURL)
        return newURL
    }
}
