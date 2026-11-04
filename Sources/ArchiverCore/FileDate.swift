import Foundation
import PDFKit

/// Datum einer Datei als Ersatz, wenn im Text kein Datum steht:
/// 1. Datum im Dateinamen („2025-12-11_Rechnung.pdf“, „20251211_…“, „11.12.2025 …“),
/// 2. Erstelldatum im PDF (vom erzeugenden Programm/Scanner eingetragen),
/// 3. Datum im Dateisystem (das frühere von Erstell- und Änderungsdatum).
public enum FileDate {
    public static func best(for url: URL, now: Date = Date()) -> (date: Date, source: DocumentMetadata.DateSource)? {
        if let date = fromFileName(url.lastPathComponent, now: now) { return (date, .fileName) }
        if url.pathExtension.lowercased() == "pdf", let date = pdfCreationDate(url), plausible(date, now: now) {
            return (date, .pdfCreation)
        }
        if let date = fileSystemDate(url), plausible(date, now: now) { return (date, .fileDate) }
        return nil
    }

    /// Datum im Dateinamen; Trennzeichen wie „_“ gelten als Leerzeichen.
    static func fromFileName(_ name: String, now: Date = Date()) -> Date? {
        let base = (name as NSString).deletingPathExtension.replacingOccurrences(of: "_", with: " ")
        if let date = DateExtractor.bestGuess(in: base, now: now) { return date }
        // kompakt: 20251211 (nicht Teil einer längeren Zahl)
        if let match = base.firstMatch(of: #/(?:^|\D)((?:19|20)\d{2})(\d{2})(\d{2})(?:\D|$)/#),
           let y = Int(match.1), let m = Int(match.2), let d = Int(match.3) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            if let date = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)),
               calendar.component(.day, from: date) == d, plausible(date, now: now) { return date }
        }
        return nil
    }

    static func pdfCreationDate(_ url: URL) -> Date? {
        PDFDocument(url: url)?.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date
    }

    static func fileSystemDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.min()
    }

    static func plausible(_ date: Date, now: Date) -> Bool {
        date >= Date(timeIntervalSince1970: 0) && date <= now.addingTimeInterval(86_400)
    }
}
