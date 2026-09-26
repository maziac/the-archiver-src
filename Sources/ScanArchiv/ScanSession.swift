import AppKit
import Foundation
import Observation
import os
import ScanArchivCore

struct ScannedPage: Identifiable {
    enum Kind { case front, back, single }

    let id = UUID()
    let url: URL
    let kind: Kind
    /// Miniatur des Scans in Originallage
    let baseThumbnail: CGImage?
    /// Miniatur in der aktuellen Drehung
    private(set) var thumbnail: NSImage
    /// Drehung im Uhrzeigersinn (0, 90, 180, 270)
    private(set) var rotation: Int
    /// Ausrichtung wurde schon automatisch geprüft
    var orientationChecked = false
    /// Drehung stammt von der automatischen Erkennung
    var autoRotated = false
    /// Vom Benutzer gedreht – die Erkennung ändert dann nichts mehr
    var manuallyRotated = false

    init(url: URL, kind: Kind, rotation: Int) {
        self.url = url
        self.kind = kind
        baseThumbnail = ImageTools.thumbnail(url, maxPixel: 1400)  // groß genug für lesbare Seitenzahlen
        self.rotation = 0
        thumbnail = NSImage()
        setRotation(rotation)
    }

    mutating func setRotation(_ degrees: Int) {
        rotation = (degrees % 360 + 360) % 360
        thumbnail = baseThumbnail.map { NSImage(cgImage: ImageTools.rotated($0, clockwise: rotation), size: .zero) } ?? NSImage()
    }
}

/// Führt durch den Scan: als Stapel in zwei Durchgängen (Vorderseiten → wenden → Rückseiten) oder
/// Seite für Seite; danach Vorschau → Speichern.
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
        /// Seite für Seite: eine Seite wird gescannt
        case scanningSingle
        /// Seite für Seite: gescannt, noch eine?
        case singleNext
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
    /// Quelle beim Scannen Seite für Seite (gemerkt)
    var singleSource: ScanSource = ScanSource(rawValue: UserDefaults.standard.string(forKey: SettingsKey.singleSource) ?? "") ?? .flatbed {
        didSet { UserDefaults.standard.set(singleSource.rawValue, forKey: SettingsKey.singleSource) }
    }
    /// Fehler beim letzten Einzelscan (die bisherigen Seiten bleiben erhalten)
    private(set) var singleError: String?

    /// Hinweis, wenn die gedruckten Seitenzahlen nicht zur Reihenfolge passen.
    enum OrderHint: Equatable {
        /// eindeutig: vorgeschlagene Reihenfolge (Seiten-IDs); `sequence` = Seitenzahlen in aktueller Lage
        case reorder([UUID], sequence: [Int])
        /// passt nicht, aber nicht eindeutig (gefundene Nummern, nil = keine)
        case uncertain([Int?])
    }
    private(set) var orderHint: OrderHint?
    private static let log = Logger(subsystem: "de.local.scanarchiv", category: "scan")
    /// Reihenfolge, für die der Hinweis mit „Ignorieren“ ausgeblendet wurde
    @ObservationIgnored private var orderHintDismissedFor: [UUID]?

    // Metadaten-Vorschlag (bearbeitbar in der Vorschau)
    var title = "" { didSet { if !applying { titleEdited = true } } }
    var summary = "" { didSet { if !applying { summaryEdited = true } } }
    var categories: [String] = [] { didSet { if !applying { categoriesEdited = true } } }
    var documentDate = Date() { didSet { if !applying { dateSource = .manual } } }
    private(set) var dateSource: DateSource = .today
    /// Datum stammt von Apple Intelligence (sonst direkt aus dem Text)
    @ObservationIgnored private var dateFromAI = false
    private(set) var suggestionState: SuggestionState = .idle
    /// Probleme des zuletzt gespeicherten Dokuments (für die Anzeige nach dem Speichern)
    private(set) var savedIssues: [DocumentIssue] = []
    @ObservationIgnored private var titleEdited = false
    @ObservationIgnored private var summaryEdited = false
    @ObservationIgnored private var categoriesEdited = false
    /// Kategorien stammen aus einem Vorschlag oder wurden von Hand gesetzt (sonst: noch nicht kategorisiert)
    @ObservationIgnored private var categoriesDecided = false
    @ObservationIgnored private var applying = false
    /// OCR-Ergebnis je Seite, gültig für die gespeicherte Drehung
    @ObservationIgnored private var ocrCache: [UUID: (rotation: Int, lines: [OCRLine])] = [:]
    /// Text, zu dem der aktuelle Vorschlag gehört (dann muss nicht erneut gefragt werden)
    @ObservationIgnored private var suggestedText: String?
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
    private var autoOrient: Bool { UserDefaults.standard.bool(forKey: SettingsKey.autoOrient) }

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

    // MARK: Seite für Seite

    /// Scannt eine weitere Seite und hängt sie hinten an (auch aus der Vorschau heraus).
    func scanSinglePage() {
        let source = scanner.sources.contains(singleSource) ? singleSource : (scanner.sources.first ?? singleSource)
        singleError = nil
        phase = .scanningSingle
        let folder = workFolder.appendingPathComponent("einzeln-\(UUID().uuidString.prefix(6))")
        Task {
            do {
                let urls = try await scanner.scan(source: source, dpi: dpi, color: color, into: folder)
                if urls.isEmpty { singleError = "Es wurde keine Seite gescannt." }
                pages += urls.map { ScannedPage(url: $0, kind: .single, rotation: 0) }
                startAnalysis()  // Texterkennung läuft schon, während die nächste Seite aufgelegt wird
            } catch {
                singleError = error.localizedDescription
            }
            phase = .singleNext
        }
    }

    /// Letzte Seite verwerfen und erneut scannen.
    func rescanLastPage() {
        if let last = pages.last { remove(last) }
        scanSinglePage()
    }

    func finishSingle() {
        singleError = nil
        guard !pages.isEmpty else { reset(); return }
        phase = .preview
        Summarizer.prewarm()
        startAnalysis()
    }

    func cancelScan() { scanner.cancelScan() }

    private func buildPreview() {
        let rotateBacks = UserDefaults.standard.bool(forKey: SettingsKey.rotateBacks)
        let frontPages = fronts.map { ScannedPage(url: $0, kind: .front, rotation: 0) }
        let backPages = backs.map { ScannedPage(url: $0, kind: .back, rotation: rotateBacks ? 180 : 0) }
        pages = PageOrder.interleave(fronts: frontPages, backsScannedReversed: backPages)
        phase = .preview
        Summarizer.prewarm()
        startAnalysis()
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
        suggestedText = nil
        singleError = nil
        orderHint = nil
        orderHintDismissedFor = nil
        withoutEditTracking {
            title = ""
            summary = ""
            categories = []
            documentDate = Date()
        }
        titleEdited = false
        summaryEdited = false
        categoriesEdited = false
        categoriesDecided = false
        dateSource = .today
        suggestionState = .idle
        phase = .ready
    }

    /// Dreht eine Seite um `degrees` im Uhrzeigersinn (negativ = gegen den Uhrzeigersinn).
    func rotate(_ page: ScannedPage, by degrees: Int) {
        guard let i = pages.firstIndex(where: { $0.id == page.id }) else { return }
        pages[i].setRotation(pages[i].rotation + degrees)
        pages[i].manuallyRotated = true
        pages[i].autoRotated = false
        startAnalysis()  // gedrehte Seite neu erkennen, Vorschlag ggf. verbessern
    }

    /// Verschiebt eine Seite an die Stelle einer anderen (Ziehen in der Vorschau).
    func move(pageID: UUID, to target: UUID) {
        guard pageID != target,
              let from = pages.firstIndex(where: { $0.id == pageID }),
              let to = pages.firstIndex(where: { $0.id == target }) else { return }
        pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        startAnalysis()  // erste Seiten können sich geändert haben
    }

    func remove(_ page: ScannedPage) {
        pages.removeAll { $0.id == page.id }
        startAnalysis()
    }

    /// Übernimmt die Reihenfolge laut Seitenzahlen.
    func applyOrderHint() {
        guard case let .reorder(ids, _) = orderHint else { return }
        let byID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        let reordered = ids.compactMap { byID[$0] }
        guard reordered.count == pages.count else { orderHint = nil; return }
        pages = reordered
        orderHint = nil
        startAnalysis()
    }

    /// Blendet den Hinweis aus, bis sich die Seiten ändern.
    func dismissOrderHint() {
        orderHintDismissedFor = pages.map(\.id)
        orderHint = nil
    }

    /// Prüft die Reihenfolge anhand der Seitenzahlen, sobald alle Seiten erkannt sind.
    private func checkPageOrder() {
        let ids = pages.map(\.id)
        guard orderHintDismissedFor != ids else { orderHint = nil; return }
        var texts: [String] = []
        for page in pages {
            guard let cached = ocrCache[page.id], cached.rotation == page.rotation else {
                Self.log.notice("Reihenfolge: Seite ohne Texterkennung – keine Prüfung")
                return
            }
            // von oben nach unten, damit Kopf- und Fußzeile sicher am Anfang bzw. Ende stehen
            let sorted = cached.lines.sorted { $0.box.midY > $1.box.midY }
            texts.append(sorted.map(\.text).joined(separator: "\n"))
        }
        let result = PageNumbering.analyze(pageTexts: texts)
        Self.log.notice("Reihenfolge: \(String(describing: result), privacy: .public) – Seitenzahlen \(texts.map { PageNumbering.pageNumber(in: $0).map { String($0.number) } ?? "–" }.joined(separator: ","), privacy: .public)")
        switch result {
        case let .reorder(order):
            orderHint = .reorder(order.map { ids[$0] }, sequence: PageNumbering.originalSequence(order))
        case let .uncertain(numbers):
            orderHint = .uncertain(numbers)
        case .none, .inOrder:
            orderHint = nil
        }
    }

    /// Verwirft eigene Eingaben und fragt Apple Intelligence erneut.
    func resuggest() {
        suggestedText = nil
        titleEdited = false
        summaryEdited = false
        categoriesEdited = false
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
        let ids = pages.map(\.id)
        let first = Array(ids.prefix(Self.suggestionPageCount))
        if case let .reorder(proposed, _) = orderHint, Set(proposed) != Set(ids) { orderHint = nil }

        analysisTask = Task {
            if suggestedText == nil || suggestionState != .done { suggestionState = .recognizing }
            var texts: [String] = []
            for id in first {
                if let lines = await prepare(id) { texts.append(lines.map(\.text).joined(separator: "\n")) }
                if Task.isCancelled { return }
            }
            // restliche Seiten erst jetzt, damit sie der Vorschlags-OCR nicht in die Quere kommen
            backgroundOCRTask = Task {
                for id in ids.dropFirst(Self.suggestionPageCount) {
                    if Task.isCancelled { return }
                    _ = await prepare(id)
                }
                if !Task.isCancelled { checkPageOrder() }
            }
            let text = texts.joined(separator: "\n\n")
            // gleicher Text wie beim letzten Vorschlag (z. B. nur hinten Seiten dazu) → nichts zu tun
            if text == suggestedText, suggestionState == .done { return }

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
                let suggestion = try await Summarizer.suggest(for: text, knownCategories: model.knownCategories)
                if Task.isCancelled { return }
                withoutEditTracking {
                    if !titleEdited { title = suggestion.title }
                    if !summaryEdited { summary = suggestion.summary }
                    if !categoriesEdited { categories = suggestion.categories }
                }
                categoriesDecided = true
                if dateSource != .manual, let date = suggestion.date {
                    applyDate(date)
                    dateFromAI = true
                }
                suggestedText = text
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

    /// Richtet eine Seite (einmalig) automatisch aus und erkennt ihren Text in der aktuellen Drehung.
    private func prepare(_ id: UUID) async -> [OCRLine]? {
        guard let page = pages.first(where: { $0.id == id }) else { return nil }
        if autoOrient, !page.orientationChecked, !page.manuallyRotated {
            let detected = try? await OCRService.detectOrientation(Self.loadImage(url: page.url, rotation: 0))
            if Task.isCancelled { return nil }
            if let i = pages.firstIndex(where: { $0.id == id }) {
                pages[i].orientationChecked = true
                if let detected, !pages[i].manuallyRotated, detected != pages[i].rotation {
                    pages[i].setRotation(detected)
                    pages[i].autoRotated = true
                }
            }
        }
        guard let current = pages.first(where: { $0.id == id }) else { return nil }
        return await ocrLines(for: current)
    }

    /// OCR einer Seite in ihrer aktuellen Drehung, aus dem Cache oder neu erkannt.
    private func ocrLines(for page: ScannedPage) async -> [OCRLine]? {
        if let cached = ocrCache[page.id], cached.rotation == page.rotation { return cached.lines }
        let lines = try? await Self.recognize(url: page.url, rotation: page.rotation)
        if let lines { ocrCache[page.id] = (page.rotation, lines) }
        return lines
    }

    nonisolated private static func loadImage(url: URL, rotation: Int) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) { () throws -> CGImage in
            guard let image = ImageTools.load(url) else {
                throw ScannerError.scanFailed("Seitenbild \(url.lastPathComponent) nicht lesbar.")
            }
            return ImageTools.rotated(image, clockwise: rotation)
        }.value
    }

    nonisolated private static func recognize(url: URL, rotation: Int) async throws -> [OCRLine] {
        try await OCRService.recognize(loadImage(url: url, rotation: rotation))
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
        // ohne Vorschlag und ohne Eingabe: noch nicht kategorisiert (später per „Kategorien erzeugen“)
        let categories: [String]? = categoriesDecided || categoriesEdited ? categories : nil
        let ids = pages.map(\.id)
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
                // Ausrichtung + Texterkennung für alle Seiten (meist schon im Hintergrund erledigt)
                for (i, id) in ids.enumerated() {
                    guard let page = pages.first(where: { $0.id == id }) else { continue }
                    if ocrCache[id]?.rotation != page.rotation || (autoOrient && !page.orientationChecked && !page.manuallyRotated) {
                        phase = .processing("Texterkennung Seite \(i + 1) von \(ids.count) …")
                    }
                    guard await prepare(id) != nil else {
                        throw ScannerError.scanFailed("Texterkennung für Seite \(i + 1) fehlgeschlagen.")
                    }
                }
                // Wurde vor Ende der Texterkennung gespeichert, hat der Benutzer einen Reihenfolge-Hinweis
                // noch nicht gesehen → erst zeigen; danach speichert „Speichern“ so, wie er es entscheidet.
                if orderHint == nil {
                    checkPageOrder()
                    if orderHint != nil {
                        phase = .preview
                        return
                    }
                }
                let snapshot = ids.compactMap { id in pages.first { $0.id == id } }

                // komprimieren
                var pdfPages: [PDFPageInput] = []
                var textSources: [DocumentMetadata.TextSource] = []
                var emptyPages: [Int] = []
                var texts: [String] = []
                for (i, page) in snapshot.enumerated() {
                    let lines = ocrCache[page.id]?.lines ?? []
                    let text = lines.map(\.text).joined(separator: "\n")
                    phase = .processing("Seite \(i + 1) von \(snapshot.count) wird komprimiert …")
                    let image = try await Self.loadImage(url: page.url, rotation: page.rotation)
                    // ohne Text: leere Seite (kein Problem) oder Inhalt ohne erkennbaren Text (Problem)
                    if DocumentIssue.hasText(text) {
                        textSources.append(.ocr)
                    } else if await Task.detached(operation: { BlankPage.isBlank(image) }).value {
                        textSources.append(.blank)
                    } else {
                        textSources.append(.none)
                        emptyPages.append(i + 1)
                    }
                    texts.append(text)
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
                meta.categories = categories
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
