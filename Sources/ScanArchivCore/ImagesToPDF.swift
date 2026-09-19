import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// Fasst mehrere Bilddateien zu einem PDF zusammen (eine Seite je Bild, in der übergebenen Reihenfolge).
/// Die Bilder werden dabei nicht neu kodiert: JPEGs wandern unverändert ins PDF, andere Formate verlustfrei.
/// Texterkennung, Titel, Stempel und Kompression macht anschließend der normale Import.
public enum ImagesToPDF {
    public static func combine(_ urls: [URL]) throws -> Data {
        var pages: [PDFPageInput] = []
        for url in urls {
            guard let image = ImageTools.load(url) else { throw ImportError.unreadable(url.lastPathComponent) }
            let dpi = ImageTools.dpi(of: url, width: image.width)
            let size = CGSize(width: Double(image.width) / dpi * 72, height: Double(image.height) / dpi * 72)
            let isJPEG = UTType(filenameExtension: url.pathExtension)?.conforms(to: .jpeg) == true
            let encoded = PageCompressor.encode(image, pageSize: size, preset: .original, color: .original,
                                                originalJPEG: isJPEG ? try? Data(contentsOf: url) : nil)
            pages.append(PDFPageInput(encoded: encoded, lines: []))
        }
        guard !pages.isEmpty else { throw ImportError.unreadable("Bilder") }
        // ohne Nummer/Stempel – das übernimmt der Import
        return try PDFBuilder.build(pages: pages, number: 0, date: Date(), dpi: 300, stamp: false)
    }

    /// Dateidatum eines Bildes (früheres von Erstell- und Änderungsdatum).
    public static func fileDate(_ url: URL) -> Date? {
        FileDate.fileSystemDate(url)
    }

    /// Dateiname für das zusammengefasste PDF, z. B. „Scan 1 + 4 Bilder.pdf“.
    public static func fileName(for urls: [URL]) -> String {
        let base = urls.first.map { ($0.lastPathComponent as NSString).deletingPathExtension } ?? "Bilder"
        return urls.count > 1 ? "\(base) + \(urls.count - 1) Bilder.pdf" : "\(base).pdf"
    }
}
