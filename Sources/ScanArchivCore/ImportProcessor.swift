import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

public enum ImportError: LocalizedError, Equatable {
    case unsupported(String)
    case unreadable(String)
    /// Dieselbe Datei (gleiche Prüfsumme) ist schon als diese Nummer archiviert.
    case duplicate(number: Int, path: String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(name): return "\(name): Dateiformat wird nicht unterstützt."
        case let .unreadable(name): return "\(name) konnte nicht gelesen werden (beschädigt oder leer?)."
        case let .duplicate(number, _): return "Duplikat von Nr. \(Archive.formatNumber(number))"
        }
    }
}

public struct ImportOptions: Sendable {
    public var pdfPreset: SizePreset
    public var imagePreset: SizePreset
    public var colorMode: ColorMode
    /// false = keine Titel/Beschreibung erzeugen (z. B. für Tests)
    public var useSummarizer: Bool

    public init(pdfPreset: SizePreset = .original, imagePreset: SizePreset = .kb150, colorMode: ColorMode = .original,
                useSummarizer: Bool = true) {
        self.pdfPreset = pdfPreset
        self.imagePreset = imagePreset
        self.colorMode = colorMode
        self.useSummarizer = useSummarizer
    }
}

public struct ImportResult: Sendable {
    public var number: Int
    public var url: URL
    public var title: String
    public var summary: String
    public var date: Date
    public var meta: DocumentMetadata
    public var issues: [DocumentIssue] { meta.issues }
}

/// Eine mögliche Fassung der Archivdatei.
struct Candidate {
    var storage: DocumentMetadata.Storage
    var compressed = false
    var data: Data
}

/// Verarbeitet eine Datei vollautomatisch: Duplikatprüfung, Text (eingebettet oder per OCR), Vorschlag für
/// Titel, Beschreibung und Datum, Stempel, Metadaten, Archivieren, Indexieren. Es entstehen mehrere Fassungen
/// (angehängt, neu geschrieben, komprimiert); die kleinste gültige gewinnt.
/// Probleme werden im Dokument vermerkt, das Dokument wird trotzdem archiviert.
public enum ImportProcessor {
    public static let imageTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .bmp, .gif]
    static let renderDPI = 300.0

    public static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .pdf) || imageTypes.contains { type.conforms(to: $0) }
    }

    /// Prüft eine erzeugte Fassung: Seitenzahl, Text auf allen Seiten, die Text haben sollen,
    /// Stempel (Nummer) und Metadaten müssen lesbar sein.
    /// - Parameter expectedTexts: nach dem Umsortieren der erwartete Text je Seite – jede Seite muss
    ///   typische Wörter davon enthalten, damit eine falsch sortierte Fassung nie gewinnt.
    static func validate(_ data: Data, number: Int, pageCount: Int, textPages: Set<Int>,
                         expectedTexts: [String]? = nil) -> Bool {
        guard let pdf = PDFDocument(data: data), pdf.pageCount == pageCount,
              PDFMetadata.read(pdf)?.number == number,
              !pdf.findString("Nr. \(Archive.formatNumber(number))", withOptions: []).isEmpty else { return false }
        guard textPages.allSatisfy({ DocumentIssue.hasText(pdf.page(at: $0)?.string ?? "") }) else { return false }
        guard let expectedTexts else { return true }
        return pagesMatch(pdf, expectedTexts: expectedTexts)
    }

    /// Jede Seite enthält typische Wörter ihres erwarteten Textes (Stichprobe der längeren Wörter).
    static func pagesMatch(_ pdf: PDFDocument, expectedTexts: [String]) -> Bool {
        expectedTexts.enumerated().allSatisfy { index, expected in
            let words = Set(expected.split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 5 }.map { $0.lowercased() })
                .sorted().prefix(5)
            guard !words.isEmpty else { return true }
            let actual = (pdf.page(at: index)?.string ?? "").lowercased()
            return words.filter { actual.contains($0) }.count * 2 >= words.count
        }
    }

    public static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func process(file: URL, archive: Archive, index: SearchIndex, options: ImportOptions = ImportOptions(),
                               progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ImportResult {
        let name = file.lastPathComponent
        guard let type = UTType(filenameExtension: file.pathExtension),
              type.conforms(to: .pdf) || imageTypes.contains(where: { type.conforms(to: $0) }) else {
            throw ImportError.unsupported(name)
        }
        guard let fileData = try? Data(contentsOf: file), !fileData.isEmpty else { throw ImportError.unreadable(name) }
        let sha = sha256(of: fileData)
        if let existing = try index.record(forSHA256: sha) {
            throw ImportError.duplicate(number: existing.number, path: existing.path)
        }

        var issues: [DocumentIssue] = []
        var pageTexts: [String] = []
        /// laut Seitenzahlen umsortiert: Originalindizes in neuer Reihenfolge
        var pageOrder: [Int]?
        var textSources: [DocumentMetadata.TextSource] = []
        let source: DocumentMetadata.Source
        let preset: SizePreset
        /// Mögliche Fassungen der Archivdatei; jede bekommt ihre eigenen Metadaten (Speicherart, Kompression).
        let makeCandidates: (_ number: Int, _ date: Date, _ title: String, _ summary: String,
                             _ meta: (DocumentMetadata.Storage, Bool) -> DocumentMetadata) throws -> [Candidate]

        if type.conforms(to: .pdf) {
            // PDF: Textseiten bleiben unverändert; Bildseiten bekommen OCR und werden ggf. komprimiert
            source = .pdf
            preset = options.pdfPreset
            let embedded = PDFStamper.pageTexts(of: file)
            guard !embedded.isEmpty, let document = CGPDFDocument(file as CFURL) else { throw ImportError.unreadable(name) }
            let convert = options.pdfPreset != .original || options.colorMode != .original
            var edits: [PDFStamper.PageEdit] = []
            var composed: [PDFPageInput] = []
            var emptyPages: [Int] = []

            for (i, text) in embedded.enumerated() {
                guard let cgPage = document.page(at: i + 1) else { throw ImportError.unreadable(name) }
                if !text.isEmpty {
                    pageTexts.append(text)
                    textSources.append(.embedded)
                    edits.append(.init(index: i))
                    composed.append(PDFPageInput(vectorPage: cgPage))
                    continue
                }
                progress("Texterkennung Seite \(i + 1)/\(embedded.count)")
                let gray = options.colorMode != .original
                guard let image = await Task.detached(operation: {
                    ImageTools.renderPDFPage(document, index: i, dpi: renderDPI, gray: gray)
                }).value else { throw ImportError.unreadable(name) }
                let lines = try await OCRService.recognize(image)
                let pageText = lines.map(\.text).joined(separator: "\n")
                let hasText = DocumentIssue.hasText(pageText)
                if !hasText { emptyPages.append(i + 1) }
                pageTexts.append(pageText)
                textSources.append(hasText ? .ocr : .none)
                edits.append(.init(index: i, lines: lines))
                if convert {
                    let size = CGSize(width: Double(image.width) / renderDPI * 72, height: Double(image.height) / renderDPI * 72)
                    let encoded = await Task.detached {
                        PageCompressor.encode(image, pageSize: size, preset: options.pdfPreset, color: options.colorMode)
                    }.value
                    composed.append(PDFPageInput(encoded: encoded, lines: lines))
                } else {
                    composed.append(PDFPageInput(vectorPage: cgPage))
                }
            }
            // Reihenfolge laut gedruckter Seitenzahlen; eindeutig → vor dem Stempeln umsortieren
            let numbering = PageNumbering.analyze(pageTexts: pageTexts)
            if case let .reorder(order) = numbering {
                pageOrder = order
                pageTexts = order.map { pageTexts[$0] }
                textSources = order.map { textSources[$0] }
                edits = order.map { edits[$0] }
                composed = order.map { composed[$0] }
                emptyPages = emptyPages.compactMap { old in order.firstIndex(of: old - 1).map { $0 + 1 } }.sorted()
            }
            if !emptyPages.isEmpty { issues.append(.noText(pages: emptyPages)) }
            switch numbering {
            case let .reorder(order): issues.append(.pageOrderCorrected(original: PageNumbering.originalSequence(order)))
            case let .uncertain(numbers): issues.append(.pageOrderUncertain(numbers: numbers))
            case .none, .inOrder: break
            }
            let hasImagePages = textSources.contains { $0 != .embedded }
            let order = pageOrder
            // Positionen in der (ggf. neuen) Reihenfolge
            let overlays = edits.enumerated().filter { !$0.element.lines.isEmpty }
                .map { PDFAppender.Overlay(pageIndex: $0.offset, lines: $0.element.lines) }
            makeCandidates = { number, date, title, summary, meta in
                var candidates: [Candidate] = []
                // 1. Original unverändert, Zusätze angehängt (inkrementelles Update)
                if let appended = try? PDFAppender.stamp(original: fileData, stampText: PDFBuilder.stampText(number: number, date: date),
                                                         overlays: overlays, meta: meta(.appended, false), title: title, summary: summary,
                                                         order: order) {
                    candidates.append(Candidate(storage: .appended, data: appended))
                }
                // 2. von PDFKit neu geschrieben (manchmal kleiner, z. B. bei ungünstig aufgebauten Originalen)
                if let rewritten = try? PDFStamper.stamp(source: file, pages: edits, number: number, date: date, title: title,
                                                         summary: summary, meta: meta(.rewritten, false)) {
                    candidates.append(Candidate(storage: .rewritten, data: rewritten))
                }
                // 3. Bildseiten komprimiert neu erzeugt
                if convert, hasImagePages {
                    let built = try PDFBuilder.build(pages: composed, number: number, date: date, dpi: renderDPI,
                                                     title: title, summary: summary)
                    candidates.append(Candidate(storage: .rebuilt, compressed: true, data: try PDFMetadata.finalize(
                        built, meta: meta(.rebuilt, true), title: title, summary: summary)))
                }
                return candidates
            }
        } else {
            // Bild: einseitiges PDF in voller Auflösung, JPEGs ohne erneute Kompression
            source = .image
            preset = options.imagePreset
            guard let image = ImageTools.load(file) else { throw ImportError.unreadable(name) }
            let dpi = ImageTools.dpi(of: file, width: image.width)
            let size = CGSize(width: Double(image.width) / dpi * 72, height: Double(image.height) / dpi * 72)
            let originalJPEG = type.conforms(to: .jpeg) ? fileData : nil
            progress("Texterkennung")
            let lines = try await OCRService.recognize(image)
            let text = lines.map(\.text).joined(separator: "\n")
            let hasText = DocumentIssue.hasText(text)
            if !hasText { issues.append(.noText(pages: [1])) }
            pageTexts = [text]
            textSources = [hasText ? .ocr : .none]
            let convert = options.imagePreset != .original || options.colorMode != .original
            makeCandidates = { number, date, title, summary, meta in
                let plain = PageCompressor.encode(image, pageSize: size, preset: .original, color: .original, originalJPEG: originalJPEG)
                let original = try PDFBuilder.build(pages: [PDFPageInput(encoded: plain, lines: lines)], number: number, date: date,
                                                    dpi: dpi, title: title, summary: summary)
                var candidates = [Candidate(storage: .created, data: try PDFMetadata.finalize(
                    original, meta: meta(.created, false), title: title, summary: summary))]
                guard convert else { return candidates }
                let small = PageCompressor.encode(image, pageSize: size, preset: options.imagePreset, color: options.colorMode,
                                                  originalJPEG: originalJPEG)
                let converted = try PDFBuilder.build(pages: [PDFPageInput(encoded: small, lines: lines)], number: number, date: date,
                                                     dpi: small.dpi, title: title, summary: summary)
                candidates.append(Candidate(storage: .created, compressed: true, data: try PDFMetadata.finalize(
                    converted, meta: meta(.created, true), title: title, summary: summary)))
                return candidates
            }
        }

        // Vorschlag aus den ersten Seiten
        let firstText = pageTexts.prefix(2).joined(separator: "\n\n")
        var suggestion: DocumentSuggestion?
        if !options.useSummarizer {
            issues.append(.noSuggestion(DocumentIssue.suggestionDisabled))
        } else if !DocumentIssue.hasText(firstText) {
            issues.append(.noSuggestion("kein Text auf den ersten Seiten"))
        } else {
            progress("Titel und Beschreibung")
            do {
                suggestion = try await Summarizer.suggest(for: firstText)
            } catch {
                issues.append(.noSuggestion(error.localizedDescription))
            }
        }
        // Datum: 1. im Text (Apple Intelligence bzw. erkannt), 2. der Datei (Name, PDF, Dateisystem), 3. heute
        let textDate = DateExtractor.bestGuess(in: pageTexts.first ?? "") ?? DateExtractor.bestGuess(in: firstText)
        let fileDate = FileDate.best(for: file)
        let date: Date
        let dateSource: DocumentMetadata.DateSource
        if let aiDate = suggestion?.date {
            (date, dateSource) = (aiDate, .ai)
        } else if let textDate {
            (date, dateSource) = (textDate, .text)
        } else if let fileDate {
            (date, dateSource) = (fileDate.date, fileDate.source)
        } else {
            (date, dateSource) = (Date(), .today)
            issues.append(.noDate)
        }
        let title = suggestion?.title ?? ""
        let summary = suggestion?.summary ?? ""
        let usesOCR = textSources.contains { $0 != .embedded }

        var meta = DocumentMetadata(
            number: 0, documentDate: date, dateSource: dateSource,
            titleSource: title.isEmpty ? .none : .ai, titleUpdated: title.isEmpty ? nil : Date(),
            archivedAt: Date(), source: source, originalFileName: name, originalSize: fileData.count, originalSHA256: sha,
            pages: textSources, ocr: usesOCR ? DocumentMetadata.OCRInfo() : nil, issues: issues)
        meta.pageOrder = pageOrder
        let finalMeta = meta

        progress("Speichern")
        let expectedTextPages = Set(textSources.enumerated().filter { $0.element != .none }.map(\.offset))
        let pageCount = textSources.count
        let expectedTexts = pageOrder == nil ? nil : pageTexts
        let saved = try await Task.detached { () throws -> (number: Int, url: URL, meta: DocumentMetadata) in
            var stored = finalMeta
            let result = try archive.save(date: date, title: title) { number in
                let metaFor: (DocumentMetadata.Storage, Bool) -> DocumentMetadata = { storage, compressed in
                    var m = finalMeta
                    m.number = number
                    m.storage = storage
                    if preset != .original || options.colorMode != .original {
                        m.compression = .init(preset: preset, colorMode: options.colorMode, applied: compressed,
                                              originalBytes: nil, resultBytes: nil)
                    }
                    return m
                }
                // Die kleinste Fassung gewinnt – aber nur, wenn Text, Stempel und Metadaten lesbar sind
                let candidates = try makeCandidates(number, date, title, summary, metaFor)
                let valid = candidates.filter {
                    validate($0.data, number: number, pageCount: pageCount, textPages: expectedTextPages,
                             expectedTexts: expectedTexts)
                }
                guard let best = valid.min(by: { $0.data.count < $1.data.count }) else { throw ImportError.unreadable(name) }
                stored = metaFor(best.storage, best.compressed)
                return best.data
            }
            return (result.number, result.url, stored)
        }.value
        meta = saved.meta

        try index.add(number: saved.number, date: date, url: saved.url, pages: pageTexts.count,
                      text: pageTexts.joined(separator: "\n\n"), title: title, summary: summary, meta: meta)
        return ImportResult(number: saved.number, url: saved.url, title: title, summary: summary, date: date, meta: meta)
    }
}
