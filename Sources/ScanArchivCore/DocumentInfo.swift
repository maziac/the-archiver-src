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
            // Import: Vergleich mit dem Original
            if let original = meta?.originalSize, original > 0 {
                let diff = size - original
                let reason = diff >= 0 ? "für Textebene, Stempel und Metadaten" : "durch Kompression"
                return "\(bytes(size)) (Original \(bytes(original)), \(diff >= 0 ? "+" : "−")\(bytes(abs(diff))) \(reason))"
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
        add("Kompression", compressionText(meta))
        add("Dateigröße", sizeText)
        add("Text je Seite", textText(meta, pageCount: pageCount))
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
