import CoreGraphics
import CoreText
import Foundation

/// Hängt Stempel, OCR-Textebene und Metadaten per **inkrementellem Update** an ein PDF an.
/// Der Inhalt des Originals bleibt bitgenau erhalten (Bilder, Schriften, Objekt-Streams) –
/// im Gegensatz zum Neuschreiben durch PDFKit, das z. B. CCITT-Bilder neu kodiert und
/// Schriften mehrfach einbettet.
public enum PDFAppender {
    /// OCR-Zeilen einer Bildseite (Koordinaten normiert auf die angezeigte Seite).
    public struct Overlay {
        public var pageIndex: Int
        public var lines: [OCRLine]

        public init(pageIndex: Int, lines: [OCRLine]) {
            self.pageIndex = pageIndex
            self.lines = lines
        }
    }

    static let stampFontName = "SAStamp"
    static let textFontName = "SAText"
    static let metadataKey = "ScanArchiv"

    /// Stempel auf Seite 1, OCR-Ebenen, Metadaten-Anmerkung und Dokumentinfos anhängen.
    /// - Parameter order: neue Seitenreihenfolge (Indizes der Originalseiten); `Overlay.pageIndex` und der
    ///   Stempel beziehen sich dann auf die **neue** Reihenfolge.
    public static func stamp(original: Data, stampText: String, overlays: [Overlay],
                             meta: DocumentMetadata, title: String, summary: String, order: [Int]? = nil) throws -> Data {
        let doc = try PDFRawDocument(data: original)
        let update = PDFIncrementalUpdate(doc)
        var pages = try doc.pages()
        guard !pages.isEmpty else { throw PDFRawError.malformed("keine Seiten") }
        if let order { pages = try reorder(pages, order: order, in: doc, update: update) }

        let stampFont = update.add(.dict(PDFDict([
            ("Type", .name("Font")), ("Subtype", .name("Type1")),
            ("BaseFont", .name("Helvetica-Bold")), ("Encoding", .name("WinAnsiEncoding")),
        ])))
        let usable = overlays.filter { $0.pageIndex < pages.count && !$0.lines.isEmpty }
        let textFont: (ref: PDFValue, gids: [UInt32: Int], codepoints: [UInt32])? =
            usable.isEmpty ? nil : try addGlyphlessFont(for: usable.flatMap { $0.lines.map(\.text) }, to: update)

        for (index, original) in pages.enumerated() {
            var page = original
            let overlay = usable.first { $0.pageIndex == index }
            guard index == 0 || overlay != nil else { continue }
            let (toPage, size) = geometry(of: page)
            var ops = ""
            if let overlay, let textFont {
                ops += invisibleText(overlay.lines, pageSize: size, gids: textFont.gids, codepoints: textFont.codepoints)
            }
            if index == 0 { ops += stampOps(stampText, pageSize: size) }

            var fonts: [(String, PDFValue)] = []
            if index == 0 { fonts.append((stampFontName, stampFont)) }
            if overlay != nil, let textFont { fonts.append((textFontName, textFont.ref)) }
            try appendContent(ops, transform: toPage, fonts: fonts, to: &page, in: doc, update: update)
            if index == 0 {
                page.dict["Annots"] = .array(try setMetadataAnnotation(meta, pageDict: page.dict, pageRef: page.ref, in: doc, update: update))
            }
            update.set(page.ref, .dict(page.dict))
        }
        try setInfo(meta, title: title, summary: summary, in: doc, update: update)
        return update.write()
    }

    /// Hängt Zeichenbefehle (in Koordinaten der angezeigten Seite) als eigenen Inhaltsstrom an.
    /// Ein vorangestelltes „q“ und das „Q“ am Anfang sorgen dafür, dass die Befehle mit dem
    /// ursprünglichen Grafikzustand der Seite starten. Setzt `Contents`/`Resources` in `page.dict`.
    static func appendContent(_ ops: String, transform: CGAffineTransform, fonts: [(String, PDFValue)],
                              to page: inout PDFRawDocument.PageInfo, in doc: PDFRawDocument,
                              update: PDFIncrementalUpdate) throws {
        let open = update.addStream(Array("q\n".utf8), compress: false)
        let content = update.addStream(Array(("Q\nq\n" + matrix(transform) + " cm\n" + ops + "Q\n").utf8))
        page.dict["Contents"] = .array([open] + (try contentsList(of: page.dict, in: doc)) + [content])
        if !fonts.isEmpty { page.dict["Resources"] = .dict(try resources(of: page, in: doc, addingFonts: fonts)) }
    }

    /// Seiten eines archivierten Dokuments umsortieren und drehen (inkrementell).
    /// Wird eine andere Seite zur ersten oder die erste gedreht, wandert der Stempel mit:
    /// Die alte Stempelfläche wird weiß überdeckt, die neue erste Seite bekommt denselben Stempeltext,
    /// und die Metadaten-Anmerkung zieht auf die neue erste Seite um.
    /// - Parameters:
    ///   - order: Indizes der bisherigen Seiten in neuer Reihenfolge
    ///   - rotations: zusätzliche Drehung im Uhrzeigersinn je neuer Position (Vielfache von 90)
    ///   - stampText: Text des vorhandenen Stempels
    public static func rearrange(_ data: Data, order: [Int], rotations: [Int], stampText: String,
                                 meta: DocumentMetadata, title: String, summary: String) throws -> Data {
        let doc = try PDFRawDocument(data: data)
        let update = PDFIncrementalUpdate(doc)
        let original = try doc.pages()
        guard !original.isEmpty else { throw PDFRawError.malformed("keine Seiten") }
        guard rotations.count == order.count, rotations.allSatisfy({ $0 % 90 == 0 }) else {
            throw PDFRawError.malformed("ungültige Drehung")
        }
        var pages = try reorder(original, order: order, in: doc, update: update)
        for i in pages.indices where rotations[i] % 360 != 0 {
            let current = (pages[i].dict["Rotate"] ?? pages[i].inherited["Rotate"])?.int ?? 0
            pages[i].dict["Rotate"] = .int(((current + rotations[i]) % 360 + 360) % 360)
        }

        if order[0] != 0 || rotations[0] % 360 != 0 {
            // alte erste Seite: Stempel überdecken (in ihrer bisherigen Lage) und Metadaten-Anmerkung entfernen
            let oldPosition = order.firstIndex(of: 0)!
            let (oldTransform, oldSize) = geometry(of: original[0])
            try appendContent(coverStampOps(stampText, pageSize: oldSize), transform: oldTransform, fonts: [],
                              to: &pages[oldPosition], in: doc, update: update)
            let remaining = try annotsList(of: pages[oldPosition].dict, in: doc).filter { item in
                guard case let .ref(num, _) = item, case let .dict(annot) = try doc.object(num) else { return true }
                return annot[metadataKey] == nil
            }
            pages[oldPosition].dict["Annots"] = .array(remaining)
            // neue erste Seite: Stempel in ihrer (neuen) Lage
            let stampFont = update.add(.dict(PDFDict([
                ("Type", .name("Font")), ("Subtype", .name("Type1")),
                ("BaseFont", .name("Helvetica-Bold")), ("Encoding", .name("WinAnsiEncoding")),
            ])))
            let (toPage, size) = geometry(of: pages[0])
            try appendContent(stampOps(stampText, pageSize: size), transform: toPage, fonts: [(stampFontName, stampFont)],
                              to: &pages[0], in: doc, update: update)
        }
        pages[0].dict["Annots"] = .array(try setMetadataAnnotation(meta, pageDict: pages[0].dict, pageRef: pages[0].ref,
                                                                   in: doc, update: update))
        for page in pages { update.set(page.ref, .dict(page.dict)) }
        try setInfo(meta, title: title, summary: summary, in: doc, update: update)
        return update.write()
    }

    /// Neuer, flacher Seitenbaum in der gewünschten Reihenfolge. Geerbte Attribute wandern in die Seiten,
    /// damit Größe, Drehung und Ressourcen erhalten bleiben. Liefert die Seiten in neuer Reihenfolge.
    static func reorder(_ pages: [PDFRawDocument.PageInfo], order: [Int], in doc: PDFRawDocument,
                        update: PDFIncrementalUpdate) throws -> [PDFRawDocument.PageInfo] {
        guard order.sorted() == Array(pages.indices) else { throw PDFRawError.malformed("ungültige Seitenreihenfolge") }
        guard case let .ref(rootNum, _)? = doc.trailer["Root"], case var .dict(catalog) = try doc.object(rootNum) else {
            throw PDFRawError.malformed("Katalog")
        }
        let treeNum = update.allocate()
        let reordered = order.map { index -> PDFRawDocument.PageInfo in
            var page = pages[index]
            for key in ["Resources", "MediaBox", "CropBox", "Rotate"] where page.dict[key] == nil {
                if let value = page.inherited[key] { page.dict[key] = value }
            }
            page.dict["Parent"] = .ref(treeNum, 0)
            update.set(page.ref, .dict(page.dict))
            return page
        }
        update.set(treeNum, .dict(PDFDict([
            ("Type", .name("Pages")),
            ("Kids", .array(reordered.map { .ref($0.ref, doc.generation(of: $0.ref)) })),
            ("Count", .int(reordered.count)),
        ])))
        catalog["Pages"] = .ref(treeNum, 0)
        update.set(rootNum, .dict(catalog))
        return reordered
    }

    /// Nur Metadaten (Anmerkung + Dokumentinfos) aktualisieren – z. B. nach „Bearbeiten“.
    public static func updateMetadata(_ data: Data, meta: DocumentMetadata, title: String, summary: String) throws -> Data {
        let doc = try PDFRawDocument(data: data)
        let update = PDFIncrementalUpdate(doc)
        guard let first = try doc.pages().first else { throw PDFRawError.malformed("keine Seiten") }
        let annots = try setMetadataAnnotation(meta, pageDict: first.dict, pageRef: first.ref, in: doc, update: update)
        if try annotsList(of: first.dict, in: doc).count != annots.count {
            var dict = first.dict
            dict["Annots"] = .array(annots)
            update.set(first.ref, .dict(dict))
        }
        try setInfo(meta, title: title, summary: summary, in: doc, update: update)
        return update.write()
    }

    // MARK: Seite

    /// Transformation angezeigte Seite → Seitenraum und angezeigte Größe (Drehung, CropBox).
    static func geometry(of page: PDFRawDocument.PageInfo) -> (CGAffineTransform, CGSize) {
        func rect(_ value: PDFValue?) -> CGRect? {
            guard let a = value?.array?.compactMap(\.number), a.count == 4 else { return nil }
            return CGRect(x: min(a[0], a[2]), y: min(a[1], a[3]), width: abs(a[2] - a[0]), height: abs(a[3] - a[1]))
        }
        let box = rect(page.dict["CropBox"] ?? page.inherited["CropBox"])
            ?? rect(page.dict["MediaBox"] ?? page.inherited["MediaBox"])
            ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        let rotation = (page.dict["Rotate"] ?? page.inherited["Rotate"])?.int ?? 0
        let (t, size) = PDFStamper.displayToPage(rotation: rotation, box: box)
        return (t, size)
    }

    static func matrix(_ t: CGAffineTransform) -> String {
        [t.a, t.b, t.c, t.d, t.tx, t.ty].map { PDFValue.format(Double($0)) }.joined(separator: " ")
    }

    static func contentsList(of dict: PDFDict, in doc: PDFRawDocument) throws -> [PDFValue] {
        guard let contents = dict["Contents"] else { return [] }
        if case let .ref(num, _) = contents, case let .array(items) = try doc.object(num) { return items }
        if case let .array(items) = contents { return items }
        return [contents]
    }

    static func annotsList(of dict: PDFDict, in doc: PDFRawDocument) throws -> [PDFValue] {
        guard let annots = dict["Annots"] else { return [] }
        return (try doc.resolve(annots)).array ?? []
    }

    /// Wirksame Ressourcen der Seite (auch geerbt) als eigenes Dictionary, ergänzt um Schriften.
    static func resources(of page: PDFRawDocument.PageInfo, in doc: PDFRawDocument,
                          addingFonts fonts: [(String, PDFValue)]) throws -> PDFDict {
        var resources = (try doc.resolve(page.dict["Resources"] ?? page.inherited["Resources"] ?? .dict(PDFDict()))).dict ?? PDFDict()
        var fontDict = (try doc.resolve(resources["Font"] ?? .dict(PDFDict()))).dict ?? PDFDict()
        for (name, ref) in fonts { fontDict[name] = ref }
        resources["Font"] = .dict(fontDict)
        return resources
    }

    // MARK: Stempel (Standardschrift, keine Einbettung)

    static func stampOps(_ text: String, pageSize: CGSize) -> String {
        let (rect, origin) = PDFBuilder.stampGeometry(text, pageSize: pageSize)
        let box = rectOps(rect)
        let encoded = PDFValue.string(text.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data(text.utf8)).serialized()
        return """
            q 1 1 1 rg \(box) re f 0.85 0.05 0.05 RG 0.75 w \(box) re S
            BT 0.85 0.05 0.05 rg /\(stampFontName) 9 Tf 1 0 0 1 \(PDFValue.format(Double(origin.x))) \(PDFValue.format(Double(origin.y))) Tm \(String(decoding: encoded, as: UTF8.self)) Tj ET Q

            """
    }

    /// Weiße Fläche über einem früheren Stempel (etwas größer, damit auch der Rahmen verschwindet).
    static func coverStampOps(_ text: String, pageSize: CGSize) -> String {
        let rect = PDFBuilder.stampGeometry(text, pageSize: pageSize).box.insetBy(dx: -1, dy: -1)
        return "q 1 1 1 rg \(rectOps(rect)) re f Q\n"
    }

    static func rectOps(_ r: CGRect) -> String {
        [r.minX, r.minY, r.width, r.height].map { PDFValue.format(Double($0)) }.joined(separator: " ")
    }

    // MARK: OCR-Ebene (Schrift ohne Zeichenformen, nur benutzte Zeichen)

    static func addGlyphlessFont(for texts: [String], to update: PDFIncrementalUpdate) throws
        -> (ref: PDFValue, gids: [UInt32: Int], codepoints: [UInt32]) {
        let used = Set(texts.flatMap { $0.unicodeScalars.map(\.value) }).intersection(GlyphlessFont.supported)
        let codepoints = used.sorted()
        var gids: [UInt32: Int] = [:]
        for (i, cp) in codepoints.enumerated() { gids[cp] = i + 1 }

        let fontData = GlyphlessFont.makeFontData(codepoints: codepoints)
        let fontFile = update.addStream([UInt8](fontData), dict: PDFDict([("Length1", .int(fontData.count))]))
        let baseFont = PDFValue.name("SAGLYP+" + GlyphlessFont.postScriptName)
        let descriptor = update.add(.dict(PDFDict([
            ("Type", .name("FontDescriptor")), ("FontName", baseFont), ("Flags", .int(4)),
            ("FontBBox", .array([.int(0), .int(-200), .int(1000), .int(800)])), ("ItalicAngle", .int(0)),
            ("Ascent", .int(800)), ("Descent", .int(-200)), ("CapHeight", .int(700)), ("StemV", .int(80)),
            ("FontFile2", fontFile),
        ])))
        let widths = PDFValue.array([.int(1), .array(codepoints.map { .int(Int(GlyphlessFont.advance(for: $0))) })])
        let cidFont = update.add(.dict(PDFDict([
            ("Type", .name("Font")), ("Subtype", .name("CIDFontType2")), ("BaseFont", baseFont),
            ("CIDSystemInfo", .dict(PDFDict([("Registry", .string(Data("Adobe".utf8))),
                                             ("Ordering", .string(Data("Identity".utf8))), ("Supplement", .int(0))]))),
            ("FontDescriptor", descriptor), ("DW", .int(Int(GlyphlessFont.advance))), ("W", widths),
            ("CIDToGIDMap", .name("Identity")),
        ])))
        let toUnicode = update.addStream(Array(toUnicodeCMap(codepoints).utf8))
        let font = update.add(.dict(PDFDict([
            ("Type", .name("Font")), ("Subtype", .name("Type0")), ("BaseFont", baseFont),
            ("Encoding", .name("Identity-H")), ("DescendantFonts", .array([cidFont])), ("ToUnicode", toUnicode),
        ])))
        return (font, gids, codepoints)
    }

    static func toUnicodeCMap(_ codepoints: [UInt32]) -> String {
        var cmap = """
            /CIDInit /ProcSet findresource begin 12 dict begin begincmap
            /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
            /CMapName /Adobe-Identity-UCS def /CMapType 2 def
            1 begincodespacerange <0000> <FFFF> endcodespacerange

            """
        for chunk in stride(from: 0, to: codepoints.count, by: 100) {
            let part = codepoints[chunk..<min(chunk + 100, codepoints.count)]
            cmap += "\(part.count) beginbfchar\n"
            for (offset, cp) in part.enumerated() {
                let utf16 = String(Character(Unicode.Scalar(cp)!)).utf16.map { String(format: "%04X", $0) }.joined()
                cmap += String(format: "<%04X> <%@>\n", chunk + offset + 1, utf16)
            }
            cmap += "endbfchar\n"
        }
        cmap += "endcmap CMapName currentdict /CMap defineresource pop end end\n"
        return cmap
    }

    static func invisibleText(_ lines: [OCRLine], pageSize: CGSize, gids: [UInt32: Int], codepoints: [UInt32]) -> String {
        var ops = "BT 3 Tr\n"
        for line in lines {
            let scalars = line.text.unicodeScalars.map(\.value).filter { gids[$0] != nil }
            guard !scalars.isEmpty else { continue }
            let rect = CGRect(x: line.box.minX * pageSize.width, y: line.box.minY * pageSize.height,
                              width: line.box.width * pageSize.width, height: line.box.height * pageSize.height)
            guard rect.width > 0, rect.height > 0 else { continue }
            let units = scalars.reduce(0.0) { $0 + Double(GlyphlessFont.advance(for: $1)) } / 1000
            var fontSize = Double(rect.height) * 0.85
            // zu schmale Zeile: Schrift verkleinern statt stauchen (sonst liest PDFKit „E U R O …“)
            if Double(rect.width) < units * fontSize * 0.95 { fontSize = Double(rect.width) / units }
            let scale = Double(rect.width) / (units * fontSize) * 100
            let hex = scalars.map { String(format: "%04X", gids[$0]!) }.joined()
            ops += "/\(textFontName) \(PDFValue.format(fontSize)) Tf \(PDFValue.format(scale)) Tz "
                + "1 0 0 1 \(PDFValue.format(Double(rect.minX))) \(PDFValue.format(Double(rect.minY + rect.height * 0.15))) Tm <\(hex)> Tj\n"
        }
        return ops + "ET\n"
    }

    // MARK: Metadaten

    /// Setzt/ersetzt die unsichtbare Metadaten-Anmerkung; liefert die neue /Annots-Liste der Seite.
    static func setMetadataAnnotation(_ meta: DocumentMetadata, pageDict: PDFDict, pageRef: Int, in doc: PDFRawDocument,
                                      update: PDFIncrementalUpdate) throws -> [PDFValue] {
        var annots = try annotsList(of: pageDict, in: doc)
        let json = PDFValue.text(try meta.encoded())
        for item in annots {
            if case let .ref(num, _) = item, case var .dict(annot) = try doc.object(num), annot[metadataKey] != nil {
                annot[metadataKey] = json
                update.set(num, .dict(annot))
                return annots
            }
        }
        let annot = update.add(.dict(PDFDict([
            ("Type", .name("Annot")), ("Subtype", .name("Text")),
            ("Rect", .array([.int(0), .int(0), .int(0), .int(0)])),
            ("F", .int(2 | 64)),  // versteckt, schreibgeschützt, nicht drucken
            ("P", .ref(pageRef, doc.generation(of: pageRef))),
            (metadataKey, json),
        ])))
        annots.append(annot)
        return annots
    }

    static func setInfo(_ meta: DocumentMetadata, title: String, summary: String, in doc: PDFRawDocument,
                        update: PDFIncrementalUpdate) throws {
        let numberText = Archive.formatNumber(meta.number)
        var info = (try doc.resolve(doc.trailer["Info"] ?? .null)).dict ?? PDFDict()
        info["Title"] = .text(title.isEmpty
            ? Archive.fileName(date: meta.documentDate, number: meta.number).replacingOccurrences(of: ".pdf", with: "") : title)
        info["Subject"] = .text(summary)
        info["Keywords"] = .text("\(numberText), Nr. \(numberText)")
        info["Creator"] = .text(meta.app)
        info["CreationDate"] = .text(pdfDate(meta.archivedAt))
        info["ModDate"] = .text(pdfDate(Date()))
        if case let .ref(num, _)? = doc.trailer["Info"] {
            update.set(num, .dict(info))
        } else {
            update.trailerChanges["Info"] = update.add(.dict(info))
        }
    }

    static func pdfDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return "D:\(f.string(from: date))Z"
    }
}
