import CoreText
import Foundation

/// Eine zur Laufzeit erzeugte TrueType-Schrift, deren Zeichen alle **leer** sind.
///
/// Für die unsichtbare OCR-Textebene werden keine Buchstabenformen gebraucht – nur die Zuordnung
/// Zeichen ↔ Glyphe, damit Suchen, Markieren und Kopieren funktionieren. Eine normale Schrift würde
/// dafür 10–15 KB Teilschrift pro PDF einbetten, diese hier nur wenige hundert Bytes.
/// (Gleiches Prinzip wie die „GlyphLessFont“ von OCRmyPDF/Tesseract.)
///
/// Jedes unterstützte Zeichen bekommt eine eigene Glyphe (sonst wäre der Text beim Auslesen nicht
/// eindeutig). Zeichen außerhalb des Zeichenvorrats übernimmt CoreText mit einer Ersatzschrift.
public enum GlyphlessFont {
    static let postScriptName = "ScanArchivGlyphless"
    static let unitsPerEm: UInt16 = 1000
    static let advance: UInt16 = 556

    /// Zeichenbreiten wie Helvetica (in 1/1000 em), damit die Textebene kaum gestreckt werden muss –
    /// sonst hält PDFKit die Lücken zwischen den Buchstaben für Leerzeichen („E U R O …“).
    static let advances: [UInt16] = {
        let helvetica = CTFontCreateWithName("Helvetica" as CFString, CGFloat(unitsPerEm), nil)
        return codepoints.map { cp in
            guard let scalar = Unicode.Scalar(cp) else { return advance }
            var chars = Array(String(Character(scalar)).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            guard CTFontGetGlyphsForCharacters(helvetica, &chars, &glyphs, chars.count), glyphs[0] != 0 else { return advance }
            var size = CGSize.zero
            CTFontGetAdvancesForGlyphs(helvetica, .horizontal, &glyphs, &size, 1)
            return UInt16(max(1, min(2000, size.width.rounded())))
        }
    }()

    /// Unterstützte Zeichen. Leere Glyphen kosten nur wenige Bytes, und ins PDF kommen ohnehin nur die
    /// benutzten – der Vorrat ist daher großzügig, damit keine Ersatzschrift eingebettet werden muss.
    static let codepoints: [UInt32] = {
        let ranges: [ClosedRange<UInt32>] = [
            0x20...0x7E,     // Basis-Latein
            0xA0...0x24F,    // Latin-1, Latin Extended-A/B (Umlaute, Akzente)
            0x370...0x3FF,   // Griechisch
            0x400...0x4FF,   // Kyrillisch
            0x1E00...0x1EFF, // Latin Extended Additional
            0x2010...0x205E, // Satzzeichen (Striche, Anführungszeichen, …)
            0x2070...0x209F, // hoch-/tiefgestellte Ziffern
            0x20A0...0x20C0, // Währungen (€ …)
            0x2100...0x214F, // buchstabenähnliche Symbole (№, ™, ℃ …)
            0x2150...0x218B, // Brüche, römische Zahlen
            0x2190...0x21FF, // Pfeile
            0x2200...0x22FF, // mathematische Operatoren
            0x2460...0x24FF, // eingekreiste Ziffern
            0x2500...0x25FF, // Rahmen, Blöcke, geometrische Formen
            0x2600...0x26FF, // Symbole (☐ ☑ ✓ …)
            0x2700...0x27BF, // Dingbats
            0xFB00...0xFB06, // Ligaturen (ﬁ ﬂ)
        ]
        return ranges.flatMap { Array($0) }
    }()

    nonisolated(unsafe) private static var descriptor: CTFontDescriptor?
    private static let lock = NSLock()

    /// Die Schrift in der gewünschten Größe.
    public static func font(size: CGFloat) -> CTFont {
        lock.lock(); defer { lock.unlock() }
        if descriptor == nil {
            descriptor = CTFontManagerCreateFontDescriptorFromData(makeFontData() as CFData)
        }
        guard let descriptor else { return CTFontCreateWithName("Helvetica" as CFString, size, nil) }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    // MARK: TrueType-Erzeugung

    static func makeFontData() -> Data {
        let numGlyphs = UInt16(codepoints.count + 1)  // Glyphe 0 = .notdef
        var tables: [(tag: String, data: Data)] = []

        // head
        var head = Data()
        head.u32(0x0001_0000); head.u32(0x0001_0000)   // version, fontRevision
        head.u32(0)                                     // checkSumAdjustment (später)
        head.u32(0x5F0F_3CF5)                           // magicNumber
        head.u16(0x000B); head.u16(unitsPerEm)          // flags, unitsPerEm
        head.u64(0); head.u64(0)                        // created, modified
        head.i16(0); head.i16(-200); head.i16(Int16(advance)); head.i16(800)  // xMin, yMin, xMax, yMax
        head.u16(0); head.u16(8); head.i16(2)           // macStyle, lowestRecPPEM, fontDirectionHint
        head.i16(0); head.i16(0)                        // indexToLocFormat (short), glyphDataFormat
        tables.append(("head", head))

        // hhea
        var hhea = Data()
        hhea.u32(0x0001_0000)
        hhea.i16(800); hhea.i16(-200); hhea.i16(0)      // ascender, descender, lineGap
        hhea.u16(max(advance, advances.max() ?? advance)); hhea.i16(0); hhea.i16(0); hhea.i16(0)  // advanceWidthMax, minLSB, minRSB, xMaxExtent
        hhea.i16(1); hhea.i16(0); hhea.i16(0)           // caretSlopeRise, caretSlopeRun, caretOffset
        for _ in 0..<4 { hhea.i16(0) }                  // reserved
        hhea.i16(0); hhea.u16(numGlyphs)                // metricDataFormat, numberOfHMetrics
        tables.append(("hhea", hhea))

        // maxp (TrueType, Version 1.0)
        var maxp = Data()
        maxp.u32(0x0001_0000); maxp.u16(numGlyphs)
        for value: UInt16 in [0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0] { maxp.u16(value) }
        tables.append(("maxp", maxp))

        // OS/2 (Version 4) – fsType 0: Einbetten erlaubt
        var os2 = Data()
        os2.u16(4); os2.i16(Int16(advance)); os2.u16(400); os2.u16(5); os2.u16(0)
        for value: Int16 in [650, 600, 0, 75, 650, 600, 0, 350, 50, 300] { os2.i16(value) }
        os2.i16(0)                                       // sFamilyClass
        os2.append(Data(count: 10))                      // panose
        os2.u32(0b111 | (1 << 31)); os2.u32(1 << 1); os2.u32(0); os2.u32(0)  // ulUnicodeRange1-4
        os2.append("NONE".data(using: .ascii)!)          // achVendID
        os2.u16(0x40); os2.u16(0x20); os2.u16(0xFFFF)   // fsSelection (REGULAR), first/last char
        os2.i16(800); os2.i16(-200); os2.i16(0)          // sTypoAscender/Descender/LineGap
        os2.u16(800); os2.u16(200)                       // usWinAscent/Descent
        os2.u32(1); os2.u32(0)                           // ulCodePageRange1/2
        os2.i16(500); os2.i16(700); os2.u16(0); os2.u16(32); os2.u16(1)  // xHeight, capHeight, default, break, maxContext
        tables.append(("OS/2", os2))

        // hmtx: Breite je Glyphe (.notdef + Zeichen), lsb 0
        var hmtx = Data()
        hmtx.u16(advance); hmtx.i16(0)
        for width in advances { hmtx.u16(width); hmtx.i16(0) }
        tables.append(("hmtx", hmtx))

        // cmap (Format 4): zusammenhängende Bereiche → fortlaufende Glyphen
        tables.append(("cmap", makeCmap()))

        // loca (kurz) + glyf: alle Glyphen leer
        var loca = Data()
        for _ in 0...Int(numGlyphs) { loca.u16(0) }
        tables.append(("loca", loca))
        tables.append(("glyf", Data(count: 4)))

        // name
        tables.append(("name", makeName()))

        // post (Version 3: keine Glyphnamen)
        var post = Data()
        post.u32(0x0003_0000); post.u32(0); post.i16(-100); post.i16(50)
        post.u32(0); post.u32(0); post.u32(0); post.u32(0); post.u32(0)
        tables.append(("post", post))

        return assemble(tables)
    }

    private static func makeCmap() -> Data {
        // Segmente aus aufeinanderfolgenden Codepoints
        var segments: [(start: UInt16, end: UInt16, firstGlyph: UInt16)] = []
        for (i, cp) in codepoints.enumerated() {
            let glyph = UInt16(i + 1)
            if let last = segments.last, UInt32(last.end) + 1 == cp,
               UInt32(last.firstGlyph) + (UInt32(last.end) - UInt32(last.start)) + 1 == UInt32(glyph) {
                segments[segments.count - 1].end = UInt16(cp)
            } else {
                segments.append((UInt16(cp), UInt16(cp), glyph))
            }
        }
        segments.append((0xFFFF, 0xFFFF, 1))  // Pflicht-Endsegment
        let segCount = UInt16(segments.count)
        var searchRange: UInt16 = 1, entrySelector: UInt16 = 0
        while searchRange * 2 <= segCount { searchRange *= 2; entrySelector += 1 }
        searchRange *= 2

        var sub = Data()
        sub.u16(4); sub.u16(0); sub.u16(0)  // format, length (später), language
        sub.u16(segCount * 2); sub.u16(searchRange); sub.u16(entrySelector); sub.u16(segCount * 2 - searchRange)
        for s in segments { sub.u16(s.end) }
        sub.u16(0)  // reservedPad
        for s in segments { sub.u16(s.start) }
        for s in segments { sub.u16(s.start == 0xFFFF ? 1 : UInt16(truncatingIfNeeded: Int(s.firstGlyph) - Int(s.start))) }
        for _ in segments { sub.u16(0) }  // idRangeOffset
        sub.replaceSubrange(2..<4, with: UInt16(sub.count).bigEndianData)

        var cmap = Data()
        cmap.u16(0); cmap.u16(1)                 // version, numTables
        cmap.u16(3); cmap.u16(1); cmap.u32(12)   // Windows, Unicode BMP, offset
        cmap.append(sub)
        return cmap
    }

    private static func makeName() -> Data {
        let records: [(id: UInt16, text: String)] = [
            (1, postScriptName), (2, "Regular"), (4, postScriptName), (6, postScriptName),
        ]
        var strings = Data()
        var entries = Data()
        for record in records {
            let utf16 = record.text.data(using: .utf16BigEndian)!
            entries.u16(3); entries.u16(1); entries.u16(0x409); entries.u16(record.id)
            entries.u16(UInt16(utf16.count)); entries.u16(UInt16(strings.count))
            strings.append(utf16)
        }
        var name = Data()
        name.u16(0); name.u16(UInt16(records.count)); name.u16(UInt16(6 + entries.count))
        name.append(entries)
        name.append(strings)
        return name
    }

    private static func assemble(_ tables: [(tag: String, data: Data)]) -> Data {
        let sorted = tables.sorted { $0.tag < $1.tag }
        let numTables = UInt16(sorted.count)
        var searchRange: UInt16 = 1, entrySelector: UInt16 = 0
        while searchRange * 2 <= numTables { searchRange *= 2; entrySelector += 1 }
        searchRange *= 16

        var font = Data()
        font.u32(0x0001_0000); font.u16(numTables); font.u16(searchRange); font.u16(entrySelector)
        font.u16(numTables * 16 - searchRange)
        var offset = 12 + 16 * sorted.count
        var body = Data()
        var headOffset = 0
        for table in sorted {
            font.append(table.tag.data(using: .ascii)!)
            font.u32(checksum(table.data)); font.u32(UInt32(offset)); font.u32(UInt32(table.data.count))
            if table.tag == "head" { headOffset = offset }
            var padded = table.data
            while padded.count % 4 != 0 { padded.append(0) }
            body.append(padded)
            offset += padded.count
        }
        font.append(body)
        let adjustment = 0xB1B0_AFBA &- checksum(font)
        font.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: adjustment.bigEndianData)
        return font
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var padded = data
        while padded.count % 4 != 0 { padded.append(0) }
        var sum: UInt32 = 0
        padded.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: bytes.count, by: 4) {
                sum &+= UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
            }
        }
        return sum
    }
}

private extension Data {
    mutating func u16(_ v: UInt16) { append(v.bigEndianData) }
    mutating func i16(_ v: Int16) { append(UInt16(bitPattern: v).bigEndianData) }
    mutating func u32(_ v: UInt32) { append(v.bigEndianData) }
    mutating func u64(_ v: UInt64) { append(v.bigEndianData) }
}

private extension FixedWidthInteger {
    var bigEndianData: Data { withUnsafeBytes(of: bigEndian) { Data($0) } }
}
