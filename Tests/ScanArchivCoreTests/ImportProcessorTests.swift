import AppKit
import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

struct ImportProcessorTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ImportTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    let helpers = PDFStamperTests()

    func makeEnv() throws -> (Archive, SearchIndex) {
        let archiveFolder = folder.appendingPathComponent("archiv")
        let archive = try Archive(folder: archiveFolder)
        return (archive, try SearchIndex(url: archiveFolder.appendingPathComponent(SearchIndex.fileName)))
    }

    func process(_ file: URL, _ env: (Archive, SearchIndex), _ options: ImportOptions = ImportOptions(useSummarizer: false)) async throws -> ImportResult {
        try await ImportProcessor.process(file: file, archive: env.0, index: env.1, options: options)
    }

    /// Weißes Bild ohne Text als PDF
    func makeBlankImagePDF() -> URL {
        let url = folder.appendingPathComponent("leer.pdf")
        let ctx = CGContext(data: nil, width: 620, height: 877, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 620, height: 877))
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        pdf.draw(ctx.makeImage()!, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    /// Farbiges Foto-ähnliches Bild mit Text, 600 dpi, als unkomprimiertes PDF (groß)
    func makeHeavyImagePDF() -> URL {
        let url = folder.appendingPathComponent("schwer.pdf")
        let w = 4960, h = 7016
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for i in 0..<60 {  // Farbverläufe, damit es nicht trivial komprimierbar ist
            ctx.setFillColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1)
            ctx.fill(CGRect(x: 0, y: i * h / 60, width: w, height: h / 60))
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Versicherungsschein Hausrat", attributes: [.font: NSFont.systemFont(ofSize: 160), .foregroundColor: NSColor.black]))
        ctx.textPosition = CGPoint(x: 300, y: 6000)
        CTLineDraw(line, ctx)
        var box = CGRect(x: 0, y: 0, width: 595.2, height: 841.9)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        pdf.draw(ctx.makeImage()!, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    @Test func textPDFIsArchivedUnchangedWithMetadata() async throws {
        let env = try makeEnv()
        let source = helpers.makeTextPDF()
        let result = try await process(source, env, ImportOptions(pdfPreset: .kb40, useSummarizer: false))
        #expect(result.number == 1)
        let pdf = try #require(PDFDocument(url: result.url))
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 0)?.string?.contains("Online-Rechnung Telekom") == true)
        #expect(pdf.page(at: 0)?.string?.contains("Nr. 000001") == true)
        #expect(pdf.page(at: 0)?.annotations.contains { $0.url != nil } == true)  // Link erhalten
        let meta = try #require(PDFMetadata.read(pdf))
        #expect(meta.number == 1)
        #expect(meta.source == .pdf)
        #expect(meta.originalFileName == source.lastPathComponent)
        #expect(meta.originalSHA256?.count == 64)
        #expect(meta.pages == [.embedded, .embedded])
        #expect(meta.ocr == nil)
        // nur Textseiten → nichts umzuwandeln
        #expect(meta.compression?.applied == false)
        #expect(try env.1.search("telekom").map(\.number) == [1])
    }

    @Test func imagePDFGetsOCR() async throws {
        let env = try makeEnv()
        let result = try await process(helpers.makeImagePDF(), env)
        #expect(PDFDocument(url: result.url)?.string?.contains("Mahnung Finanzamt") == true)
        #expect(result.meta.pages == [.ocr])
        #expect(result.meta.ocr?.engine == "Apple Vision")
    }

    @Test func heavyImagePageIsCompressed() async throws {
        let env = try makeEnv()
        let source = makeHeavyImagePDF()
        let before = try Data(contentsOf: source).count
        let result = try await process(source, env, ImportOptions(pdfPreset: .kb150, colorMode: .gray, useSummarizer: false))
        let after = try Data(contentsOf: result.url).count
        #expect(result.meta.compression?.applied == true)
        #expect(after < before / 2, "vorher \(before), nachher \(after)")
        #expect(after < 450_000, "Ziel ca. 150 KB, erhalten \(after)")
        #expect(PDFDocument(url: result.url)?.string?.contains("Versicherungsschein") == true)
    }

    @Test func pngBecomesPDF() async throws {
        let env = try makeEnv()
        let png = folder.appendingPathComponent("scan.png")
        try ImageTools.writePNG(PDFBuilderTests.renderPage("Kaufvertrag vom 03.05.2025"), to: png)
        let result = try await process(png, env)
        let pdf = try #require(PDFDocument(url: result.url))
        #expect(pdf.pageCount == 1)
        #expect(pdf.string?.contains("Kaufvertrag") == true)
        #expect(Archive.formatDate(result.date) == "2025-05-03")
        #expect(result.meta.dateSource == .text)
        #expect(!result.issues.contains(.noDate))
        #expect(result.meta.source == .image)
    }

    @Test func jpegIsEmbeddedUnchangedWithOriginalPreset() async throws {
        let env = try makeEnv()
        let jpegURL = folder.appendingPathComponent("foto.jpg")
        let jpeg = try #require(PageCompressor.jpegData(PDFBuilderTests.renderPage("Quittung Baumarkt"), quality: 0.8))
        try jpeg.write(to: jpegURL)
        let result = try await process(jpegURL, env, ImportOptions(imagePreset: .original, useSummarizer: false))
        let size = try Data(contentsOf: result.url).count
        #expect(size < jpeg.count + 60_000, "JPEG \(jpeg.count), PDF \(size)")
        #expect(result.meta.compression == nil)
    }

    @Test func duplicatesAreRejected() async throws {
        let env = try makeEnv()
        let source = helpers.makeTextPDF()
        _ = try await process(source, env)
        await #expect(throws: ImportError.duplicate(number: 1, path: try env.1.search("").first!.path)) {
            try await process(source, env)
        }
        #expect(env.0.peekNextNumber() == 2)
    }

    @Test func brokenAndUnsupportedFilesThrow() async throws {
        let env = try makeEnv()
        let broken = folder.appendingPathComponent("kaputt.pdf")
        try Data("kein pdf".utf8).write(to: broken)
        await #expect(throws: ImportError.self) { try await process(broken, env) }
        let docx = folder.appendingPathComponent("brief.docx")
        try Data("x".utf8).write(to: docx)
        await #expect(throws: ImportError.self) { try await process(docx, env) }
        #expect(env.0.peekNextNumber() == 1)  // keine Nummer verbraucht
    }

    @Test func issuesAreStoredInPDFAndIndex() async throws {
        let env = try makeEnv()
        let result = try await process(makeBlankImagePDF(), env)
        #expect(result.issues.contains(.noText(pages: [1])))
        #expect(result.issues.contains(.noDate))
        #expect(result.issues.contains { if case .noSuggestion = $0 { return true }; return false })
        #expect(PDFMetadata.read(url: result.url)?.issues == result.issues)
        #expect(try env.1.search("", onlyIssues: true).map(\.number) == [result.number])
        #expect(try env.1.countWithIssues() == 1)
    }

    @Test func rebuildRestoresEverythingFromPDFs() async throws {
        let env = try makeEnv()
        let result = try await process(makeBlankImagePDF(), env)
        _ = try await process(helpers.makeTextPDF(), env)
        try env.1.sync(folder: env.0.folder, full: true)
        let records = try env.1.search("")
        #expect(records.count == 2)
        let restored = try #require(records.first { $0.number == result.number })
        #expect(restored.meta == result.meta)
        #expect(restored.issues == result.issues)
        #expect(try env.1.search("", onlyIssues: true).count == 2)  // beide ohne Titel (KI im Test aus)
        // Originalname durchsuchbar, Duplikatprüfung funktioniert auch nach dem Neuaufbau
        #expect(try env.1.search("leer").map(\.number) == [result.number])
        #expect(try env.1.record(forSHA256: result.meta.originalSHA256!)?.number == result.number)
    }

    @Test(.enabled(if: Summarizer.isAvailable, "Apple Intelligence nicht verfügbar"))
    func withAppleIntelligence() async throws {
        let env = try makeEnv()
        let png = folder.appendingPathComponent("rechnung.png")
        try ImageTools.writePNG(PDFBuilderTests.renderPage("Rechnung Stadtwerke 18.09.2026"), to: png)
        let result = try await process(png, env, ImportOptions())
        #expect(!result.title.isEmpty)
        #expect(result.meta.titleSource == .ai)
        #expect(result.url.lastPathComponent.hasPrefix("2026-09-18_000001_"))
    }
}

struct MetadataTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Meta-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    let date = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 18, hour: 12).date!

    func sampleMeta(number: Int) -> DocumentMetadata {
        DocumentMetadata(number: number, documentDate: date, dateSource: .text, titleSource: .ai, titleUpdated: date,
                         archivedAt: date, source: .scan, scan: .init(scanner: "Brother MFC-L2710DN", dpi: 300, colorMode: .gray),
                         compression: .init(preset: .kb150, colorMode: .gray, applied: true, originalBytes: 900_000, resultBytes: 140_000),
                         pages: [.ocr], ocr: .init(date: date), issues: [.noDate])
    }

    @Test func roundTripAndUpdateKeepMetadata() throws {
        let archive = try Archive(folder: folder)
        let saved = try archive.save(date: date, title: "Stromrechnung") { number in
            let data = try PDFBuilder.build(pages: [PDFPageInput(image: PDFBuilderTests.renderPage("Strom München"), lines: [])],
                                            number: number, date: date, dpi: 150)
            return try PDFMetadata.finalize(data, meta: sampleMeta(number: number), title: "Stromrechnung", summary: "Ümläute & Sonderzeichen")
        }
        let pdf = try #require(PDFDocument(url: saved.url))
        #expect(PDFMetadata.read(pdf) == sampleMeta(number: 1))
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String == "Ümläute & Sonderzeichen")
        #expect(pdf.page(at: 0)?.string?.contains("Nr. 000001") == true)

        // Bearbeiten: Datum manuell, Problem erledigt – übrige Metadaten bleiben
        let newDate = date.addingTimeInterval(-86400 * 10)
        let updated = try archive.updateMetadata(url: saved.url, date: newDate, title: "Strom SWM", summary: "neu") { meta in
            meta.dateSource = .manual
            meta.issues.removeAll { $0 == .noDate }
        }
        let meta = try #require(PDFMetadata.read(url: updated.url))
        #expect(meta.dateSource == .manual)
        #expect(meta.issues.isEmpty)
        #expect(meta.documentDate == newDate)
        #expect(meta.scan?.scanner == "Brother MFC-L2710DN")
        #expect(meta.compression?.resultBytes == 140_000)
        #expect(updated.url.lastPathComponent == "2026-09-08_000001_Strom-SWM.pdf")
        // Erstellversion bleibt, Änderungsversion wird gesetzt
        #expect(meta.app == sampleMeta(number: 1).app)
        #expect(meta.updatedWith == DocumentMetadata.appName)
    }

    @Test func repairWronglyMigratedLegacy() throws {
        let archive = try Archive(folder: folder)
        // so sah die erste Migration aus: Quelle unbekannt, aber Version „1.0“ und „eigener Text“
        let wrong = DocumentMetadata(number: 1, documentDate: date, dateSource: .unknown, titleSource: .ai, archivedAt: date,
                                     source: .unknown, pages: [.embedded, .none], app: "ScanArchiv 1.0")
        let saved = try archive.save(date: date, title: "Alt") { number in
            let data = try PDFBuilder.build(pages: [PDFPageInput(image: PDFBuilderTests.renderPage("Alt"), lines: []),
                                                    PDFPageInput(image: PDFBuilderTests.renderPage(""), lines: [])],
                                            number: number, date: date, dpi: 150)
            return try PDFMetadata.finalize(data, meta: wrong, title: "Alt", summary: "")
        }
        #expect(try archive.repairLegacyMetadata(url: saved.url))
        let fixed = try #require(PDFMetadata.read(url: saved.url))
        #expect(fixed.app == DocumentMetadata.legacyAppName)
        #expect(fixed.pages == [.unknown, .none])
        #expect(fixed.updatedWith == DocumentMetadata.appName)
        #expect(PDFDocument(url: saved.url)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Alt")
        #expect(try archive.repairLegacyMetadata(url: saved.url) == false)  // zweiter Aufruf ändert nichts

        // normales Dokument bleibt unberührt
        let normal = try archive.save(date: date, title: "Neu") { number in
            let data = try PDFBuilder.build(pages: [PDFPageInput(image: PDFBuilderTests.renderPage("Neu"), lines: [])],
                                            number: number, date: date, dpi: 150)
            return try PDFMetadata.finalize(data, meta: sampleMeta(number: number), title: "Neu", summary: "")
        }
        #expect(try archive.repairLegacyMetadata(url: normal.url) == false)
    }

    @Test func sizesForImports() {
        var meta = sampleMeta(number: 3)
        meta.source = .pdf
        meta.originalFileName = "TK-Ausweis.pdf"
        meta.originalSize = 66_716
        let grown = Dictionary(uniqueKeysWithValues: DocumentInfo.lines(meta: meta, fileSize: 80_239, pageCount: 1).map { ($0.label, $0.value) })
        #expect(grown["Originaldatei"] == "TK-Ausweis.pdf (67 KB)")
        #expect(grown["Dateigröße"] == "80 KB (Original 67 KB, +14 KB für Textebene, Stempel und Metadaten)")
        meta.originalSize = 1_926_408
        let shrunk = Dictionary(uniqueKeysWithValues: DocumentInfo.lines(meta: meta, fileSize: 178_148, pageCount: 1).map { ($0.label, $0.value) })
        #expect(shrunk["Dateigröße"]?.contains("−1,7 MB durch Kompression") == true, "\(shrunk["Dateigröße"] ?? "")")
    }

    @Test func textSourceWording() {
        var meta = sampleMeta(number: 1)
        meta.pages = Array(repeating: .embedded, count: 26)
        #expect(DocumentInfo.textText(meta, pageCount: 26) == "26 Seiten mit vorhandenem Text (keine OCR nötig)")
        meta.pages = [.embedded, .ocr, .ocr, .none, .unknown]
        #expect(DocumentInfo.textText(meta, pageCount: 5) == "1 Seite mit vorhandenem Text (keine OCR nötig) · 2 Seiten per OCR erkannt · 1 Seite mit Text (Herkunft unbekannt, ältere Version) · 1 Seite ohne Text")
    }

    @Test func infoLinesAndTooltip() {
        var meta = sampleMeta(number: 12)
        meta.updatedWith = "ScanArchiv 9.9"
        let lines = DocumentInfo.lines(meta: meta, fileSize: 300_000, pageCount: 2)
        let dict = Dictionary(uniqueKeysWithValues: lines.map { ($0.label, $0.value) })
        #expect(dict["Quelle"] == "Scan")
        #expect(dict["Scan"] == "Brother MFC-L2710DN, 300 dpi, Graustufen")
        #expect(dict["Dokumentdatum"] == "18.09.2026 (aus dem Text)")
        #expect(dict["Kompression"]?.hasPrefix("ca. 150 KB pro Seite, Graustufen:") == true)
        #expect(dict["Zuletzt geändert mit"] == "ScanArchiv 9.9")
        #expect(dict["Originaldatei"] == nil)
        let tooltip = DocumentInfo.tooltip(meta: meta, fileName: "x.pdf", fileSize: 300_000, pageCount: 2)
        #expect(tooltip.hasPrefix("x.pdf\n"))
        #expect(tooltip.contains("Zu prüfen:\n⚠︎ kein Datum gefunden"))
        // fremdes PDF
        #expect(DocumentInfo.lines(meta: nil, fileSize: 1000, pageCount: 3).map(\.label) == ["Seiten", "Dateigröße"])
    }

    @Test func legacyMigration() throws {
        // PDF wie aus früherer Version: ohne ScanArchiv-Metadaten, Probleme in Zusatzdatei
        let archive = try Archive(folder: folder)
        let saved = try archive.save(date: date, title: "Alt") { number in
            try PDFBuilder.build(pages: [PDFPageInput(image: PDFBuilderTests.renderPage("Alter Brief"), lines: [])],
                                 number: number, date: date, dpi: 150, title: "Alter Brief", summary: "von früher")
        }
        try JSONEncoder().encode(["1": [DocumentIssue.noDate]]).write(to: folder.appendingPathComponent(LegacyIssues.fileName))
        #expect(PDFMetadata.read(url: saved.url) == nil)

        let index = try SearchIndex(url: folder.appendingPathComponent(SearchIndex.fileName))
        let legacy = LegacyIssues.load(folder: folder)
        try index.sync(folder: folder, full: true) { url in
            let number = Archive.parse(fileName: url.lastPathComponent)?.number ?? 0
            try? archive.migrateLegacy(url: url, issues: legacy[number] ?? [])
        }
        let meta = try #require(PDFMetadata.read(url: saved.url))
        #expect(meta.number == 1)
        #expect(meta.issues == [.noDate])
        #expect(meta.titleSource == .ai)
        #expect(meta.app == DocumentMetadata.legacyAppName)
        #expect(meta.pages == [.unknown])
        #expect(meta.updatedWith == DocumentMetadata.appName)
        #expect(try index.search("", onlyIssues: true).count == 1)
        #expect(try index.search("brief").first?.title == "Alter Brief")
    }
}

struct PageCompressorTests {
    let a4 = CGSize(width: 595.2, height: 841.9)

    /// A4 bei 300 dpi mit viel Text und etwas Graufläche
    static func textPage(color: Bool = false, lines: Int = 20) -> CGImage {
        let w = 2480, h = 3508
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if color {
            ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            ctx.fill(CGRect(x: 150, y: 3100, width: 600, height: 250))
        }
        for i in 0..<lines {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: "Zeile \(i): Sehr geehrte Damen und Herren, anbei die Rechnung Nr. 4711 über 1.234,56 EUR",
                attributes: [.font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black]))
            ctx.textPosition = CGPoint(x: 150, y: 3000 - CGFloat(i) * 62)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()!
    }

    /// Graustufen: Größe sinkt mit jeder Stufe, 300/150 KB werden erreicht (Text geht nicht unter ~150 dpi).
    @Test func grayPresetsShrink() {
        let page = Self.textPage(color: true)
        let sizes = [SizePreset.kb300, .kb150, .kb80, .kb40].map {
            PageCompressor.encode(page, pageSize: a4, preset: $0, color: .gray).bytes
        }
        #expect(sizes == sizes.sorted(by: >), "\(sizes)")
        #expect(sizes[0] <= 300_000 * 3 / 2)
        #expect(sizes[1] <= 150_000 * 3 / 2)
    }

    /// Schwarz-Weiß erreicht auch die kleinen Ziele.
    @Test(arguments: [SizePreset.kb80, .kb40])
    func blackWhiteHitsSmallTargets(preset: SizePreset) {
        let encoded = PageCompressor.encode(Self.textPage(lines: 45), pageSize: a4, preset: preset, color: .blackWhite)
        #expect(encoded.bytes <= preset.targetBytesA4! * 3 / 2, "\(preset): \(encoded.bytes)")
    }

    /// Saubere Seite: verlustfrei ist kleiner als JPEG → wird genommen.
    @Test func losslessWinsWhenSmaller() {
        let encoded = PageCompressor.encode(Self.textPage(lines: 5), pageSize: a4, preset: .kb300, color: .gray)
        #expect(encoded.image.bitsPerPixel == 8)
        #expect(encoded.dpi > 299)
        #expect(encoded.bytes <= 300_000)
    }

    @Test func blackWhiteIsOneBit() {
        let encoded = PageCompressor.encode(Self.textPage(), pageSize: a4, preset: .kb150, color: .blackWhite)
        #expect(encoded.image.bitsPerPixel == 1)
        #expect(encoded.bytes < 150_000)
    }

    @Test func originalJPEGIsPassedThrough() throws {
        let jpeg = try #require(PageCompressor.jpegData(Self.textPage(), quality: 0.8))
        let encoded = PageCompressor.encode(Self.textPage(), pageSize: a4, preset: .original, color: .original, originalJPEG: jpeg)
        #expect(encoded.bytes == jpeg.count)
    }

    @Test func otsuFindsGapBetweenPeaks() {
        var histogram = [Int](repeating: 0, count: 256)
        histogram[30] = 1000   // Schrift
        histogram[230] = 9000  // Papier
        let t = PageCompressor.otsu(histogram, total: 10_000)
        #expect(t >= 30 && t < 230)
    }
}

struct GlyphlessFontTests {
    /// Unsichtbarer Text in der Schrift ohne Zeichenformen bleibt exakt auslesbar – auch Umlaute,
    /// Sonderzeichen und Zeichen außerhalb des Zeichenvorrats (Ersatzschrift).
    @Test func textStaysExtractable() throws {
        let text = "Größe 12,50 € – „Müller“ & Söhne · Straße ÄÖÜ 100 % Ω→"
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = try #require(CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        PDFBuilder.drawInvisibleText([OCRLine(text: text, box: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.02))], in: ctx,
                                     pageSize: box.size)
        ctx.endPDFPage()
        ctx.closePDF()
        let pdf = try #require(PDFDocument(data: data as Data))
        #expect(pdf.string?.trimmingCharacters(in: .whitespacesAndNewlines) == text)
        #expect(data.length < 6_000, "\(data.length) Bytes")
    }

    @Test func fontIsValid() {
        let font = GlyphlessFont.font(size: 12)
        #expect(CTFontCopyPostScriptName(font) as String == GlyphlessFont.postScriptName)
        var chars = Array("Aä€".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        #expect(CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count))
        #expect(Set(glyphs).count == 3 && !glyphs.contains(0))
    }
}
