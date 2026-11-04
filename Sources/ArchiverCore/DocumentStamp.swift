import Foundation
import PDFKit

/// Der rote Nummernstempel („Nr. 000123 · 19.09.2026“) steht **nicht** in der Archivdatei.
/// Er entsteht aus den Metadaten (Nummer, Dokumentdatum) erst beim Anzeigen, Drucken und
/// Kopieren mit Nummer – ein über „Bearbeiten“ geändertes Datum erscheint so sofort im Stempel.
public enum DocumentStamp {
    /// Stempeltext für ein Dokument.
    public static func text(for meta: DocumentMetadata) -> String {
        PDFBuilder.stampText(number: meta.number, date: meta.documentDate)
    }

    /// Geteilter Delegate (PDFDocument hält ihn nur schwach); liefert Seiten, die den Stempel zeichnen.
    private static let delegate = StampDelegate()

    /// PDF zum Anzeigen/Drucken mit Stempel auf Seite 1. Ohne Archiver-Metadaten ohne Stempel.
    public static func document(url: URL) -> PDFDocument? {
        stamped(PDFDocument(url: url), meta: PDFMetadata.read(url: url))
    }

    public static func document(data: Data) -> PDFDocument? {
        stamped(PDFDocument(data: data), meta: PDFDocument(data: data).flatMap(PDFMetadata.read))
    }

    /// Der Delegate muss stehen, bevor die erste Seite geladen wird – deshalb kommen die Metadaten
    /// aus einem eigenen Dokument.
    private static func stamped(_ pdf: PDFDocument?, meta: DocumentMetadata?) -> PDFDocument? {
        guard let pdf, let meta else { return pdf }
        pdf.delegate = delegate
        (pdf.page(at: 0) as? StampPage)?.stampText = text(for: meta)
        return pdf
    }

    /// Dateiinhalt für eine Kopie: ohne Nummer unverändert, mit Nummer mit angehängtem Stempel
    /// (inkrementell, das Archiv-PDF bleibt Präfix; Ausweichweg: über PDFKit neu geschrieben).
    public static func copyData(url: URL, withNumber: Bool) throws -> Data {
        let data = try Data(contentsOf: url)
        guard withNumber, let meta = PDFDocument(data: data).flatMap(PDFMetadata.read) else { return data }
        let stampText = text(for: meta)
        if let appended = try? PDFAppender.addStamp(data, stampText: stampText), isValid(appended, stampText: stampText, like: data) {
            return appended
        }
        if let rewritten = document(data: data)?.dataRepresentation(), isValid(rewritten, stampText: stampText, like: data) {
            return rewritten
        }
        throw ArchiveError.cannotWrite(url)
    }

    static func isValid(_ result: Data, stampText: String, like original: Data) -> Bool {
        guard let check = PDFDocument(data: result), let source = PDFDocument(data: original),
              check.pageCount == source.pageCount else { return false }
        return check.page(at: 0)?.string?.contains(stampText) == true
    }
}
