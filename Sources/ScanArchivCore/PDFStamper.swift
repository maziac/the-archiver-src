import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Übernimmt ein vorhandenes PDF inhaltlich unverändert (Text, Bilder in Originalauflösung,
/// Links, Lesezeichen) und ergänzt nur:
/// - den roten Nummernstempel auf Seite 1,
/// - eine unsichtbare OCR-Textebene für Seiten, die bisher nur ein Bild enthalten,
/// - Metadaten (Titel, Beschreibung, Nummer).
public enum PDFStamper {
    /// Anpassung einer Seite des Quell-PDFs.
    public struct PageEdit {
        /// Seitenindex im Quell-PDF
        public var index: Int
        /// zusätzliche Drehung im Uhrzeigersinn (Vielfaches von 90)
        public var extraRotation: Int
        /// OCR-Zeilen in normierten Koordinaten der *angezeigten* (gedrehten) Seite; leer = Seite hat eigenen Text
        public var lines: [OCRLine]

        public init(index: Int, extraRotation: Int = 0, lines: [OCRLine] = []) {
            self.index = index
            self.extraRotation = extraRotation
            self.lines = lines
        }
    }

    /// Text je Seite; leerer String = Seite ohne (nennenswerten) eigenen Text.
    public static func pageTexts(of url: URL) -> [String] {
        guard let pdf = PDFDocument(url: url) else { return [] }
        return (0..<pdf.pageCount).map { i in
            let text = pdf.page(at: i)?.string ?? ""
            return DocumentIssue.hasText(text) ? text : ""
        }
    }

    public static func stamp(source: URL, pages: [PageEdit], number: Int, date: Date,
                             title: String, summary: String) throws -> Data {
        let delegate = StampDelegate()
        guard let pdf = PDFDocument(url: source) else { throw ArchiveError.unreadablePDF(source) }
        pdf.delegate = delegate

        // gewünschte Seiten in gewünschter Reihenfolge; entfernte Seiten fallen weg
        let kept = pages.compactMap { edit -> (StampPage, PageEdit)? in
            guard let page = pdf.page(at: edit.index) as? StampPage else { return nil }
            return (page, edit)
        }
        guard !kept.isEmpty else { throw ArchiveError.unreadablePDF(source) }
        for i in stride(from: pdf.pageCount - 1, through: 0, by: -1) { pdf.removePage(at: i) }
        for (position, (page, edit)) in kept.enumerated() {
            page.rotation = ((page.rotation + edit.extraRotation) % 360 + 360) % 360
            page.overlayLines = edit.lines
            page.stampText = position == 0 ? PDFBuilder.stampText(number: number, date: date) : nil
            pdf.insert(page, at: position)
        }

        let numberText = Archive.formatNumber(number)
        var attributes = pdf.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = title.isEmpty
            ? Archive.fileName(date: date, number: number).replacingOccurrences(of: ".pdf", with: "") : title
        attributes[PDFDocumentAttribute.subjectAttribute] = summary.isEmpty ? PDFBuilder.stampText(number: number, date: date) : summary
        attributes[PDFDocumentAttribute.keywordsAttribute] = [numberText, "Nr. \(numberText)"]
        pdf.documentAttributes = attributes

        guard let data = pdf.dataRepresentation() else { throw ArchiveError.cannotWrite(source) }
        return data
    }

    /// Transformation von Koordinaten der angezeigten (gedrehten) Seite in den Seitenraum.
    static func displayToPage(rotation: Int, box: CGRect) -> (transform: CGAffineTransform, displaySize: CGSize) {
        let w = box.width, h = box.height
        let t: CGAffineTransform
        let size: CGSize
        switch ((rotation % 360) + 360) % 360 {
        case 90:  t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0); size = CGSize(width: h, height: w)
        case 180: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h); size = CGSize(width: w, height: h)
        case 270: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h); size = CGSize(width: h, height: w)
        default:  t = .identity; size = CGSize(width: w, height: h)
        }
        return (t.concatenating(CGAffineTransform(translationX: box.minX, y: box.minY)), size)
    }
}

private final class StampDelegate: NSObject, PDFDocumentDelegate {
    func classForPage() -> AnyClass { StampPage.self }
}

/// Seite, die beim Anzeigen und Speichern zusätzlich Stempel und OCR-Textebene zeichnet.
final class StampPage: PDFPage {
    var overlayLines: [OCRLine] = []
    var stampText: String?

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        guard !overlayLines.isEmpty || stampText != nil else { return }
        let (transform, size) = PDFStamper.displayToPage(rotation: rotation, box: bounds(for: .cropBox))
        context.saveGState()
        context.concatenate(transform)  // ab hier: Koordinaten der angezeigten Seite
        PDFBuilder.drawInvisibleText(overlayLines, in: context, pageSize: size)
        if let stampText { PDFBuilder.drawStamp(stampText, in: context, pageSize: size) }
        context.restoreGState()
    }
}
