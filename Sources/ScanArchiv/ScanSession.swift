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

    private(set) var phase: Phase = .ready
    private(set) var fronts: [URL] = []
    private(set) var backs: [URL] = []
    var pages: [ScannedPage] = []

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
        try? FileManager.default.removeItem(at: workFolder)
        workFolder = ScanSession.newWorkFolder()
        fronts = []
        backs = []
        pages = []
        phase = .ready
    }

    func toggleRotation(_ page: ScannedPage) {
        guard let i = pages.firstIndex(where: { $0.id == page.id }) else { return }
        pages[i].rotated180.toggle()
    }

    func remove(_ page: ScannedPage) {
        pages.removeAll { $0.id == page.id }
    }

    private func buildPreview() {
        let rotateBacks = UserDefaults.standard.bool(forKey: SettingsKey.rotateBacks)
        let frontPages = fronts.map { makePage($0, isBack: false, rotated: false) }
        let backPages = backs.map { makePage($0, isBack: true, rotated: rotateBacks) }
        pages = PageOrder.interleave(fronts: frontPages, backsScannedReversed: backPages)
        phase = .preview
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
        let input = pages.map { (url: $0.url, rotated: $0.rotated180) }
        let dpi = Double(dpi)
        let quality = UserDefaults.standard.double(forKey: SettingsKey.jpegQuality)
        let date = Date()
        phase = .processing("Texterkennung …")

        Task.detached(priority: .userInitiated) {
            do {
                var pdfPages: [PDFPageInput] = []
                for (i, page) in input.enumerated() {
                    await MainActor.run { self.phase = .processing("Texterkennung Seite \(i + 1) von \(input.count) …") }
                    guard var image = ImageTools.load(page.url) else {
                        throw ScannerError.scanFailed("Seitenbild \(page.url.lastPathComponent) nicht lesbar.")
                    }
                    if page.rotated { image = ImageTools.rotated180(image) }
                    pdfPages.append(PDFPageInput(image: image, lines: try OCRService.recognize(image)))
                }
                await MainActor.run { self.phase = .processing("PDF wird gespeichert …") }
                let saved = try archive.save(date: date) { number in
                    try PDFBuilder.build(pages: pdfPages, number: number, date: date, dpi: dpi, jpegQuality: quality)
                }
                let text = pdfPages.map { $0.lines.map(\.text).joined(separator: "\n") }.joined(separator: "\n\n")
                try index.add(number: saved.number, date: date, url: saved.url, pages: pdfPages.count, text: text)
                await MainActor.run {
                    try? FileManager.default.removeItem(at: self.workFolder)
                    self.workFolder = ScanSession.newWorkFolder()
                    self.model.didSave()
                    self.phase = .saved(saved.url)
                }
            } catch {
                await MainActor.run { self.phase = .failed(error.localizedDescription) }
            }
        }
    }
}
