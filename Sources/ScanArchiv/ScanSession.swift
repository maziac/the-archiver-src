import AppKit
import Foundation
import Observation
import ScanArchivCore

struct ScannedPage: Identifiable {
    enum Kind { case front, back }

    let id = UUID()
    let url: URL
    let kind: Kind
    let thumbnail: NSImage
    var rotated180: Bool
}

/// Führt durch den zweiteiligen Scan: Vorderseiten → wenden → Rückseiten → Vorschau → Speichern.
/// (Dateien werden über den Eingang vollautomatisch importiert, siehe `InboxService`.)
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
    /// Datum stammt von Apple Intelligence (sonst direkt aus dem Text)
    @ObservationIgnored private var dateFromAI = false
    private(set) var suggestionState: SuggestionState = .idle
    /// Probleme des zuletzt gespeicherten Dokuments (für die Anzeige nach dem Speichern)
    private(set) var savedIssues: [DocumentIssue] = []
    @ObservationIgnored private var titleEdited = false
    @ObservationIgnored private var summaryEdited = false
    @ObservationIgnored private var applying = false
    /// OCR-Ergebnis je Seite, gültig für die gespeicherte Drehung
    @ObservationIgnored private var ocrCache: [UUID: (rotated: Bool, lines: [OCRLine])] = [:]
    @ObservationIgnored private var analysisTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundOCRTask: Task<Void, Never>?

    let scanner: ScannerService
    let model: AppModel
    @ObservationIgnored private var workFolder = ScanSession.newWorkFolder()

    /// Seiten, deren Text für Titel, Beschreibung und Datum genutzt wird.
    nonisolated static let suggestionPageCount = 2

    init(scanner: ScannerService, model: AppModel) {
        self.scanner = scanner
        self.model = model
    }

    private static func newWorkFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ScanArchiv-\(UUID().uuidString)", isDirectory: true)
    }

    private var dpi: Int { UserDefaults.standard.integer(forKey: SettingsKey.dpi) }
    private var scanColorMode: ColorMode { SettingsKey.colorMode(SettingsKey.scanColorMode) }
    /// Farbe nur bei „Farbe/Original“; Graustufen und Schwarz-Weiß werden grau gescannt
    private var color: Bool { scanColorMode == .original }

    // MARK: Scannen

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

    private func buildPreview() {
        let rotateBacks = UserDefaults.standard.bool(forKey: SettingsKey.rotateBacks)
        let frontPages = fronts.map { makePage($0, kind: .front, rotated: false) }
        let backPages = backs.map { makePage($0, kind: .back, rotated: rotateBacks) }
        pages = PageOrder.interleave(fronts: frontPages, backsScannedReversed: backPages)
        phase = .preview
        Summarizer.prewarm()
        startAnalysis()
    }

    private func makePage(_ url: URL, kind: ScannedPage.Kind, rotated: Bool) -> ScannedPage {
        let thumb = ImageTools.thumbnail(url).map { NSImage(cgImage: $0, size: .zero) } ?? NSImage()
        return ScannedPage(url: url, kind: kind, thumbnail: thumb, rotated180: rotated)
    }

    // MARK: Zurücksetzen / Bearbeiten

    func reset() {
        analysisTask?.cancel()
        backgroundOCRTask?.cancel()
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

    /// Titel, Beschreibung und Datum aus den ersten Seiten; die übrigen Seiten werden parallel
    /// für die Textebene erkannt, damit das Speichern schneller geht.
    private func startAnalysis() {
        analysisTask?.cancel()
        backgroundOCRTask?.cancel()
        let snapshot = pages
        let first = Array(snapshot.prefix(Self.suggestionPageCount))

        analysisTask = Task {
            suggestionState = .recognizing
            var texts: [String] = []
            for page in first {
                if let lines = await ocrLines(for: page) { texts.append(lines.map(\.text).joined(separator: "\n")) }
                if Task.isCancelled { return }
            }
            // restliche Seiten erst jetzt, damit sie der Vorschlags-OCR nicht in die Quere kommen
            backgroundOCRTask = Task {
                for page in snapshot.dropFirst(Self.suggestionPageCount) {
                    if Task.isCancelled { return }
                    _ = await ocrLines(for: page)
                }
            }
            let text = texts.joined(separator: "\n\n")

            if dateSource != .manual {
                applyDate(DateExtractor.bestGuess(in: texts.first ?? "") ?? DateExtractor.bestGuess(in: text))
            }
            if let reason = Summarizer.unavailableReason {
                suggestionState = .unavailable(reason)
                return
            }
            guard DocumentIssue.hasText(text) else {
                suggestionState = .failed("Auf den ersten Seiten wurde kein Text erkannt.")
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
                if dateSource != .manual, let date = suggestion.date {
                    applyDate(date)
                    dateFromAI = true
                }
                suggestionState = .done
            } catch {
                if !Task.isCancelled { suggestionState = .failed(error.localizedDescription) }
            }
        }
    }

    private func applyDate(_ date: Date?) {
        withoutEditTracking { documentDate = date ?? Date() }
        dateSource = date == nil ? .today : .document
        dateFromAI = false
    }

    /// OCR einer Seite in ihrer aktuellen Drehung, aus dem Cache oder neu erkannt.
    private func ocrLines(for page: ScannedPage) async -> [OCRLine]? {
        if let cached = ocrCache[page.id], cached.rotated == page.rotated180 { return cached.lines }
        let lines = try? await Self.recognize(url: page.url, rotated: page.rotated180)
        if let lines { ocrCache[page.id] = (page.rotated180, lines) }
        return lines
    }

    nonisolated private static func loadImage(url: URL, rotated: Bool) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) { () throws -> CGImage in
            guard let image = ImageTools.load(url) else {
                throw ScannerError.scanFailed("Seitenbild \(url.lastPathComponent) nicht lesbar.")
            }
            return rotated ? ImageTools.rotated180(image) : image
        }.value
    }

    nonisolated private static func recognize(url: URL, rotated: Bool) async throws -> [OCRLine] {
        try await OCRService.recognize(loadImage(url: url, rotated: rotated))
    }

    // MARK: Speichern

    func save() {
        guard let archive = model.archive, let index = model.index else {
            phase = .failed(model.error ?? "Kein Archivordner.")
            return
        }
        analysisTask?.cancel()
        backgroundOCRTask?.cancel()
        let date = documentDate
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = pages
        let dpi = Double(dpi)
        let preset = SettingsKey.preset(SettingsKey.scanPreset)
        let colorMode = scanColorMode

        // Probleme und Herkunft, die schon jetzt feststehen
        var issues: [DocumentIssue] = []
        if title.isEmpty {
            switch suggestionState {
            case let .unavailable(reason), let .failed(reason): issues.append(.noSuggestion(reason))
            default: issues.append(.noSuggestion(""))
            }
        }
        if dateSource == .today { issues.append(.noDate) }
        let metaDateSource: DocumentMetadata.DateSource = switch dateSource {
        case .document: dateFromAI ? .ai : .text
        case .today: .today
        case .manual: .manual
        }
        let titleSource: DocumentMetadata.TitleSource = title.isEmpty ? .none : (titleEdited || summaryEdited ? .manual : .ai)
        let scanInfo = DocumentMetadata.ScanInfo(scanner: scanner.selected?.name, dpi: Int(dpi), colorMode: colorMode)

        Task {
            do {
                // Texterkennung für alle Seiten (meist schon im Hintergrund erledigt), dann komprimieren
                var pdfPages: [PDFPageInput] = []
                var textSources: [DocumentMetadata.TextSource] = []
                var emptyPages: [Int] = []
                var texts: [String] = []
                for (i, page) in snapshot.enumerated() {
                    let lines: [OCRLine]
                    if let cached = ocrCache[page.id], cached.rotated == page.rotated180 {
                        lines = cached.lines
                    } else {
                        phase = .processing("Texterkennung Seite \(i + 1) von \(snapshot.count) …")
                        lines = try await Self.recognize(url: page.url, rotated: page.rotated180)
                    }
                    let text = lines.map(\.text).joined(separator: "\n")
                    let hasText = DocumentIssue.hasText(text)
                    if !hasText { emptyPages.append(i + 1) }
                    textSources.append(hasText ? .ocr : .none)
                    texts.append(text)
                    phase = .processing("Seite \(i + 1) von \(snapshot.count) wird komprimiert …")
                    let image = try await Self.loadImage(url: page.url, rotated: page.rotated180)
                    let size = CGSize(width: Double(image.width) / dpi * 72, height: Double(image.height) / dpi * 72)
                    let encoded = await Task.detached {
                        PageCompressor.encode(image, pageSize: size, preset: preset, color: colorMode)
                    }.value
                    pdfPages.append(PDFPageInput(encoded: encoded, lines: lines))
                }
                if !emptyPages.isEmpty { issues.insert(.noText(pages: emptyPages), at: 0) }
                phase = .processing("PDF wird gespeichert …")

                var meta = DocumentMetadata(
                    number: 0, documentDate: date, dateSource: metaDateSource, titleSource: titleSource,
                    titleUpdated: title.isEmpty ? nil : Date(), archivedAt: Date(), source: .scan, scan: scanInfo,
                    pages: textSources, ocr: .init(), issues: issues, storage: .created)
                let pagesToSave = pdfPages
                let draft = meta
                let saved = try await Task.detached(priority: .userInitiated) { () throws -> (number: Int, url: URL, meta: DocumentMetadata) in
                    var stored = draft
                    let result = try archive.save(date: date, title: title) { number in
                        let data = try PDFBuilder.build(pages: pagesToSave, number: number, date: date, dpi: dpi,
                                                        title: title, summary: summary)
                        stored.number = number
                        stored.compression = .init(preset: preset, colorMode: colorMode, applied: preset != .original,
                                                   originalBytes: nil, resultBytes: data.count)
                        return try PDFMetadata.finalize(data, meta: stored, title: title, summary: summary)
                    }
                    return (result.number, result.url, stored)
                }.value
                meta = saved.meta
                try index.add(number: saved.number, date: date, url: saved.url, pages: pdfPages.count,
                              text: texts.joined(separator: "\n\n"), title: title, summary: summary, meta: meta)
                model.didSave()
                reset()
                savedIssues = issues
                phase = .saved(saved.url)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
