import CoreGraphics
import Foundation
import Vision

/// Eine erkannte Textzeile. `box` ist normiert (0…1) mit Ursprung unten links (Vision-Konvention).
public struct OCRLine: Sendable, Equatable {
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

    private static func recognizeBlocking(_ image: CGImage, languages: [String]) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, box: observation.boundingBox)
        }
    }
}
