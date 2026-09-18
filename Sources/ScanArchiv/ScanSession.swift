import AppKit
import Foundation
import Observation
import ScanArchivCore

struct ScannedPage: Identifiable {
    let id = UUID()
    let url: URL
    let isBack: Bool
    let thumbnail: NSImage
    var rotated180: Bool
}

/// Führt durch den zweiteiligen Scan: Vorderseiten → wenden → Rückseiten → Vorschau → Speichern.
@Observable
@MainActor
final class ScanSession {
    enum Phase: Equatable {
        case ready
        case scanningFronts
        case awaitingFlip
        case scanningBacks
        case countMismatch(fronts: Int, backs: Int)
        case preview
        case processing(String)
        case saved(URL)
        case failed(String)
    }

    enum SuggestionState: Equatable {
        case idle
        case recognizing
        case suggesting
        case done
        case unavailable(String)
        case failed(String)
    }

    enum DateSource: Equatable {
        case document, today, manual
    }

    private(set) var phase: Phase = .ready
    private(set) var fronts: [URL] = []
    private(set) var backs: [URL] = []
    var pages: [ScannedPage] = []

    // Metadaten-Vorschlag (bearbeitbar in der Vorschau)
    var title = "" { didSet { if !applying { titleEdited = true } } }
    var summary = "" { didSet { if !applying { summaryEdited = true } } }
    var documentDate = Date() { didSet { if !applying { dateSource = .manual } } }
    private(set) var dateSource: DateSource = .today
    private(set) var suggestionState: SuggestionState = .idle
    @ObservationIgnored private var titleEdited = false
    @ObservationIgnored private var summaryEdited = false
    @ObservationIgnored private var applying = false
    /// OCR-Ergebnis je Seite, gültig für die gespeicherte Drehung
    @ObservationIgnored private var ocrCache: [UUID: (rotated: Bool, lines: [OCRLine])] = [:]
    @ObservationIgnored private var analysisTask: Task<Void, Never>?

    let scanner: ScannerService
    let model: AppModel
    @ObservationIgnored private var workFolder = ScanSession.newWorkFolder()

    init(scanner: ScannerService, model: AppModel) {
        self.scanner = scanner
        self.model = model
    }

    private static func newWorkFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ScanArchiv-\(UUID().uuidString)", isDirectory: true)
    }

    private var dpi: Int { UserDefaults.standard.integer(forKey: SettingsKey.dpi) }
    private var color: Bool { UserDefaults.standard.bool(forKey: SettingsKey.color) }

    // MARK: Aktionen

    func scanFronts() {
        phase = .scanningFronts
        Task {
            do {
                fronts = try await scanner.scanFeeder(dpi: dpi, color: color, into: workFolder.appendingPathComponent("vorne"))
                phase = fronts.isEmpty ? .failed("Es wurden keine Seiten gescannt. Liegt Papier im Einzug?") : .awaitingFlip
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func scanBacks() {
        phase = .scanningBacks
        let folder = workFolder.appendingPathComponent("hinten-\(UUID().uuidString.prefix(6))")
        Task {
            do {
                backs = try await scanner.scanFeeder(dpi: dpi, color: color, into: folder)
                if backs.count == fronts.count {
                    buildPreview()
                } else {
                    phase = .countMismatch(fronts: fronts.count, backs: backs.count)
                }
            } catch {
                phase = .countMismatch(fronts: fronts.count, backs: 0)
            }
        }
    }

    /// Nur Vorderseiten verwenden (einseitige Dokumente).
    func finishSimplex() {
        backs = []
        buildPreview()
    }

    func acceptMismatch() { buildPreview() }

    func backToPreview() { phase = .preview }

    func cancelScan() { scanner.cancelScan() }

    func reset() {
        analysisTask?.cancel()
        try? FileManager.default.removeItem(at: workFolder)
        workFolder = ScanSession.newWorkFolder()
        fronts = []
        backs = []
        pages = []
        ocrCache = [:]
        withoutEditTracking {
            title = ""
            summary = ""
            documentDate = Date()
        }
        titleEdited = false
        summaryEdited = false
        dateSource = .today
        suggestionState = .idle
        phase = .ready
    }

    func toggleRotation(_ page: ScannedPage) {
        guard let i = pages.firstIndex(where: { $0.id == page.id }) else { return }
        pages[i].rotated180.toggle()
        startAnalysis()  // gedrehte Seite neu erkennen, Vorschlag ggf. verbessern
    }

    func remove(_ page: ScannedPage) {
        pages.removeAll { $0.id == page.id }
        startAnalysis()
    }

    /// Verwirft eigene Eingaben und fragt Apple Intelligence erneut.
    func resuggest() {
        titleEdited = false
        summaryEdited = false
        if dateSource == .manual { dateSource = .today }
        startAnalysis()
    }

    private func withoutEditTracking(_ body: () -> Void) {
        applying = true
        body()
        applying = false
    }

    // MARK: Texterkennung + Vorschlag im Hintergrund

    /// OCR aller Seiten (Cache nutzen), dann Datum aus dem Text und Titel/Beschreibung per Apple Intelligence.
    private func startAnalysis() {
        analysisTask?.cancel()
        let snapshot = pages
        analysisTask = Task {
            suggestionState = .recognizing
            var texts: [String] = []
            for page in snapshot {
                guard let lines = await ocrLines(for: page) else {
                    if Task.isCancelled { return }
                    continue
                }
                texts.append(lines.map(\.text).joined(separator: "\n"))
            }
            if Task.isCancelled { return }
            let text = texts.joined(separator: "\n\n")

            if dateSource != .manual {
                applyDate(DateExtractor.bestGuess(in: texts.first ?? "") ?? DateExtractor.bestGuess(in: text))
            }
            if let reason = Summarizer.unavailableReason {
                suggestionState = .unavailable(reason)
                return
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                suggestionState = .failed("Auf den Seiten wurde kein Text erkannt.")
                return
            }
            suggestionState = .suggesting
            do {
                let suggestion = try await Summarizer.suggest(for: text)
                if Task.isCancelled { return }
                withoutEditTracking {
                    if !titleEdited { title = suggestion.title }
                    if !summaryEdited { summary = suggestion.summary }
                }
                if dateSource != .manual, let date = suggestion.date { applyDate(date) }
                suggestionState = .done
            } catch {
                if !Task.isCancelled { suggestionState = .failed(error.localizedDescription) }
            }
        }
    }

    private func applyDate(_ date: Date?) {
        withoutEditTracking { documentDate = date ?? Date() }
        dateSource = date == nil ? .today : .document
    }

    /// OCR einer Seite in ihrer aktuellen Drehung, aus dem Cache oder neu erkannt.
    private func ocrLines(for page: ScannedPage) async -> [OCRLine]? {
        if let cached = ocrCache[page.id], cached.rotated == page.rotated180 { return cached.lines }
        let url = page.url, rotated = page.rotated180
        let lines = await Task.detached(priority: .userInitiated) { () -> [OCRLine]? in
            guard var image = ImageTools.load(url) else { return nil }
            if rotated { image = ImageTools.rotated180(image) }
            return try? OCRService.recognize(image)
        }.value
        if let lines, !Task.isCancelled { ocrCache[page.id] = (rotated, lines) }
        return lines
    }

    private func buildPreview() {
        let rotateBacks = UserDefaults.standard.bool(forKey: SettingsKey.rotateBacks)
        let frontPages = fronts.map { makePage($0, isBack: false, rotated: false) }
        let backPages = backs.map { makePage($0, isBack: true, rotated: rotateBacks) }
        pages = PageOrder.interleave(fronts: frontPages, backsScannedReversed: backPages)
        phase = .preview
        startAnalysis()
    }

    private func makePage(_ url: URL, isBack: Bool, rotated: Bool) -> ScannedPage {
        let thumb = ImageTools.thumbnail(url).map { NSImage(cgImage: $0, size: .zero) } ?? NSImage()
        return ScannedPage(url: url, isBack: isBack, thumbnail: thumb, rotated180: rotated)
    }

    // MARK: Speichern

    func save() {
        guard let archive = model.archive, let index = model.index else {
            phase = .failed(model.error ?? "Kein Archivordner.")
            return
        }
        analysisTask?.cancel()
        let input = pages.map { page -> (url: URL, rotated: Bool, lines: [OCRLine]?) in
            let cached = ocrCache[page.id]
            return (page.url, page.rotated180, cached?.rotated == page.rotated180 ? cached?.lines : nil)
        }
        let dpi = Double(dpi)
        let quality = UserDefaults.standard.double(forKey: SettingsKey.jpegQuality)
        let date = documentDate
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .processing("Texterkennung …")

        Task.detached(priority: .userInitiated) {
            do {
                var pdfPages: [PDFPageInput] = []
                for (i, page) in input.enumerated() {
                    if page.lines == nil {
                    await MainActor.run { self.phase = .processing("Texterkennung Seite \(i + 1) von \(input.count) …") }
                }
                    guard var image = ImageTools.load(page.url) else {
                        throw ScannerError.scanFailed("Seitenbild \(page.url.lastPathComponent) nicht lesbar.")
                    }
                    if page.rotated { image = ImageTools.rotated180(image) }
                    let lines = try page.lines ?? OCRService.recognize(image)
                    pdfPages.append(PDFPageInput(image: image, lines: lines))
                }
                await MainActor.run { self.phase = .processing("PDF wird gespeichert …") }
                let saved = try archive.save(date: date, title: title) { number in
                    try PDFBuilder.build(pages: pdfPages, number: number, date: date, dpi: dpi, jpegQuality: quality,
                                         title: title, summary: summary)
                }
                let text = pdfPages.map { $0.lines.map(\.text).joined(separator: "\n") }.joined(separator: "\n\n")
                try index.add(number: saved.number, date: date, url: saved.url, pages: pdfPages.count, text: text,
                              title: title, summary: summary)
                await MainActor.run {
                    self.model.didSave()
                    self.reset()
                    self.phase = .saved(saved.url)
                }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }
}
