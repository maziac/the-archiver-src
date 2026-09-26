import CoreGraphics
import Foundation
import Vision

/// Eine erkannte Textzeile. `box` ist normiert (0…1) mit Ursprung unten links (Vision-Konvention).
public struct OCRLine: Sendable, Equatable {
    public var text: String
    public var box: CGRect
    /// Lage der einzelnen Wörter (gleiche Normierung); leer = unbekannt, dann wird die Zeile als Ganzes gesetzt.
    public var words: [OCRWord]

    public init(text: String, box: CGRect, words: [OCRWord] = []) {
        self.text = text
        self.box = box
        self.words = words
    }
}

/// Ein Wort einer `OCRLine` mit seiner Lage.
public struct OCRWord: Sendable, Equatable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

public enum OCRService {
    /// Vision blockiert während der Erkennung und braucht intern selbst Threads. Läuft die OCR direkt
    /// auf Threads von Swift Concurrency, kann sich der Pool erschöpfen und alles hängt. Deshalb
    /// laufen alle Erkennungen nacheinander auf einer eigenen Queue.
    private static let queue = DispatchQueue(label: "de.local.scanarchiv.ocr", qos: .userInitiated)

    public static let defaultLanguages = ["de-DE", "en-US"]

    public static func recognize(_ image: CGImage, languages: [String] = defaultLanguages) async throws -> [OCRLine] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try recognizeBlocking(image, languages: languages) })
            }
        }
    }

    // MARK: Ausrichtung

    /// Erkennt, wie eine Seite gedreht werden muss, damit der Text aufrecht steht.
    /// - Returns: Drehung im Uhrzeigersinn (0, 90, 180, 270) oder `nil`, wenn zu wenig Text erkennbar ist
    ///   oder keine Richtung klar überwiegt.
    public static func detectOrientation(_ image: CGImage) async -> Int? {
        let scores = await orientationScores(image)
        return decideOrientation(scores)
    }

    /// Punkte je Drehung: Anzahl sicher erkannter Buchstaben in echten Wörtern.
    static func orientationScores(_ image: CGImage) async -> [Int: Double] {
        let small = ImageTools.downscaled(image, maxPixel: 1600)
        return await withCheckedContinuation { continuation in
            queue.async {
                var scores: [Int: Double] = [:]
                for rotation in [0, 180, 90, 270] {
                    scores[rotation] = (try? orientationScore(small, rotation: rotation)) ?? 0
                }
                continuation.resume(returning: scores)
            }
        }
    }

    /// Häufige deutsche und englische Wörter – in Buchstabensalat kommen sie praktisch nicht vor.
    static let commonWords: Set<String> = [
        "der", "die", "das", "und", "ist", "ein", "eine", "einer", "den", "dem", "des", "mit", "von", "für", "auf",
        "sie", "ihr", "ihre", "ihren", "ihnen", "wir", "ich", "nicht", "sich", "auch", "als", "bei", "zu", "zum", "zur",
        "im", "in", "an", "am", "es", "er", "wie", "oder", "aus", "nach", "bis", "vom", "wird", "werden", "sind",
        "haben", "hat", "kann", "noch", "nur", "über", "unter", "sehr", "geehrte", "geehrter", "herr", "frau",
        "datum", "seite", "betrag", "euro", "eur", "rechnung", "straße", "str", "gmbh", "nr", "tel", "mfg",
        "the", "and", "of", "to", "for", "with", "you", "your", "is", "are", "on", "at", "by", "this", "that",
        "from", "be", "or", "we", "our", "not", "page", "date", "total", "dear", "invoice",
    ]

    static func decideOrientation(_ scores: [Int: Double]) -> Int? {
        let ranked = scores.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 15 else { return nil }
        let second = ranked.dropFirst().first?.value ?? 0
        return best.value >= second * 3 ? best.key : nil
    }

    private static func orientationScore(_ image: CGImage, rotation: Int) throws -> Double {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = defaultLanguages
        request.usesLanguageCorrection = false
        // Orientierung sagt Vision, wie das Bild aufrecht aussähe (.right = 90° im Uhrzeigersinn drehen)
        let orientation: CGImagePropertyOrientation = switch rotation {
        case 90: .right
        case 180: .down
        case 270: .left
        default: .up
        }
        try VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        return plausibility(of: text)
    }

    /// Wie sehr ein Text nach echter Sprache aussieht. Kopfstehend gelesener Text ergibt Buchstabensalat
    /// wie „uaq!aJuasin6 ua6EI“: Großbuchstaben mitten im Wort, Satzzeichen im Wort, kaum häufige Wörter.
    static func plausibility(of text: String) -> Double {
        var score = 0.0
        for word in text.split(whereSeparator: { $0.isWhitespace || ",.;:()\"'".contains($0) }) {
            guard word.count >= 2 else { continue }
            if commonWords.contains(word.lowercased()) { score += 6 }
            guard word.count >= 3, word.allSatisfy(\.isLetter) else { continue }
            let tail = word.dropFirst()
            if tail.allSatisfy(\.isLowercase) || word.allSatisfy(\.isUppercase) { score += Double(word.count) }
        }
        return score
    }

    private static func recognizeBlocking(_ image: CGImage, languages: [String]) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, box: observation.boundingBox, words: words(of: candidate))
        }
    }

    /// Wörter mit ihren Rahmen. Ohne sie läge die Textebene nur zeilenweise richtig: Suchtreffer würden
    /// innerhalb der Zeile verschoben markiert, sobald die Schrift des Dokuments anders läuft als die Textebene.
    private static func words(of candidate: VNRecognizedText) -> [OCRWord] {
        let text = candidate.string
        var words: [OCRWord] = []
        var start = text.startIndex
        while let wordStart = text[start...].firstIndex(where: { !$0.isWhitespace }) {
            let wordEnd = text[wordStart...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            guard let box = try? candidate.boundingBox(for: wordStart..<wordEnd)?.boundingBox else { return [] }
            words.append(OCRWord(text: String(text[wordStart..<wordEnd]), box: box))
            start = wordEnd
        }
        return words
    }
}
