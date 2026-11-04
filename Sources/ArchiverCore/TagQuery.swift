import Foundation

/// Suchausdruck eines Tags, z. B. `("Rente" AND "DRV") OR "Rentenversicherung"`.
///
/// - Wörter sind **exakt** (Groß-/Kleinschreibung und Umlaute egal), Anführungszeichen optional.
/// - Platzhalter: `rente*` (Wortanfang), `*rente` (Wortende), `*rente*` (enthält).
/// - `AND`/`UND`, `OR`/`ODER`, `NOT`/`NICHT`, Klammern; ohne Operator gilt `AND`.
/// - `NOT` schließt aus und braucht davor einen Begriff („Rente NOT Witwe“).
public enum TagQuery {
    public struct ParseError: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    indirect enum Node: Equatable {
        /// Begriff; `leading`/`trailing` = Platzhalter vor/nach dem Wort
        case term(String, leading: Bool, trailing: Bool)
        case and(Node, Node)
        case or(Node, Node)
        /// „a NOT b“
        case andNot(Node, Node)
    }

    enum Token: Equatable {
        case word(String, quoted: Bool)
        case and, or, not, open, close
    }

    // MARK: Zerlegen

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        var chars = Array(text)
        chars.append(" ")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "(" { tokens.append(.open); i += 1; continue }
            if c == ")" { tokens.append(.close); i += 1; continue }
            if c == "\"" || c == "„" || c == "“" || c == "”" {
                var j = i + 1
                var word = ""
                while j < chars.count - 1, !["\"", "“", "”"].contains(chars[j]) { word.append(chars[j]); j += 1 }
                guard j < chars.count - 1 else { throw ParseError(message: "Anführungszeichen nicht geschlossen") }
                tokens.append(.word(word, quoted: true))
                i = j + 1
                continue
            }
            var word = ""
            while i < chars.count, !chars[i].isWhitespace, !"()\"„“”".contains(chars[i]) { word.append(chars[i]); i += 1 }
            switch word.uppercased() {
            case "AND", "UND", "&&": tokens.append(.and)
            case "OR", "ODER", "||": tokens.append(.or)
            case "NOT", "NICHT": tokens.append(.not)
            default: tokens.append(.word(word, quoted: false))
            }
        }
        return tokens
    }

    // MARK: Parsen

    public static func validate(_ text: String) throws {
        _ = try parse(text)
    }

    static func parse(_ text: String) throws -> Node {
        let tokens = try tokenize(text)
        guard !tokens.isEmpty else { throw ParseError(message: "Der Ausdruck ist leer") }
        var position = 0

        func peek() -> Token? { position < tokens.count ? tokens[position] : nil }

        func parseOr() throws -> Node {
            var left = try parseAnd()
            while peek() == .or {
                position += 1
                guard peek() != nil, peek() != .close else { throw ParseError(message: "Nach OR fehlt ein Begriff") }
                left = .or(left, try parseAnd())
            }
            return left
        }

        func parseAnd() throws -> Node {
            if peek() == .not { throw ParseError(message: "NOT braucht davor einen Begriff, z. B. „Rente NOT Witwe“") }
            var left = try parsePrimary()
            while let next = peek(), next != .or, next != .close {
                if next == .and {
                    position += 1
                    guard let after = peek(), after != .close, after != .or else {
                        throw ParseError(message: "Nach AND fehlt ein Begriff")
                    }
                    if after == .not { continue }  // „a AND NOT b“
                    left = .and(left, try parsePrimary())
                } else if next == .not {
                    position += 1
                    guard let after = peek(), after != .close, after != .or, after != .and else {
                        throw ParseError(message: "Nach NOT fehlt ein Begriff")
                    }
                    left = .andNot(left, try parsePrimary())
                } else {
                    left = .and(left, try parsePrimary())  // ohne Operator: UND
                }
            }
            return left
        }

        func parsePrimary() throws -> Node {
            guard let token = peek() else { throw ParseError(message: "Begriff fehlt") }
            position += 1
            switch token {
            case .open:
                let inner = try parseOr()
                guard peek() == .close else { throw ParseError(message: "Klammer nicht geschlossen") }
                position += 1
                return inner
            case let .word(raw, _):
                var word = raw.trimmingCharacters(in: .whitespaces)
                let leading = word.hasPrefix("*"), trailing = word.hasSuffix("*")
                word = word.trimmingCharacters(in: CharacterSet(charactersIn: "*")).trimmingCharacters(in: .whitespaces)
                guard !word.isEmpty else { throw ParseError(message: "Leerer Begriff") }
                if word.contains("*") { throw ParseError(message: "„*“ ist nur am Anfang oder Ende eines Wortes erlaubt") }
                if leading, word.contains(where: \.isWhitespace) {
                    throw ParseError(message: "Platzhalter am Anfang nur bei einzelnen Wörtern möglich")
                }
                return .term(word, leading: leading, trailing: trailing)
            case .close: throw ParseError(message: "Klammer „)“ ohne passende „(“")
            case .and: throw ParseError(message: "AND steht am Anfang oder doppelt")
            case .or: throw ParseError(message: "OR steht am Anfang oder doppelt")
            case .not: throw ParseError(message: "NOT braucht davor einen Begriff, z. B. „Rente NOT Witwe“")
            }
        }

        let node = try parseOr()
        if position < tokens.count {
            throw ParseError(message: tokens[position] == .close ? "Klammer „)“ ohne passende „(“" : "Unerwarteter Teil im Ausdruck")
        }
        return node
    }

    // MARK: Übersetzen nach FTS5

    /// Ausdruck, der garantiert nichts findet (z. B. Platzhalter ohne passendes Wort im Archiv).
    static let noMatch = "\"zzqxjkeinetrefferzzqxj\""

    /// - Parameter expand: liefert für Platzhalter am Wortanfang die passenden Wörter aus dem Index
    ///   (Muster im LIKE-Format, klein geschrieben, ohne Akzente)
    static func fts(_ node: Node, expand: (String) throws -> [String]) throws -> String {
        switch node {
        case let .term(word, leading, trailing):
            if leading {
                let folded = fold(word)
                let pattern = "%" + escapeLike(folded) + (trailing ? "%" : "")
                let terms = try expand(pattern)
                guard !terms.isEmpty else { return noMatch }
                return "(" + terms.map(phrase).joined(separator: " OR ") + ")"
            }
            return phrase(word) + (trailing ? "*" : "")
        case let .and(a, b): return "(\(try fts(a, expand: expand)) AND \(try fts(b, expand: expand)))"
        case let .or(a, b): return "(\(try fts(a, expand: expand)) OR \(try fts(b, expand: expand)))"
        case let .andNot(a, b): return "(\(try fts(a, expand: expand)) NOT \(try fts(b, expand: expand)))"
        }
    }

    static func phrase(_ word: String) -> String {
        "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Wie der Index (unicode61, remove_diacritics): klein, ohne Akzente.
    static func fold(_ word: String) -> String {
        word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
