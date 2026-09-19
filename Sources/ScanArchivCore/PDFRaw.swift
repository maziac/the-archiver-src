import Compression
import Foundation

/// Minimaler PDF-Leser/-Schreiber für inkrementelle Updates: liest Querverweise (Tabelle oder Stream),
/// Objekt-Streams und Objekte, und hängt geänderte/neue Objekte an das unveränderte Original an.
/// Damit bleiben Bilder (z. B. CCITT-Fax), Schriften und Struktur des Originals bitgenau erhalten.

public enum PDFRawError: Error, LocalizedError {
    case malformed(String)

    public var errorDescription: String? {
        if case let .malformed(message) = self { return "PDF nicht lesbar: \(message)" }
        return nil
    }
}

/// Ein PDF-Wert.
public indirect enum PDFValue: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    case string(Data)
    case name(String)
    case array([PDFValue])
    case dict(PDFDict)
    case ref(Int, Int)

    var int: Int? {
        switch self {
        case let .int(v): return v
        case let .real(v): return Int(v)
        default: return nil
        }
    }

    var number: Double? {
        switch self {
        case let .int(v): return Double(v)
        case let .real(v): return v
        default: return nil
        }
    }

    var dict: PDFDict? { if case let .dict(d) = self { return d }; return nil }
    var array: [PDFValue]? { if case let .array(a) = self { return a }; return nil }
    var nameValue: String? { if case let .name(n) = self { return n }; return nil }

    /// PDF-Textstring aus Swift-String (ASCII literal, sonst UTF-16BE mit BOM).
    static func text(_ string: String) -> PDFValue {
        if string.unicodeScalars.allSatisfy({ $0.value < 0x80 }) { return .string(Data(string.utf8)) }
        var data = Data([0xFE, 0xFF])
        data.append(string.data(using: .utf16BigEndian)!)
        return .string(data)
    }

    func serialized() -> Data {
        var out = Data()
        write(to: &out)
        return out
    }

    func write(to out: inout Data) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case let .bool(b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case let .int(i): out.append(contentsOf: Array(String(i).utf8))
        case let .real(r): out.append(contentsOf: Array(PDFValue.format(r).utf8))
        case let .string(data):
            // überwiegend Nicht-ASCII (z. B. UTF-16): hexadezimal ist kürzer als Oktal-Escapes
            if data.filter({ $0 >= 0x80 || $0 < 0x20 }).count * 4 > data.count {
                out.append(UInt8(ascii: "<"))
                out.append(contentsOf: Array(data.map { String(format: "%02X", $0) }.joined().utf8))
                out.append(UInt8(ascii: ">"))
                return
            }
            out.append(UInt8(ascii: "("))
            for byte in data {
                switch byte {
                case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
                    out.append(UInt8(ascii: "\\")); out.append(byte)
                case 0x0A: out.append(contentsOf: Array("\\n".utf8))
                case 0x0D: out.append(contentsOf: Array("\\r".utf8))
                case 0x80...0xFF, 0x00...0x1F:
                    // nur ASCII ausgeben – Seiteninhalte werden als Text zusammengesetzt
                    out.append(contentsOf: Array(String(format: "\\%03o", byte).utf8))
                default: out.append(byte)
                }
            }
            out.append(UInt8(ascii: ")"))
        case let .name(n):
            out.append(UInt8(ascii: "/"))
            for byte in n.utf8 {
                if byte < 0x21 || byte > 0x7E || "#()<>[]{}/%".utf8.contains(byte) {
                    out.append(contentsOf: Array(String(format: "#%02X", byte).utf8))
                } else {
                    out.append(byte)
                }
            }
        case let .array(items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: " ")) }
                item.write(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case let .dict(d):
            out.append(contentsOf: Array("<<".utf8))
            for (key, value) in d.entries {
                PDFValue.name(key).write(to: &out)
                out.append(UInt8(ascii: " "))
                value.write(to: &out)
            }
            out.append(contentsOf: Array(">>".utf8))
        case let .ref(n, g): out.append(contentsOf: Array("\(n) \(g) R".utf8))
        }
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 { return String(Int(value)) }
        var s = String(format: "%.4f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// Dictionary mit erhaltener Reihenfolge.
public struct PDFDict: Equatable {
    public var entries: [(String, PDFValue)]

    public init(_ entries: [(String, PDFValue)] = []) { self.entries = entries }

    public subscript(key: String) -> PDFValue? {
        get { entries.first { $0.0 == key }?.1 }
        set {
            if let i = entries.firstIndex(where: { $0.0 == key }) {
                if let newValue { entries[i].1 = newValue } else { entries.remove(at: i) }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }

    public static func == (a: PDFDict, b: PDFDict) -> Bool {
        a.entries.count == b.entries.count && zip(a.entries, b.entries).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

// MARK: - Tokenizer / Parser

struct PDFScanner {
    let data: [UInt8]
    var pos: Int

    init(_ data: [UInt8], at pos: Int = 0) {
        self.data = data
        self.pos = pos
    }

    static func isWhite(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
    static func isDelimiter(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) }

    mutating func skipWhitespace() {
        while pos < data.count {
            let c = data[pos]
            if PDFScanner.isWhite(c) { pos += 1; continue }
            if c == UInt8(ascii: "%") {  // Kommentar
                while pos < data.count, data[pos] != 10, data[pos] != 13 { pos += 1 }
                continue
            }
            break
        }
    }

    /// Liest ein Schlüsselwort/eine Zahl bis zum nächsten Trenner.
    mutating func regularToken() -> String {
        let start = pos
        while pos < data.count, !PDFScanner.isWhite(data[pos]), !PDFScanner.isDelimiter(data[pos]) { pos += 1 }
        return String(decoding: data[start..<pos], as: UTF8.self)
    }

    mutating func expectKeyword(_ keyword: String) throws {
        skipWhitespace()
        let token = regularToken()
        guard token == keyword else { throw PDFRawError.malformed("„\(keyword)“ erwartet, „\(token)“ gefunden") }
    }

    mutating func parseValue() throws -> PDFValue {
        skipWhitespace()
        guard pos < data.count else { throw PDFRawError.malformed("unerwartetes Ende") }
        let c = data[pos]
        switch c {
        case UInt8(ascii: "/"):
            pos += 1
            var bytes: [UInt8] = []
            while pos < data.count, !PDFScanner.isWhite(data[pos]), !PDFScanner.isDelimiter(data[pos]) {
                if data[pos] == UInt8(ascii: "#"), pos + 2 < data.count,
                   let v = UInt8(String(decoding: data[(pos + 1)...(pos + 2)], as: UTF8.self), radix: 16) {
                    bytes.append(v); pos += 3
                } else {
                    bytes.append(data[pos]); pos += 1
                }
            }
            return .name(String(decoding: bytes, as: UTF8.self))
        case UInt8(ascii: "("):
            return .string(parseLiteralString())
        case UInt8(ascii: "<"):
            if pos + 1 < data.count, data[pos + 1] == UInt8(ascii: "<") {
                pos += 2
                var dict = PDFDict()
                while true {
                    skipWhitespace()
                    guard pos < data.count else { throw PDFRawError.malformed("Dictionary nicht geschlossen") }
                    if data[pos] == UInt8(ascii: ">") { pos += 2; break }
                    guard case let .name(key) = try parseValue() else { throw PDFRawError.malformed("Schlüssel erwartet") }
                    dict.entries.append((key, try parseValue()))
                }
                return .dict(dict)
            }
            pos += 1
            var hex: [UInt8] = []
            while pos < data.count, data[pos] != UInt8(ascii: ">") {
                if !PDFScanner.isWhite(data[pos]) { hex.append(data[pos]) }
                pos += 1
            }
            pos += 1
            if hex.count % 2 == 1 { hex.append(UInt8(ascii: "0")) }
            var bytes = Data()
            var i = 0
            while i < hex.count {
                bytes.append(UInt8(String(decoding: hex[i...(i + 1)], as: UTF8.self), radix: 16) ?? 0)
                i += 2
            }
            return .string(bytes)
        case UInt8(ascii: "["):
            pos += 1
            var items: [PDFValue] = []
            while true {
                skipWhitespace()
                guard pos < data.count else { throw PDFRawError.malformed("Array nicht geschlossen") }
                if data[pos] == UInt8(ascii: "]") { pos += 1; break }
                items.append(try parseValue())
            }
            return .array(items)
        default:
            let token = regularToken()
            if token.isEmpty { pos += 1; throw PDFRawError.malformed("unerwartetes Zeichen") }
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: break
            }
            if let int = Int(token) {
                // Referenz „n g R“?
                let save = pos
                skipWhitespace()
                let second = regularToken()
                if let gen = Int(second) {
                    skipWhitespace()
                    if pos < data.count, data[pos] == UInt8(ascii: "R"),
                       pos + 1 >= data.count || PDFScanner.isWhite(data[pos + 1]) || PDFScanner.isDelimiter(data[pos + 1]) {
                        pos += 1
                        return .ref(int, gen)
                    }
                }
                pos = save
                return .int(int)
            }
            if let real = Double(token) { return .real(real) }
            throw PDFRawError.malformed("unbekanntes Token „\(token)“")
        }
    }

    mutating func parseLiteralString() -> Data {
        pos += 1  // (
        var out = Data()
        var depth = 1
        while pos < data.count {
            let c = data[pos]
            pos += 1
            if c == UInt8(ascii: "\\"), pos < data.count {
                let e = data[pos]
                pos += 1
                switch e {
                case UInt8(ascii: "n"): out.append(10)
                case UInt8(ascii: "r"): out.append(13)
                case UInt8(ascii: "t"): out.append(9)
                case UInt8(ascii: "b"): out.append(8)
                case UInt8(ascii: "f"): out.append(12)
                case 13: if pos < data.count, data[pos] == 10 { pos += 1 }
                case 10: break
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(e - 48)
                    for _ in 0..<2 where pos < data.count && (48...55).contains(data[pos]) {
                        value = value * 8 + Int(data[pos] - 48); pos += 1
                    }
                    out.append(UInt8(value & 0xFF))
                default: out.append(e)
                }
                continue
            }
            if c == UInt8(ascii: "(") { depth += 1 }
            if c == UInt8(ascii: ")") { depth -= 1; if depth == 0 { break } }
            out.append(c)
        }
        return out
    }
}

// MARK: - Dokument

public final class PDFRawDocument {
    public let data: [UInt8]

    enum Location {
        case offset(Int, gen: Int)
        case compressed(stream: Int, index: Int)
    }

    private(set) var xref: [Int: Location] = [:]
    public private(set) var trailer = PDFDict()
    /// Position des letzten Querverweises (für /Prev)
    public private(set) var lastXRefOffset = 0
    /// true, wenn der neueste Querverweis ein Stream ist (dann schreiben wir auch einen Stream)
    public private(set) var usesXRefStream = false
    private var objectStreamCache: [Int: [Int: PDFValue]] = [:]

    public init(data: Data) throws {
        self.data = [UInt8](data)
        guard let start = PDFRawDocument.findStartXRef(self.data) else { throw PDFRawError.malformed("startxref fehlt") }
        lastXRefOffset = start
        var visited = Set<Int>()
        var offset: Int? = start
        var first = true
        while let current = offset, !visited.contains(current) {
            visited.insert(current)
            let section = try readXRefSection(at: current)
            if first {
                trailer = section.trailer
                usesXRefStream = section.isStream
                first = false
            }
            // ältere Einträge nicht überschreiben
            for (num, loc) in section.entries where xref[num] == nil { xref[num] = loc }
            if let stm = section.trailer["XRefStm"]?.int, !visited.contains(stm) {
                visited.insert(stm)
                let hybrid = try readXRefSection(at: stm)
                for (num, loc) in hybrid.entries where xref[num] == nil { xref[num] = loc }
            }
            offset = section.trailer["Prev"]?.int
        }
        guard trailer["Root"] != nil else { throw PDFRawError.malformed("Root fehlt") }
    }

    var size: Int { max(trailer["Size"]?.int ?? 0, (xref.keys.max() ?? 0) + 1) }

    static func findStartXRef(_ data: [UInt8]) -> Int? {
        let needle = Array("startxref".utf8)
        var i = data.count - needle.count
        let limit = max(0, data.count - 2048)
        while i >= limit {
            if data[i] == needle[0], Array(data[i..<(i + needle.count)]) == needle {
                var s = PDFScanner(data, at: i + needle.count)
                s.skipWhitespace()
                return Int(s.regularToken())
            }
            i -= 1
        }
        return nil
    }

    private func readXRefSection(at offset: Int) throws -> (entries: [Int: Location], trailer: PDFDict, isStream: Bool) {
        var s = PDFScanner(data, at: offset)
        s.skipWhitespace()
        let save = s.pos
        if s.regularToken() == "xref" {
            var entries: [Int: Location] = [:]
            while true {
                s.skipWhitespace()
                let save2 = s.pos
                let token = s.regularToken()
                if token == "trailer" { break }
                guard let startNum = Int(token) else { s.pos = save2; break }
                s.skipWhitespace()
                guard let count = Int(s.regularToken()) else { throw PDFRawError.malformed("xref") }
                for i in 0..<count {
                    s.skipWhitespace()
                    let off = Int(s.regularToken()) ?? 0
                    s.skipWhitespace()
                    let gen = Int(s.regularToken()) ?? 0
                    s.skipWhitespace()
                    let type = s.regularToken()
                    if type == "n" { entries[startNum + i] = .offset(off, gen: gen) }
                }
            }
            guard case let .dict(trailer) = try s.parseValue() else { throw PDFRawError.malformed("trailer") }
            return (entries, trailer, false)
        }
        // Querverweis-Stream
        s.pos = save
        let (_, value, stream) = try parseIndirectObject(at: offset)
        guard case let .dict(dict) = value, let raw = stream else { throw PDFRawError.malformed("xref-Stream") }
        let decoded = try PDFRawDocument.decode(stream: raw, dict: dict)
        guard let w = dict["W"]?.array?.compactMap(\.int), w.count == 3 else { throw PDFRawError.malformed("/W") }
        let sizeValue = dict["Size"]?.int ?? 0
        let index = dict["Index"]?.array?.compactMap(\.int) ?? [0, sizeValue]
        let rowLength = w.reduce(0, +)
        var entries: [Int: Location] = [:]
        var row = 0
        for pair in stride(from: 0, to: index.count - 1, by: 2) {
            for k in 0..<index[pair + 1] {
                let base = row * rowLength
                guard base + rowLength <= decoded.count else { break }
                func field(_ start: Int, _ length: Int) -> Int {
                    var v = 0
                    for b in 0..<length { v = v << 8 | Int(decoded[base + start + b]) }
                    return v
                }
                let type = w[0] == 0 ? 1 : field(0, w[0])
                let f2 = field(w[0], w[1])
                let f3 = field(w[0] + w[1], w[2])
                let num = index[pair] + k
                if type == 1 { entries[num] = .offset(f2, gen: f3) }
                if type == 2 { entries[num] = .compressed(stream: f2, index: f3) }
                row += 1
            }
        }
        return (entries, dict, true)
    }

    /// Liest „n g obj … endobj“ an der Position; bei Streams die Rohdaten.
    func parseIndirectObject(at offset: Int) throws -> (num: Int, value: PDFValue, stream: [UInt8]?) {
        var s = PDFScanner(data, at: offset)
        s.skipWhitespace()
        guard let num = Int(s.regularToken()) else { throw PDFRawError.malformed("Objektnummer") }
        s.skipWhitespace()
        _ = s.regularToken()
        try s.expectKeyword("obj")
        let value = try s.parseValue()
        s.skipWhitespace()
        let save = s.pos
        if case let .dict(dict) = value, s.regularToken() == "stream" {
            if s.pos < data.count, data[s.pos] == 13 { s.pos += 1 }
            if s.pos < data.count, data[s.pos] == 10 { s.pos += 1 }
            let start = s.pos
            var length = dict["Length"].flatMap { try? resolve($0).int } ?? -1
            if length < 0 || start + length > data.count {
                // Länge unbekannt/falsch: bis „endstream“ suchen
                length = PDFRawDocument.find(Array("endstream".utf8), in: data, from: start).map { $0 - start } ?? 0
            }
            return (num, value, Array(data[start..<min(data.count, start + length)]))
        }
        s.pos = save
        return (num, value, nil)
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var i = from
        while i <= haystack.count - needle.count {
            if haystack[i] == needle[0], Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// Objekt anhand der Nummer (ohne Stream-Daten).
    public func object(_ num: Int) throws -> PDFValue {
        try objectWithStream(num).value
    }

    func objectWithStream(_ num: Int) throws -> (value: PDFValue, stream: [UInt8]?) {
        guard let location = xref[num] else { return (.null, nil) }
        switch location {
        case let .offset(off, _):
            let parsed = try parseIndirectObject(at: off)
            return (parsed.value, parsed.stream)
        case let .compressed(streamNum, index):
            if objectStreamCache[streamNum] == nil { try loadObjectStream(streamNum) }
            _ = index
            return (objectStreamCache[streamNum]?[num] ?? .null, nil)
        }
    }

    public func generation(of num: Int) -> Int {
        if case let .offset(_, gen)? = xref[num] { return gen }
        return 0
    }

    private func loadObjectStream(_ num: Int) throws {
        guard case let .offset(off, _)? = xref[num] else { throw PDFRawError.malformed("Objekt-Stream \(num)") }
        let (_, value, stream) = try parseIndirectObject(at: off)
        guard case let .dict(dict) = value, let raw = stream, let n = dict["N"]?.int, let first = dict["First"]?.int
        else { throw PDFRawError.malformed("Objekt-Stream \(num)") }
        let decoded = try PDFRawDocument.decode(stream: raw, dict: dict)
        var header = PDFScanner(decoded, at: 0)
        var pairs: [(Int, Int)] = []
        for _ in 0..<n {
            header.skipWhitespace()
            let objNum = Int(header.regularToken()) ?? -1
            header.skipWhitespace()
            let objOff = Int(header.regularToken()) ?? 0
            pairs.append((objNum, objOff))
        }
        var objects: [Int: PDFValue] = [:]
        for (objNum, objOff) in pairs {
            var s = PDFScanner(decoded, at: first + objOff)
            if let value = try? s.parseValue() { objects[objNum] = value }
        }
        objectStreamCache[num] = objects
    }

    /// Löst Referenzen auf (auch verschachtelt nur eine Ebene).
    public func resolve(_ value: PDFValue) throws -> PDFValue {
        if case let .ref(num, _) = value { return try object(num) }
        return value
    }

    // MARK: Seiten

    public struct PageInfo {
        public let ref: Int
        public var dict: PDFDict
        /// geerbte Attribute (Resources, MediaBox, CropBox, Rotate)
        public var inherited: PDFDict
    }

    public func pages() throws -> [PageInfo] {
        guard case let .ref(rootNum, _)? = trailer["Root"], case let .dict(root) = try object(rootNum),
              case let .ref(pagesNum, _)? = root["Pages"] else { throw PDFRawError.malformed("Seitenbaum") }
        var result: [PageInfo] = []
        var visited = Set<Int>()
        func walk(_ num: Int, inherited: PDFDict) throws {
            guard !visited.contains(num), case let .dict(node) = try object(num) else { return }
            visited.insert(num)
            var inh = inherited
            for key in ["Resources", "MediaBox", "CropBox", "Rotate"] { if let v = node[key] { inh[key] = v } }
            if node["Type"]?.nameValue == "Pages" || node["Kids"] != nil {
                for kid in (try resolve(node["Kids"] ?? .null)).array ?? [] {
                    if case let .ref(k, _) = kid { try walk(k, inherited: inh) }
                }
            } else {
                result.append(PageInfo(ref: num, dict: node, inherited: inh))
            }
        }
        try walk(pagesNum, inherited: PDFDict())
        return result
    }

    // MARK: Filter

    static func decode(stream raw: [UInt8], dict: PDFDict) throws -> [UInt8] {
        var filters: [String] = []
        if let f = dict["Filter"] {
            if case let .name(n) = f { filters = [n] }
            if case let .array(a) = f { filters = a.compactMap(\.nameValue) }
        }
        var bytes = raw
        for filter in filters {
            guard filter == "FlateDecode" || filter == "Fl" else { throw PDFRawError.malformed("Filter \(filter)") }
            bytes = try inflate(bytes)
        }
        let parms: PDFDict? = {
            if case let .dict(d)? = dict["DecodeParms"] { return d }
            if case let .array(a)? = dict["DecodeParms"] { return a.first?.dict }
            return nil
        }()
        if let parms, let predictor = parms["Predictor"]?.int, predictor >= 10 {
            bytes = try undoPNGPredictor(bytes, columns: parms["Columns"]?.int ?? 1)
        }
        return bytes
    }

    static func inflate(_ input: [UInt8]) throws -> [UInt8] {
        guard input.count > 2 else { return [] }
        let body = Array(input.dropFirst(2))  // zlib-Kopf überspringen (Compression kennt nur rohes Deflate)
        var capacity = max(1024, body.count * 8)
        for _ in 0..<6 {
            var out = [UInt8](repeating: 0, count: capacity)
            let written = compression_decode_buffer(&out, capacity, body, body.count, nil, COMPRESSION_ZLIB)
            if written > 0, written < capacity { return Array(out[0..<written]) }
            capacity *= 4
        }
        throw PDFRawError.malformed("Flate")
    }

    static func deflate(_ input: [UInt8]) -> [UInt8] {
        let capacity = input.count + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let written = compression_encode_buffer(&out, capacity, input, input.count, nil, COMPRESSION_ZLIB)
        var result: [UInt8] = [0x78, 0x9C]
        result += out[0..<written]
        // Adler-32
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in input { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = (b << 16) | a
        result += [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
        return result
    }

    static func undoPNGPredictor(_ data: [UInt8], columns: Int) throws -> [UInt8] {
        let rowLength = columns + 1
        guard rowLength > 1 else { return data }
        var out: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: columns)
        var i = 0
        while i + rowLength <= data.count {
            let type = data[i]
            var row = Array(data[(i + 1)..<(i + rowLength)])
            for x in 0..<columns {
                let left: Int = x > 0 ? Int(row[x - 1]) : 0
                let up = Int(previous[x])
                let upLeft: Int = x > 0 ? Int(previous[x - 1]) : 0
                let value = Int(row[x])
                switch type {
                case 1: row[x] = UInt8((value + left) & 0xFF)
                case 2: row[x] = UInt8((value + up) & 0xFF)
                case 3: row[x] = UInt8((value + (left + up) / 2) & 0xFF)
                case 4:
                    let p = left + up - upLeft
                    let pa = abs(p - left), pb = abs(p - up), pc = abs(p - upLeft)
                    let pred = pa <= pb && pa <= pc ? left : (pb <= pc ? up : upLeft)
                    row[x] = UInt8((value + pred) & 0xFF)
                default: break
                }
            }
            out += row
            previous = row
            i += rowLength
        }
        return out
    }
}

// MARK: - Inkrementelles Update

public final class PDFIncrementalUpdate {
    public let document: PDFRawDocument
    private var objects: [(num: Int, gen: Int, body: Data)] = []
    private var nextNumber: Int
    public var trailerChanges = PDFDict()

    public init(_ document: PDFRawDocument) {
        self.document = document
        nextNumber = document.size
    }

    /// Reserviert eine neue Objektnummer.
    public func allocate() -> Int {
        defer { nextNumber += 1 }
        return nextNumber
    }

    public func set(_ num: Int, _ value: PDFValue) {
        objects.removeAll { $0.num == num }
        objects.append((num, document.generation(of: num), value.serialized()))
    }

    public func add(_ value: PDFValue) -> PDFValue {
        let num = allocate()
        set(num, value)
        return .ref(num, 0)
    }

    /// Stream-Objekt (Daten werden Flate-komprimiert, sofern das kleiner ist).
    public func addStream(_ bytes: [UInt8], dict: PDFDict = PDFDict(), compress: Bool = true) -> PDFValue {
        var d = dict
        var payload = bytes
        if compress {
            let packed = PDFRawDocument.deflate(bytes)
            if packed.count < bytes.count {
                payload = packed
                d["Filter"] = .name("FlateDecode")
            }
        }
        d["Length"] = .int(payload.count)
        var body = PDFValue.dict(d).serialized()
        body.append(contentsOf: Array("\nstream\n".utf8))
        body.append(contentsOf: payload)
        body.append(contentsOf: Array("\nendstream".utf8))
        let num = allocate()
        objects.append((num, 0, body))
        return .ref(num, 0)
    }

    /// Original + angehängte Objekte + neuer Querverweis.
    public func write() -> Data {
        var out = Data(document.data)
        if out.last != 10 { out.append(10) }
        var offsets: [(num: Int, gen: Int, offset: Int)] = []
        for object in objects.sorted(by: { $0.num < $1.num }) {
            offsets.append((object.num, object.gen, out.count))
            out.append(contentsOf: Array("\(object.num) \(object.gen) obj\n".utf8))
            out.append(object.body)
            out.append(contentsOf: Array("\nendobj\n".utf8))
        }

        var trailer = PDFDict()
        trailer["Root"] = document.trailer["Root"]
        if let info = document.trailer["Info"] { trailer["Info"] = info }
        if let id = document.trailer["ID"] { trailer["ID"] = id }
        for (key, value) in trailerChanges.entries { trailer[key] = value }
        trailer["Prev"] = .int(document.lastXRefOffset)

        if document.usesXRefStream {
            let xrefNum = nextNumber
            let xrefOffset = out.count
            offsets.append((xrefNum, 0, xrefOffset))
            var rows: [UInt8] = []
            var index: [PDFValue] = []
            for entry in offsets {
                rows.append(1)
                rows += [UInt8(entry.offset >> 24 & 0xFF), UInt8(entry.offset >> 16 & 0xFF),
                         UInt8(entry.offset >> 8 & 0xFF), UInt8(entry.offset & 0xFF)]
                rows += [UInt8(entry.gen >> 8 & 0xFF), UInt8(entry.gen & 0xFF)]
                index += [.int(entry.num), .int(1)]
            }
            var dict = trailer
            dict["Type"] = .name("XRef")
            dict["Size"] = .int(xrefNum + 1)
            dict["W"] = .array([.int(1), .int(4), .int(2)])
            dict["Index"] = .array(index)
            dict["Length"] = .int(rows.count)
            out.append(contentsOf: Array("\(xrefNum) 0 obj\n".utf8))
            out.append(PDFValue.dict(dict).serialized())
            out.append(contentsOf: Array("\nstream\n".utf8))
            out.append(contentsOf: rows)
            out.append(contentsOf: Array("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        } else {
            let xrefOffset = out.count
            out.append(contentsOf: Array("xref\n".utf8))
            for entry in offsets {
                out.append(contentsOf: Array("\(entry.num) 1\n".utf8))
                out.append(contentsOf: Array(String(format: "%010d %05d n\r\n", entry.offset, entry.gen).utf8))
            }
            trailer["Size"] = .int(max(nextNumber, document.size))
            out.append(contentsOf: Array("trailer\n".utf8))
            out.append(PDFValue.dict(trailer).serialized())
            out.append(contentsOf: Array("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        }
        return out
    }
}
