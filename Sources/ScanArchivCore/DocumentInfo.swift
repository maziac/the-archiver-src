import Foundation

/// Aufbereitung der Dokument-Informationen für ⓘ-Popover und Tooltip (beide zeigen dasselbe).
public enum DocumentInfo {
    public struct Line: Equatable, Sendable {
        public let label: String
        public let value: String
    }

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return f
    }()

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    public static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    public static func fileSize(of url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// Zeilen „Bezeichnung: Wert“; ohne ScanArchiv-Metadaten nur Seiten und Größe.
    public static func lines(meta: DocumentMetadata?, fileSize: Int?, pageCount: Int) -> [Line] {
        var lines: [Line] = []
        func add(_ label: String, _ value: String) { lines.append(Line(label: label, value: value)) }
        let sizeText = fileSize.map { size -> String in
            // Import: Vergleich mit dem Original, nur tatsächlich Hinzugefügtes nennen
            if let meta, let original = meta.originalSize, original > 0 {
                return "\(bytes(size)) (Original \(bytes(original)), \(sizeChange(size - original, meta: meta)))"
            }
            return bytes(size) + (pageCount > 0 ? " (≈ \(bytes(size / pageCount)) pro Seite)" : "")
        } ?? "–"

        guard let meta else {
            add("Seiten", "\(pageCount)")
            add("Dateigröße", sizeText)
            return lines
        }
        add("Quelle", sourceText(meta.source))
        if let name = meta.originalFileName {
            add("Originaldatei", name + (meta.originalSize.map { " (\(bytes($0)))" } ?? ""))
        }
        add("Archiviert", dateTime.string(from: meta.archivedAt))
        add("Dokumentdatum", "\(date.string(from: meta.documentDate)) (\(dateSourceText(meta.dateSource)))")
        add("Titel/Beschreibung", titleText(meta))
        if let scan = meta.scan {
            add("Scan", "\(scan.scanner ?? "Scanner"), \(scan.dpi) dpi, \(scan.colorMode == .original ? "Farbe" : scan.colorMode.label)")
        }
        if let storage = meta.storage { add("Speicherung", storageText(storage)) }
        add("Kompression", compressionText(meta))
        add("Dateigröße", sizeText)
        add("Text je Seite", textText(meta, pageCount: pageCount))
        if let order = meta.pageOrder {
            add("Seitenreihenfolge", "laut Seitenzahlen korrigiert (im Original: \(PageNumbering.originalSequence(order).map(String.init).joined(separator: ", ")))")
        }
        if let ocr = meta.ocr {
            add("OCR", "\(ocr.engine), \(ocr.languages.joined(separator: ", ")), \(dateTime.string(from: ocr.date))")
        }
        add("Erstellt mit", meta.app)
        if let updated = meta.updatedWith { add("Zuletzt geändert mit", updated) }
        return lines
    }

    /// Mehrzeiliger Text für Tooltips.
    public static func tooltip(meta: DocumentMetadata?, fileName: String, fileSize: Int?, pageCount: Int) -> String {
        var parts = [fileName, ""]
        if meta == nil { parts.append("Keine ScanArchiv-Informationen (fremdes PDF).") }
        parts += lines(meta: meta, fileSize: fileSize, pageCount: pageCount).map { "\($0.label): \($0.value)" }
        if let issues = meta?.issues, !issues.isEmpty {
            parts.append("")
            parts.append("Zu prüfen:")
            parts += issues.map { "⚠︎ " + $0.message }
        }
        return parts.joined(separator: "\n")
    }

    /// z. B. „+4 KB: Stempel, Metadaten angehängt“ oder „−1,7 MB durch Kompression“
    static func sizeChange(_ diff: Int, meta: DocumentMetadata) -> String {
        let amount = (diff >= 0 ? "+" : "−") + bytes(abs(diff))
        let ocr = meta.pages.contains(.ocr)
        var added = ["Stempel"]
        if ocr { added.append("OCR-Textebene") }
        added.append("Metadaten")
        let list = added.joined(separator: ", ")
        switch meta.storage {
        case .appended?:
            return "\(amount): \(list) angehängt"
        case .rewritten?:
            return "\(amount): neu geschrieben mit \(list)"
        case .rebuilt?:
            return diff < 0 ? "\(amount) durch Kompression" : "\(amount): Seiten neu erzeugt mit \(list)"
        case .created?:
            if diff < 0, meta.compression?.applied == true { return "\(amount) durch Kompression" }
            return "\(amount): als PDF mit \(list)"
        case nil:
            return "\(amount) gegenüber Original"
        }
    }

    static func storageText(_ storage: DocumentMetadata.Storage) -> String {
        switch storage {
        case .appended: return "Original unverändert, Zusätze angehängt"
        case .rewritten: return "neu geschrieben (war kleiner als Anhängen)"
        case .rebuilt: return "Seiten neu erzeugt (Kompression)"
        case .created: return "von ScanArchiv erstellt"
        }
    }

    static func sourceText(_ source: DocumentMetadata.Source) -> String {
        switch source {
        case .scan: return "Scan"
        case .pdf: return "Import (PDF)"
        case .image: return "Import (Bild)"
        case .unknown: return "unbekannt (ältere Version)"
        }
    }

    static func dateSourceText(_ source: DocumentMetadata.DateSource) -> String {
        switch source {
        case .text: return "aus dem Text"
        case .ai: return "von Apple Intelligence"
        case .today: return "Tagesdatum – kein Datum gefunden"
        case .manual: return "von Hand"
        case .unknown: return "Herkunft unbekannt"
        case .fileName: return "aus dem Dateinamen – kein Datum im Text"
        case .pdfCreation: return "Erstelldatum des PDFs – kein Datum im Text"
        case .fileDate: return "Datum der Datei – kein Datum im Text"
        }
    }

    static func titleText(_ meta: DocumentMetadata) -> String {
        let when = meta.titleUpdated.map { " am \(dateTime.string(from: $0))" } ?? ""
        switch meta.titleSource {
        case .ai: return "von Apple Intelligence" + when
        case .manual: return "von Hand" + when
        case .none: return "keine"
        }
    }

    static func compressionText(_ meta: DocumentMetadata) -> String {
        guard let c = meta.compression else { return "keine (Original)" }
        let setting = c.preset == .original ? "keine Größenvorgabe" : c.preset.label
        let color = c.colorMode == .original ? "" : ", \(c.colorMode.label)"
        guard c.applied || meta.source == .scan else {
            return "\(setting)\(color) – Original behalten (Umwandlung wäre nicht kleiner)"
        }
        if let before = c.originalBytes, let after = c.resultBytes {
            return "\(setting)\(color): \(bytes(before)) → \(bytes(after))"
        }
        return setting + color
    }

    static func textText(_ meta: DocumentMetadata, pageCount: Int) -> String {
        let counts = Dictionary(grouping: meta.pages, by: { $0 }).mapValues(\.count)
        func pages(_ n: Int) -> String { n == 1 ? "1 Seite" : "\(n) Seiten" }
        var parts: [String] = []
        if let n = counts[.embedded] { parts.append("\(pages(n)) mit vorhandenem Text (keine OCR nötig)") }
        if let n = counts[.ocr] { parts.append("\(pages(n)) per OCR erkannt") }
        if let n = counts[.unknown] { parts.append("\(pages(n)) mit Text (Herkunft unbekannt, ältere Version)") }
        if let n = counts[.none] { parts.append("\(pages(n)) ohne Text") }
        return parts.isEmpty ? "–" : parts.joined(separator: " · ")
    }
}
