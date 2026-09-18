import AppKit
import Foundation
import Observation
import ScanArchivCore
import UniformTypeIdentifiers

/// Ein importiertes PDF, dessen Seiten unverändert übernommen werden.
final class ImportedPDF: @unchecked Sendable {
    let url: URL
    let document: CGPDFDocument
    /// eigener Text je Seite; leer = Seite enthält nur ein Bild und braucht OCR
    let pageTexts: [String]

    init?(url: URL) {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return nil }
        self.url = url
        self.document = document
        pageTexts = PDFStamper.pageTexts(of: url)
    }
}

struct ScannedPage: Identifiable {
    enum Kind { case front, back, imported }

    enum Source {
        /// Scan oder importiertes Bild; dpi nil = Scan-Auflösung aus den Einstellungen
        case image(URL, dpi: Double?)
        /// Seite eines importierten PDFs (Index ab 0)
        case pdf(ImportedPDF, index: Int)
    }

    let id = UUID()
    let source: Source
    let kind: Kind
    let thumbnail: NSImage
    var rotated180: Bool

    /// Eigener Text der PDF-Seite (dann keine OCR nötig), sonst nil.
    var embeddedText: String? {
        if case let .pdf(pdf, index) = source, !pdf.pageTexts[index].isEmpty { return pdf.pageTexts[index] }
        return nil
    }
}

/// Führt durch den zweiteiligen Scan (Vorderseiten → wenden → Rückseiten) oder den Import von Dateien,
/// zeigt die Vorschau mit Vorschlägen und speichert ins Archiv.
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
    @ObservationIgnored private var backgroundOCRTask: Task<Void, Never>?

    // Import mehrerer Dateien: jede Datei wird ein eigenes Dokument
    private(set) var importQueue: [URL] = []
    private(set) var importTotal = 0
    private(set) var currentFileName: String?
    /// Restliche Dateien ohne Vorschau mit den Vorschlägen speichern
    private(set) var autoSaveRemaining = false
    /// Rückmeldung nach dem Speichern, während schon die nächste Datei in der Vorschau ist
    private(set) var lastSavedName: String?
    var importPosition: Int { importTotal - importQueue.count }

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
    private var color: Bool { UserDefaults.standard.bool(forKey: SettingsKey.color) }

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
                    buildScanPreview()
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
        buildScanPreview()
    }

    func acceptMismatch() { buildScanPreview() }

    func backToPreview() { phase = .preview }

    func cancelScan() { scanner.cancelScan() }

    private func buildScanPreview() {
        let rotateBacks = UserDefaults.standard.bool(forKey: SettingsKey.rotateBacks)
        let frontPages = fronts.map { makePage(.image($0, dpi: nil), kind: .front, rotated: false) }
        let backPages = backs.map { makePage(.image($0, dpi: nil), kind: .back, rotated: rotateBacks) }
        showPreview(PageOrder.interleave(fronts: frontPages, backsScannedReversed: backPages))
    }

    // MARK: Vorschau zurücksetzen

    /// Verwirft das aktuelle Dokument (Seiten, Vorschläge), behält aber die Import-Warteschlange.
    private func clearDocument() {
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
        currentFileName = nil
    }

    /// Alles verwerfen, auch noch nicht verarbeitete Dateien.
    func reset() {
        clearDocument()
        importQueue = []
        importTotal = 0
        autoSaveRemaining = false
        lastSavedName = nil
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

    private func makePage(_ source: ScannedPage.Source, kind: ScannedPage.Kind, rotated: Bool) -> ScannedPage {
        let thumb: CGImage?
        switch source {
        case let .image(url, _):
            thumb = ImageTools.thumbnail(url)
        case let .pdf(pdf, index):
            thumb = ImageTools.renderPDFPage(pdf.document, index: index, dpi: 40, gray: false)
        }
        return ScannedPage(source: source, kind: kind, thumbnail: thumb.map { NSImage(cgImage: $0, size: .zero) } ?? NSImage(),
                           rotated180: rotated)
    }

    private func showPreview(_ newPages: [ScannedPage]) {
        pages = newPages
        phase = .preview
        Summarizer.prewarm()
        startAnalysis()
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
                if let text = await pageText(page) { texts.append(text) }
                if Task.isCancelled { return }
            }
            // restliche Seiten erst jetzt, damit sie der Vorschlags-OCR nicht in die Quere kommen
            backgroundOCRTask = Task {
                for page in snapshot.dropFirst(Self.suggestionPageCount) {
                    if Task.isCancelled { return }
                    _ = await pageText(page)
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
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

    /// Text einer Seite: eingebetteter PDF-Text oder OCR-Ergebnis.
    private func pageText(_ page: ScannedPage) async -> String? {
        if let embedded = page.embeddedText { return embedded }
        return await ocrLines(for: page)?.map(\.text).joined(separator: "\n")
    }

    /// OCR einer Seite in ihrer aktuellen Drehung, aus dem Cache oder neu erkannt.
    private func ocrLines(for page: ScannedPage) async -> [OCRLine]? {
        if let cached = ocrCache[page.id], cached.rotated == page.rotated180 { return cached.lines }
        let source = page.source, rotated = page.rotated180
        let lines = try? await Self.recognize(source: source, rotated: rotated)
        if let lines { ocrCache[page.id] = (rotated, lines) }
        return lines
    }

    nonisolated private static func recognize(source: ScannedPage.Source, rotated: Bool) async throws -> [OCRLine] {
        let image = try await Task.detached(priority: .userInitiated) { () throws -> CGImage in
            switch source {
            case let .image(url, _):
                guard let image = ImageTools.load(url) else {
                    throw ScannerError.scanFailed("Seitenbild \(url.lastPathComponent) nicht lesbar.")
                }
                return rotated ? ImageTools.rotated180(image) : image
            case let .pdf(pdf, index):
                guard let image = ImageTools.renderPDFPage(pdf.document, index: index, dpi: 300, gray: true,
                                                           extraRotation: rotated ? 180 : 0) else {
                    throw ScannerError.scanFailed("Seite \(index + 1) von \(pdf.url.lastPathComponent) nicht lesbar.")
                }
                return image
            }
        }.value
        return try await OCRService.recognize(image)
    }

    // MARK: Import aus Dateien

    static let importableTypes: [UTType] = [.pdf, .png, .jpeg, .tiff, .heic, .bmp, .gif]

    /// Jede Datei wird ein eigenes Dokument; sie laufen nacheinander durch die Vorschau.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        clearDocument()
        importQueue = urls
        importTotal = urls.count
        autoSaveRemaining = false
        lastSavedName = nil
        Task { await loadNextFile() }
    }

    /// Nächste Datei aus der Warteschlange in die Vorschau laden. false = keine Datei mehr.
    @discardableResult
    private func loadNextFile() async -> Bool {
        guard !importQueue.isEmpty else { return false }
        let url = importQueue.removeFirst()
        clearDocument()
        currentFileName = url.lastPathComponent
        phase = .processing("\(url.lastPathComponent) wird eingelesen …")

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                // PDF bleibt inhaltlich unverändert; für die Vorschau nur die Seiten referenzieren
                let pdf = try await Task.detached { () throws -> ImportedPDF in
                    guard let pdf = ImportedPDF(url: url) else {
                        throw ScannerError.scanFailed("\(url.lastPathComponent) ist kein lesbares PDF.")
                    }
                    return pdf
                }.value
                let newPages = (0..<pdf.document.numberOfPages).map { makePage(.pdf(pdf, index: $0), kind: .imported, rotated: false) }
                showPreview(newPages)
            } else {
                // Bild: Kopie ins Arbeitsverzeichnis, Auflösung aus den Bilddaten
                let folder = workFolder.appendingPathComponent("import", isDirectory: true)
                let copy = try await Task.detached { () throws -> (URL, Double) in
                    guard let image = ImageTools.load(url) else {
                        throw ScannerError.scanFailed("\(url.lastPathComponent) ist kein lesbares Bild.")
                    }
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let target = folder.appendingPathComponent("0001.png")
                    try ImageTools.writePNG(image, to: target)
                    return (target, ImageTools.dpi(of: url, width: image.width))
                }.value
                showPreview([makePage(.image(copy.0, dpi: copy.1), kind: .imported, rotated: false)])
            }
            return true
        } catch {
            autoSaveRemaining = false
            phase = .failed(error.localizedDescription)
            return true
        }
    }

    /// Aktuelle Datei überspringen (nicht speichern) und die nächste laden.
    func skipFile() {
        Task {
            if await !loadNextFile() { reset() }
        }
    }

    /// Automatik nach dem aktuellen Dokument anhalten; die nächste Datei erscheint wieder in der Vorschau.
    func stopAutoSave() { autoSaveRemaining = false }

    /// Aktuelles und alle restlichen Dokumente mit den Vorschlägen speichern, ohne Vorschau.
    func saveAllRemaining() {
        autoSaveRemaining = true
        save()
    }

    // MARK: Speichern

    func save() {
        Task { await saveLoop() }
    }

    /// Speichert das aktuelle Dokument; bei laufendem Import geht es mit der nächsten Datei weiter,
    /// im Automatikmodus ohne Halt in der Vorschau.
    private func saveLoop() async {
        while true {
            if autoSaveRemaining {
                // Vorschlag abwarten, damit Titel/Beschreibung/Datum drin sind
                phase = .processing("Vorschlag für \(currentFileName ?? "Dokument") …")
                await analysisTask?.value
            }
            guard let url = await saveCurrent() else { return }
            lastSavedName = url.lastPathComponent
            if importQueue.isEmpty {
                let total = importTotal
                clearDocument()
                importTotal = 0
                autoSaveRemaining = false
                phase = .saved(url)
                if total > 1 { lastSavedName = "\(total) Dateien verarbeitet" } else { lastSavedName = nil }
                return
            }
            await loadNextFile()
            if !autoSaveRemaining || phase != .preview { return }
        }
    }

    /// Speichert das aktuelle Dokument ins Archiv. nil bei Fehler (Phase ist dann `.failed`).
    private func saveCurrent() async -> URL? {
        guard let archive = model.archive, let index = model.index else {
            phase = .failed(model.error ?? "Kein Archivordner.")
            return nil
        }
        analysisTask?.cancel()
        backgroundOCRTask?.cancel()
        let date = documentDate
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = pages

        do {
            // Texterkennung für Seiten ohne eigenen Text (meist schon im Hintergrund erledigt)
            var lines: [UUID: [OCRLine]] = [:]
            for (i, page) in snapshot.enumerated() where page.embeddedText == nil {
                if ocrCache[page.id]?.rotated != page.rotated180 {
                    phase = .processing("Texterkennung Seite \(i + 1) von \(snapshot.count) …")
                }
                if let cached = ocrCache[page.id], cached.rotated == page.rotated180 {
                    lines[page.id] = cached.lines
                } else {
                    lines[page.id] = try await Self.recognize(source: page.source, rotated: page.rotated180)
                }
            }
            phase = .processing("PDF wird gespeichert …")

            let dpi = Double(dpi)
            let quality = UserDefaults.standard.double(forKey: SettingsKey.jpegQuality)
            let saved = try await Task.detached(priority: .userInitiated) { () throws -> (number: Int, url: URL) in
                if case let .pdf(pdf, _)? = snapshot.first?.source {
                    // PDF-Import: Original bleibt, nur Stempel, Textebene und Metadaten kommen dazu
                    let edits = snapshot.compactMap { page -> PDFStamper.PageEdit? in
                        guard case let .pdf(_, pageIndex) = page.source else { return nil }
                        return PDFStamper.PageEdit(index: pageIndex, extraRotation: page.rotated180 ? 180 : 0,
                                                   lines: lines[page.id] ?? [])
                    }
                    return try archive.save(date: date, title: title) { number in
                        try PDFStamper.stamp(source: pdf.url, pages: edits, number: number, date: date,
                                             title: title, summary: summary)
                    }
                }
                // Scan oder Bild: neues PDF aus den Seitenbildern
                var pdfPages: [PDFPageInput] = []
                for page in snapshot {
                    guard case let .image(url, pageDPI) = page.source, var image = ImageTools.load(url) else {
                        throw ScannerError.scanFailed("Seitenbild nicht lesbar.")
                    }
                    if page.rotated180 { image = ImageTools.rotated180(image) }
                    pdfPages.append(PDFPageInput(image: image, lines: lines[page.id] ?? [], dpi: pageDPI))
                }
                return try archive.save(date: date, title: title) { number in
                    try PDFBuilder.build(pages: pdfPages, number: number, date: date, dpi: dpi, jpegQuality: quality,
                                         title: title, summary: summary)
                }
            }.value

            let text = snapshot.map { page in
                page.embeddedText ?? (lines[page.id] ?? []).map(\.text).joined(separator: "\n")
            }.joined(separator: "\n\n")
            try index.add(number: saved.number, date: date, url: saved.url, pages: snapshot.count, text: text,
                          title: title, summary: summary)
            model.didSave()
            return saved.url
        } catch {
            autoSaveRemaining = false
            phase = .failed(error.localizedDescription)
            return nil
        }
    }
}
