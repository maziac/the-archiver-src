import CoreGraphics
import Foundation
import UniformTypeIdentifiers

public enum ImportError: LocalizedError {
    case unsupported(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(name): return "\(name): Dateiformat wird nicht unterstützt."
        case let .unreadable(name): return "\(name) konnte nicht gelesen werden (beschädigt oder leer?)."
        }
    }
}

public struct ImportResult: Sendable {
    public var number: Int
    public var url: URL
    public var title: String
    public var summary: String
    public var date: Date
    public var issues: [DocumentIssue]
}

/// Verarbeitet eine Datei vollautomatisch: Text (eingebettet oder per OCR), Vorschlag für Titel,
/// Beschreibung und Datum, Stempel, Archivieren, Indexieren. Probleme werden vermerkt, das Dokument
/// wird trotzdem archiviert.
public enum ImportProcessor {
    public static let imageTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .bmp, .gif]

    public static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .pdf) || imageTypes.contains { type.conforms(to: $0) }
    }

    /// - Parameters:
    ///   - useSummarizer: false = keine Titel/Beschreibung erzeugen (z. B. für Tests)
    ///   - progress: Statusmeldungen wie „Texterkennung Seite 2/5“
    public static func process(file: URL, archive: Archive, index: SearchIndex, issueStore: IssueStore,
                               jpegQuality: Double = 0.7, useSummarizer: Bool = true,
                               progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ImportResult {
        let name = file.lastPathComponent
        guard let type = UTType(filenameExtension: file.pathExtension) else { throw ImportError.unsupported(name) }

        var issues: [DocumentIssue] = []
        var pageTexts: [String] = []
        let save: (Date, String, String) throws -> (number: Int, url: URL)

        if type.conforms(to: .pdf) {
            // PDF: Inhalt bleibt unverändert; Bild-Seiten bekommen eine OCR-Textebene
            let embedded = PDFStamper.pageTexts(of: file)
            guard !embedded.isEmpty, let document = CGPDFDocument(file as CFURL) else { throw ImportError.unreadable(name) }
            var edits: [PDFStamper.PageEdit] = []
            var emptyPages: [Int] = []
            for (i, text) in embedded.enumerated() {
                if !text.isEmpty {
                    pageTexts.append(text)
                    edits.append(.init(index: i))
                    continue
                }
                progress("Texterkennung Seite \(i + 1)/\(embedded.count)")
                guard let image = await Task.detached(operation: {
                    ImageTools.renderPDFPage(document, index: i, dpi: 300, gray: true)
                }).value else { throw ImportError.unreadable(name) }
                let lines = try await OCRService.recognize(image)
                let text = lines.map(\.text).joined(separator: "\n")
                if !DocumentIssue.hasText(text) { emptyPages.append(i + 1) }
                pageTexts.append(text)
                edits.append(.init(index: i, lines: lines))
            }
            if !emptyPages.isEmpty { issues.append(.noText(pages: emptyPages)) }
            save = { date, title, summary in
                try archive.save(date: date, title: title) { number in
                    try PDFStamper.stamp(source: file, pages: edits, number: number, date: date, title: title, summary: summary)
                }
            }
        } else if imageTypes.contains(where: { type.conforms(to: $0) }) {
            // Bild: einseitiges PDF in voller Auflösung
            guard let image = ImageTools.load(file) else { throw ImportError.unreadable(name) }
            let dpi = ImageTools.dpi(of: file, width: image.width)
            progress("Texterkennung")
            let lines = try await OCRService.recognize(image)
            let text = lines.map(\.text).joined(separator: "\n")
            if !DocumentIssue.hasText(text) { issues.append(.noText(pages: [1])) }
            pageTexts = [text]
            let page = PDFPageInput(image: image, lines: lines, dpi: dpi)
            save = { date, title, summary in
                try archive.save(date: date, title: title) { number in
                    try PDFBuilder.build(pages: [page], number: number, date: date, dpi: dpi, jpegQuality: jpegQuality,
                                         title: title, summary: summary)
                }
            }
        } else {
            throw ImportError.unsupported(name)
        }

        // Vorschlag aus den ersten Seiten
        let firstText = pageTexts.prefix(2).joined(separator: "\n\n")
        var suggestion: DocumentSuggestion?
        if !useSummarizer {
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
        let date = suggestion?.date
            ?? DateExtractor.bestGuess(in: pageTexts.first ?? "")
            ?? DateExtractor.bestGuess(in: firstText)
        if date == nil { issues.append(.noDate) }
        let finalDate = date ?? Date()
        let title = suggestion?.title ?? ""
        let summary = suggestion?.summary ?? ""

        progress("Speichern")
        let saved = try await Task.detached { try save(finalDate, title, summary) }.value
        try issueStore.set(issues, for: saved.number)
        try index.add(number: saved.number, date: finalDate, url: saved.url, pages: pageTexts.count,
                      text: pageTexts.joined(separator: "\n\n"), title: title, summary: summary, issues: issues)
        return ImportResult(number: saved.number, url: saved.url, title: title, summary: summary, date: finalDate, issues: issues)
    }
}
