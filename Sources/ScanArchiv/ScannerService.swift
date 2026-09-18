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

/// Steuert Netzwerk-/USB-Scanner über ImageCaptureCore und scannt über den Vorlageneinzug (ADF).
@Observable
@MainActor
final class ScannerService: NSObject {
    private(set) var scanners: [ICScannerDevice] = []
    private(set) var selected: ICScannerDevice?
    /// Session offen und Einzug ausgewählt
    private(set) var isReady = false
    private(set) var statusText = "Suche Scanner …" {
        didSet { ScannerService.log.info("\(self.statusText, privacy: .public)") }
    }
    private static let log = Logger(subsystem: "de.local.scanarchiv", category: "scanner")
    /// Seiten, die im laufenden Durchgang schon angekommen sind
    private(set) var pagesInCurrentScan = 0

    @ObservationIgnored private let browser = ICDeviceBrowser()
    @ObservationIgnored private var scannedURLs: [URL] = []
    @ObservationIgnored private var continuation: CheckedContinuation<[URL], Error>?

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
        statusText = "Verbinde mit \(scanner.name ?? "Scanner") …"
        scanner.delegate = self
        scanner.requestOpenSession()
    }

    /// Scannt alle Blätter im Einzug und liefert die Seitenbilder (PNG) in Scan-Reihenfolge.
    func scanFeeder(dpi: Int, color: Bool, into folder: URL) async throws -> [URL] {
        guard let scanner = selected else { throw ScannerError.noScanner }
        guard isReady, let unit = scanner.selectedFunctionalUnit as? ICScannerFunctionalUnitDocumentFeeder else {
            throw ScannerError.notReady
        }
        guard continuation == nil else { throw ScannerError.busy }

        let supported = Array(unit.supportedResolutions)
        unit.resolution = supported.min(by: { abs($0 - dpi) < abs($1 - dpi) }) ?? dpi
        unit.bitDepth = .depth8Bits
        unit.pixelDataType = color ? .RGB : .gray
        unit.measurementUnit = .centimeters
        unit.documentType = .typeA4
        unit.scanArea = NSRect(origin: .zero, size: unit.documentSize)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = folder
        scanner.documentName = "seite"
        scanner.documentUTI = UTType.png.identifier

        scannedURLs = []
        pagesInCurrentScan = 0
        statusText = "Scanne …"
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            scanner.requestScan()
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
        if let error, urls.isEmpty {
            statusText = "Scan fehlgeschlagen"
            cont.resume(throwing: ScannerError.scanFailed(Self.describe(error)))
        } else {
            statusText = "Bereit"
            cont.resume(returning: urls)
        }
    }

    private static func describe(_ error: Error) -> String {
        let code = (error as NSError).code
        return "Scan fehlgeschlagen (Code \(code)). Liegt Papier im Einzug?"
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
                statusText = "Scanner getrennt"
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
            // Nach dem Öffnen ist der Flachbettscanner aktiv; erst dann lässt sich der Einzug wählen.
            if functionalUnit.type == .documentFeeder, error == nil {
                isReady = true
                statusText = "Bereit"
            } else if scanner.availableFunctionalUnitTypes.contains(NSNumber(value: ICScannerFunctionalUnitType.documentFeeder.rawValue)) {
                scanner.requestSelect(.documentFeeder)
            } else if error == nil {
                statusText = "Dieser Scanner hat keinen Vorlageneinzug."
            }
        }
    }

    nonisolated func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        MainActor.assumeIsolated {
            scannedURLs.append(url)
            pagesInCurrentScan = scannedURLs.count
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
