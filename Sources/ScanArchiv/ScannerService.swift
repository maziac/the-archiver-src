import Foundation
import ImageCaptureCore
import Observation
import os
import UniformTypeIdentifiers

enum ScannerError: LocalizedError {
    case noScanner
    case notReady
    case busy
    case scanFailed(String)

    var errorDescription: String? {
        switch self {
        case .noScanner: return "Kein Scanner gefunden."
        case .notReady: return "Der Scanner ist noch nicht bereit."
        case .busy: return "Es läuft bereits ein Scan."
        case let .scanFailed(message): return message
        }
    }
}

/// Woher gescannt wird.
enum ScanSource: String, CaseIterable, Identifiable {
    case feeder, flatbed

    var id: String { rawValue }
    var label: String { self == .feeder ? "Einzug" : "Vorlagenglas" }
    var unitType: ICScannerFunctionalUnitType { self == .feeder ? .documentFeeder : .flatbed }
}

/// Steuert Netzwerk-/USB-Scanner über ImageCaptureCore: Stapel über den Vorlageneinzug (ADF),
/// einzelne Seiten wahlweise über Einzug oder Vorlagenglas.
@Observable
@MainActor
final class ScannerService: NSObject {
    private(set) var scanners: [ICScannerDevice] = []
    private(set) var selected: ICScannerDevice?
    /// Session offen und eine Scanfunktion ausgewählt
    private(set) var isReady = false
    /// Quellen, die der Scanner anbietet
    private(set) var sources: [ScanSource] = []
    private(set) var statusText = "Suche Scanner …" {
        didSet { ScannerService.log.info("\(self.statusText, privacy: .public)") }
    }
    private static let log = Logger(subsystem: "de.local.scanarchiv", category: "scanner")
    /// Seiten, die im laufenden Durchgang schon angekommen sind
    private(set) var pagesInCurrentScan = 0

    @ObservationIgnored private let browser = ICDeviceBrowser()
    @ObservationIgnored private var scannedURLs: [URL] = []
    @ObservationIgnored private var continuation: CheckedContinuation<[URL], Error>?
    /// Wartet auf den Wechsel zwischen Einzug und Vorlagenglas
    @ObservationIgnored private var unitContinuation: CheckedContinuation<Void, Error>?
    @ObservationIgnored private var requestedUnit: ICScannerFunctionalUnitType?
    /// Seiten aus früheren Teilen desselben Stapels (für die Fortschrittsanzeige)
    @ObservationIgnored private var pageOffset = 0

    override init() {
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.scanner.rawValue
            | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue
            | ICDeviceLocationTypeMask.shared.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
        browser.start()
    }

    func select(_ scanner: ICScannerDevice) {
        guard scanner !== selected else { return }
        if let old = selected, old.hasOpenSession { old.requestCloseSession() }
        selected = scanner
        isReady = false
        sources = []
        statusText = "Verbinde mit \(scanner.name ?? "Scanner") …"
        scanner.delegate = self
        scanner.requestOpenSession()
    }

    /// Scannt alle Blätter im Einzug und liefert die Seitenbilder (PNG) in Scan-Reihenfolge.
    ///
    /// Achtung: Manche Scanner (z. B. Brother MFC-L2710DN) legen mitten im Stapel eine Pause ein; der
    /// Treiber meldet den Auftrag dann ohne Fehler als beendet, und die danach eingezogenen Blätter
    /// kommen nie an. Ein erneuter Auftrag rettet sie nicht – sie müssen nachgescannt werden.
    /// - Parameter pagesBefore: bereits vorhandene Seiten dieses Durchgangs (nur für die Anzeige)
    func scanFeeder(dpi: Int, color: Bool, into folder: URL, pagesBefore: Int = 0) async throws -> [URL] {
        pageOffset = pagesBefore
        defer { pageOffset = 0 }
        return try await scan(source: .feeder, dpi: dpi, color: color, into: folder)
    }

    /// Scannt über die gewählte Quelle: beim Einzug alle eingelegten Blätter, beim Vorlagenglas eine A4-Seite.
    func scan(source: ScanSource, dpi: Int, color: Bool, into folder: URL) async throws -> [URL] {
        guard let scanner = selected else { throw ScannerError.noScanner }
        guard isReady else { throw ScannerError.notReady }
        guard continuation == nil, unitContinuation == nil else { throw ScannerError.busy }
        guard sources.contains(source) else {
            throw ScannerError.scanFailed(source == .feeder ? "Dieser Scanner hat keinen Vorlageneinzug."
                                                            : "Dieser Scanner hat kein Vorlagenglas.")
        }
        if scanner.selectedFunctionalUnit.type != source.unitType {
            statusText = "Wechsle zu \(source.label) …"
            try await selectUnit(source.unitType, on: scanner)
        }
        let unit = scanner.selectedFunctionalUnit

        let supported = Array(unit.supportedResolutions)
        unit.resolution = supported.min(by: { abs($0 - dpi) < abs($1 - dpi) }) ?? dpi
        unit.bitDepth = .depth8Bits
        unit.pixelDataType = color ? .RGB : .gray
        unit.measurementUnit = .centimeters
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.documentType = .typeA4
            unit.scanArea = NSRect(origin: .zero, size: feeder.documentSize)
        } else if let flatbed = unit as? ICScannerFunctionalUnitFlatbed {
            flatbed.documentType = .typeA4
            // A4 ab der Anlegeecke, höchstens so groß wie das Glas
            let a4 = flatbed.documentSize.width > 0 ? flatbed.documentSize : NSSize(width: 21.0, height: 29.7)
            let glass = unit.physicalSize
            unit.scanArea = NSRect(x: 0, y: 0, width: min(a4.width, glass.width), height: min(a4.height, glass.height))
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = folder
        scanner.documentName = "seite"
        scanner.documentUTI = UTType.png.identifier

        scannedURLs = []
        pagesInCurrentScan = pageOffset
        statusText = "Scanne …"
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            scanner.requestScan()
        }
    }

    /// Wählt Einzug oder Vorlagenglas und wartet auf die Bestätigung des Scanners (höchstens 20 s).
    private func selectUnit(_ type: ICScannerFunctionalUnitType, on scanner: ICScannerDevice) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            unitContinuation = cont
            requestedUnit = type
            scanner.requestSelect(type)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard let self, let pending = self.unitContinuation else { return }
                self.unitContinuation = nil
                self.statusText = "Bereit"
                pending.resume(throwing: ScannerError.scanFailed("Der Scanner hat nicht auf den Wechsel der Scanquelle reagiert."))
            }
        }
    }

    func cancelScan() {
        selected?.cancelScan()
    }

    private func finishScan(error: Error?) {
        guard let cont = continuation else { return }
        continuation = nil
        let urls = scannedURLs
        scannedURLs = []
        Self.log.notice("Scan beendet: \(urls.count) Seite(n)\(error.map { ", Fehler \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "", privacy: .public)")
        if let error, urls.isEmpty {
            statusText = "Scan fehlgeschlagen"
            let flatbed = selected?.selectedFunctionalUnit.type == .flatbed
            cont.resume(throwing: ScannerError.scanFailed(Self.describe(error, flatbed: flatbed)))
        } else {
            statusText = "Bereit"
            cont.resume(returning: urls)
        }
    }

    private static func describe(_ error: Error, flatbed: Bool) -> String {
        let code = (error as NSError).code
        return "Scan fehlgeschlagen (Code \(code)). " + (flatbed ? "Ist die Klappe geschlossen?" : "Liegt Papier im Einzug?")
    }
}

extension ScannerService: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        MainActor.assumeIsolated {
            guard let scanner = device as? ICScannerDevice else { return }
            scanners.append(scanner)
            if selected == nil { select(scanner) }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated {
            scanners.removeAll { $0 === device }
            if device === selected {
                selected = nil
                isReady = false
                sources = []
                statusText = "Scanner getrennt"
                if let pending = unitContinuation {
                    unitContinuation = nil
                    pending.resume(throwing: ScannerError.scanFailed("Scanner getrennt"))
                }
                finishScan(error: ScannerError.scanFailed("Scanner getrennt"))
                if let next = scanners.first { select(next) }
            }
        }
    }
}

extension ScannerService: ICScannerDeviceDelegate {
    nonisolated func didRemove(_ device: ICDevice) {}

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        MainActor.assumeIsolated {
            guard device === selected else { return }
            if let error { statusText = "Verbindung fehlgeschlagen: \(error.localizedDescription)" }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        MainActor.assumeIsolated {
            if device === selected { isReady = false }
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        MainActor.assumeIsolated {
            guard scanner === selected else { return }
            let available = Set(scanner.availableFunctionalUnitTypes.map(\.uintValue))
            sources = ScanSource.allCases.filter { available.contains($0.unitType.rawValue) }
            // Wechsel für einen Scan angefordert
            if let pending = unitContinuation {
                unitContinuation = nil
                if error == nil, functionalUnit.type == requestedUnit {
                    pending.resume()
                } else {
                    statusText = "Bereit"
                    pending.resume(throwing: ScannerError.scanFailed(
                        "Scanquelle ließ sich nicht wählen\(error.map { " (\($0.localizedDescription))" } ?? "")."))
                }
                return
            }
            // Nach dem Öffnen ist der Flachbettscanner aktiv; für Stapel wird der Einzug vorausgewählt.
            if functionalUnit.type != .documentFeeder, sources.contains(.feeder) {
                scanner.requestSelect(.documentFeeder)
            } else if error == nil {
                isReady = true
                statusText = sources.contains(.feeder) ? "Bereit" : "Bereit (nur Vorlagenglas)"
            }
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        MainActor.assumeIsolated {
            scannedURLs.append(url)
            pagesInCurrentScan = pageOffset + scannedURLs.count
            statusText = "Seite \(scannedURLs.count) gescannt …"
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        MainActor.assumeIsolated { finishScan(error: error) }
    }

    nonisolated func device(_ device: ICDevice, didEncounterError error: Error?) {
        MainActor.assumeIsolated {
            if let error { statusText = "Scannerfehler: \(error.localizedDescription)" }
        }
    }
}
