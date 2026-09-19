import Foundation
import PDFKit

/// Alles, was ScanArchiv über ein Dokument weiß. Steht im PDF selbst (maßgeblich) und als Kopie
/// im Suchindex; „Index neu aufbauen“ stellt den Index daraus vollständig wieder her.
public struct DocumentMetadata: Codable, Equatable, Sendable {
    public enum DateSource: String, Codable, Sendable {
        /// aus dem Text erkannt, von Apple Intelligence gewählt, Tagesdatum (nichts gefunden), von Hand, unbekannt (Altbestand),
        /// Ersatz ohne Datum im Text: Dateiname, Erstelldatum im PDF, Datum im Dateisystem
        case text, ai, today, manual, unknown, fileName, pdfCreation, fileDate
    }

    public enum TitleSource: String, Codable, Sendable {
        case ai, manual, none
    }

    public enum Source: String, Codable, Sendable {
        case scan, pdf, image, unknown
    }

    public enum TextSource: String, Codable, Sendable {
        /// eigener Text der Seite, per OCR ergänzt, kein Text gefunden,
        /// Text vorhanden aber Herkunft unbekannt (Altbestand), leere Seite (kein Problem)
        case embedded, ocr, none, unknown, blank
    }

    /// Wie die Datei im Archiv entstanden ist.
    public enum Storage: String, Codable, Sendable {
        /// Original unverändert, Stempel/Textebene/Metadaten per inkrementellem Update angehängt
        case appended
        /// Original von PDFKit neu geschrieben (war kleiner als das Anhängen)
        case rewritten
        /// Seiten neu erzeugt (Kompression)
        case rebuilt
        /// von ScanArchiv erstellt (Scan, Bild-Import)
        case created
    }

    public struct ScanInfo: Codable, Equatable, Sendable {
        public var scanner: String?
        public var dpi: Int
        public var colorMode: ColorMode

        public init(scanner: String?, dpi: Int, colorMode: ColorMode) {
            self.scanner = scanner
            self.dpi = dpi
            self.colorMode = colorMode
        }
    }

    public struct CompressionInfo: Codable, Equatable, Sendable {
        public var preset: SizePreset
        public var colorMode: ColorMode
        /// false = Umwandlung war nicht kleiner, Original behalten
        public var applied: Bool
        /// Größe ohne Umwandlung (Original bzw. verlustfrei), soweit bekannt
        public var originalBytes: Int?
        public var resultBytes: Int?

        public init(preset: SizePreset, colorMode: ColorMode, applied: Bool, originalBytes: Int?, resultBytes: Int?) {
            self.preset = preset
            self.colorMode = colorMode
            self.applied = applied
            self.originalBytes = originalBytes
            self.resultBytes = resultBytes
        }
    }

    public struct OCRInfo: Codable, Equatable, Sendable {
        public var engine: String
        public var languages: [String]
        public var date: Date

        public init(engine: String = "Apple Vision", languages: [String] = OCRService.defaultLanguages, date: Date = Date()) {
            self.engine = engine
            self.languages = languages
            self.date = date
        }
    }

    public var version = 1
    public var number: Int
    public var documentDate: Date
    public var dateSource: DateSource
    public var titleSource: TitleSource
    public var titleUpdated: Date?
    public var archivedAt: Date
    public var source: Source
    public var originalFileName: String?
    public var originalSize: Int?
    public var originalSHA256: String?
    public var scan: ScanInfo?
    public var compression: CompressionInfo?
    public var pages: [TextSource]
    public var ocr: OCRInfo?
    public var issues: [DocumentIssue]
    /// Programmversion, mit der das Dokument erstellt wurde
    public var app: String
    /// Programmversion der letzten Änderung (Bearbeiten, Prüfen, Titel erzeugen, Migration)
    public var updatedWith: String?
    /// Entstehung der Archivdatei (nil = ältere Version)
    public var storage: Storage?
    /// Beim Import laut Seitenzahlen umsortiert: Indizes (ab 0) der Originalseiten in neuer Reihenfolge
    public var pageOrder: [Int]?

    /// Aktuelle Programmversion; die App setzt sie beim Start aus dem Bundle (z. B. „ScanArchiv 1.1 (Build 202609191030)“).
    nonisolated(unsafe) public static var appName = "ScanArchiv"
    /// Erstellversion für Dokumente aus der Zeit, bevor Metadaten gespeichert wurden
    public static let legacyAppName = "ScanArchiv vor 1.0"

    public init(number: Int, documentDate: Date, dateSource: DateSource, titleSource: TitleSource, titleUpdated: Date? = nil,
                archivedAt: Date = Date(), source: Source, originalFileName: String? = nil, originalSize: Int? = nil,
                originalSHA256: String? = nil, scan: ScanInfo? = nil, compression: CompressionInfo? = nil,
                pages: [TextSource] = [], ocr: OCRInfo? = nil, issues: [DocumentIssue] = [], app: String = DocumentMetadata.appName,
                updatedWith: String? = nil, storage: Storage? = nil) {
        self.number = number
        self.documentDate = documentDate
        self.dateSource = dateSource
        self.titleSource = titleSource
        self.titleUpdated = titleUpdated
        self.archivedAt = archivedAt
        self.source = source
        self.originalFileName = originalFileName
        self.originalSize = originalSize
        self.originalSHA256 = originalSHA256
        self.scan = scan
        self.compression = compression
        self.pages = pages
        self.ocr = ocr
        self.issues = issues
        self.app = app
        self.updatedWith = updatedWith
        self.storage = storage
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate  // Sekunden seit 2001, bitgenau
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(self), as: UTF8.self)
        // reines ASCII (Nicht-ASCII als \uXXXX): kompakt als PDF-String, weiterhin gültiges JSON
        var ascii = ""
        for unit in json.utf16 {
            if unit < 0x80 { ascii.unicodeScalars.append(Unicode.Scalar(unit)!) } else { ascii += String(format: "\\u%04x", unit) }
        }
        return ascii
    }

    static func decode(_ json: String) -> DocumentMetadata? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return try? decoder.decode(DocumentMetadata.self, from: Data(json.utf8))
    }
}

/// Liest/schreibt die Metadaten im PDF:
/// - Standardfelder (Title, Subject, Keywords, Creator, CreationDate) für Spotlight/Vorschau.app,
/// - der vollständige Datensatz als JSON in einer unsichtbaren, nicht druckbaren Anmerkung auf Seite 1.
///   (PDFKit verwirft eigene Einträge im Info-Dictionary, Anmerkungen bleiben dagegen erhalten.)
public enum PDFMetadata {
    static let annotationKey = PDFAnnotationKey(rawValue: "/ScanArchiv")

    public static func apply(_ meta: DocumentMetadata, title: String, summary: String, to document: PDFDocument) throws {
        let numberText = Archive.formatNumber(meta.number)
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title.isEmpty
            ? Archive.fileName(date: meta.documentDate, number: meta.number).replacingOccurrences(of: ".pdf", with: "") : title
        attributes[PDFDocumentAttribute.subjectAttribute] = summary
        attributes[PDFDocumentAttribute.keywordsAttribute] = [numberText, "Nr. \(numberText)"]
        attributes[PDFDocumentAttribute.creatorAttribute] = meta.app
        attributes[PDFDocumentAttribute.creationDateAttribute] = meta.archivedAt
        document.documentAttributes = attributes

        guard let page = document.page(at: 0) else { return }
        let json = try meta.encoded()
        if let existing = annotation(on: page) {
            existing.setValue(json, forAnnotationKey: annotationKey)
        } else {
            let note = PDFAnnotation(bounds: .zero, forType: .text, withProperties: nil)
            note.setValue(json, forAnnotationKey: annotationKey)
            note.shouldDisplay = false
            note.shouldPrint = false
            note.isReadOnly = true
            page.addAnnotation(note)
        }
    }

    public static func read(_ document: PDFDocument) -> DocumentMetadata? {
        guard let page = document.page(at: 0), let note = annotation(on: page),
              let json = note.value(forAnnotationKey: annotationKey) as? String else { return nil }
        return DocumentMetadata.decode(json)
    }

    public static func read(url: URL) -> DocumentMetadata? {
        PDFDocument(url: url).flatMap(read)
    }

    /// Öffnet fertige PDF-Daten, trägt die Metadaten ein und liefert die neuen Daten.
    public static func finalize(_ data: Data, meta: DocumentMetadata, title: String, summary: String) throws -> Data {
        guard let document = PDFDocument(data: data) else { throw ArchiveError.cannotWrite(URL(fileURLWithPath: "PDF")) }
        try apply(meta, title: title, summary: summary, to: document)
        guard let result = document.dataRepresentation() else { throw ArchiveError.cannotWrite(URL(fileURLWithPath: "PDF")) }
        return result
    }

    private static func annotation(on page: PDFPage) -> PDFAnnotation? {
        page.annotations.first { $0.value(forAnnotationKey: annotationKey) != nil }
    }
}
