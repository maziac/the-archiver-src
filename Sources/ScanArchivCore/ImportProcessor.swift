import CoreGraphics
import CryptoKit
import Foundation
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

/// Verarbeitet eine Datei vollautomatisch: Duplikatprüfung, Text (eingebettet oder per OCR), Vorschlag für
/// Titel, Beschreibung und Datum, Kompression (nur wenn kleiner), Stempel, Metadaten, Archivieren, Indexieren.
/// Probleme werden im Dokument vermerkt, das Dokument wird trotzdem archiviert.
public enum ImportProcessor {
    public static let imageTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .bmp, .gif]
    static let renderDPI = 300.0

    public static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .pdf) || imageTypes.contains { type.conforms(to: $0) }
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
        var textSources: [DocumentMetadata.TextSource] = []
        let source: DocumentMetadata.Source
        let preset: SizePreset
        /// liefert (unverändert, umgewandelt?) – jeweils mit Stempel, noch ohne ScanArchiv-Metadaten
        let makeCandidates: (_ number: Int, _ date: Date, _ title: String, _ summary: String) throws -> (Data, Data?)

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
            if !emptyPages.isEmpty { issues.append(.noText(pages: emptyPages)) }
            let hasImagePages = textSources.contains { $0 != .embedded }
            makeCandidates = { number, date, title, summary in
                let original = try PDFStamper.stamp(source: file, pages: edits, number: number, date: date, title: title, summary: summary)
                guard convert, hasImagePages else { return (original, nil) }
                let converted = try PDFBuilder.build(pages: composed, number: number, date: date, dpi: renderDPI,
                                                     title: title, summary: summary)
                return (original, converted)
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
            makeCandidates = { number, date, title, summary in
                let plain = PageCompressor.encode(image, pageSize: size, preset: .original, color: .original, originalJPEG: originalJPEG)
                let original = try PDFBuilder.build(pages: [PDFPageInput(encoded: plain, lines: lines)], number: number, date: date,
                                                    dpi: dpi, title: title, summary: summary)
                guard convert else { return (original, nil) }
                let small = PageCompressor.encode(image, pageSize: size, preset: options.imagePreset, color: options.colorMode,
                                                  originalJPEG: originalJPEG)
                let converted = try PDFBuilder.build(pages: [PDFPageInput(encoded: small, lines: lines)], number: number, date: date,
                                                     dpi: small.dpi, title: title, summary: summary)
                return (original, converted)
            }
        }

        // Vorschlag aus den ersten Seiten
        let firstText = pageTexts.prefix(2).joined(separator: "\n\n")
        var suggestion: DocumentSuggestion?
        if !options.useSummarizer {
            issues.append(.noSuggestion("deaktiviert"))
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
        let textDate = DateExtractor.bestGuess(in: pageTexts.first ?? "") ?? DateExtractor.bestGuess(in: firstText)
        let dateSource: DocumentMetadata.DateSource = suggestion?.date != nil ? .ai : (textDate != nil ? .text : .today)
        if dateSource == .today { issues.append(.noDate) }
        let date = suggestion?.date ?? textDate ?? Date()
        let title = suggestion?.title ?? ""
        let summary = suggestion?.summary ?? ""
        let usesOCR = textSources.contains { $0 != .embedded }

        var meta = DocumentMetadata(
            number: 0, documentDate: date, dateSource: dateSource,
            titleSource: title.isEmpty ? .none : .ai, titleUpdated: title.isEmpty ? nil : Date(),
            archivedAt: Date(), source: source, originalFileName: name, originalSize: fileData.count, originalSHA256: sha,
            pages: textSources, ocr: usesOCR ? DocumentMetadata.OCRInfo() : nil, issues: issues)
        let finalMeta = meta

        progress("Speichern")
        let saved = try await Task.detached { () throws -> (number: Int, url: URL, meta: DocumentMetadata) in
            var stored = finalMeta
            let result = try archive.save(date: date, title: title) { number in
                let (original, converted) = try makeCandidates(number, date, title, summary)
                // Umwandlung nur übernehmen, wenn sie wirklich kleiner ist
                let useConverted = converted.map { $0.count < original.count } ?? false
                stored.number = number
                if converted != nil || preset != .original || options.colorMode != .original {
                    stored.compression = .init(preset: preset, colorMode: options.colorMode, applied: useConverted,
                                               originalBytes: original.count, resultBytes: (useConverted ? converted! : original).count)
                }
                return try PDFMetadata.finalize(useConverted ? converted! : original, meta: stored, title: title, summary: summary)
            }
            return (result.number, result.url, stored)
        }.value
        meta = saved.meta

        try index.add(number: saved.number, date: date, url: saved.url, pages: pageTexts.count,
                      text: pageTexts.joined(separator: "\n\n"), title: title, summary: summary, meta: meta)
        return ImportResult(number: saved.number, url: saved.url, title: title, summary: summary, date: date, meta: meta)
    }
}
