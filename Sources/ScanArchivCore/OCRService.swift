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
    public static func recognize(_ image: CGImage, languages: [String] = ["de-DE", "en-US"]) throws -> [OCRLine] {
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
