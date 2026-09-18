import ImageCaptureCore
import ScanArchivCore
import SwiftUI
import UniformTypeIdentifiers

struct ScanView: View {
    @Bindable var session: ScanSession
    @Environment(AppModel.self) private var model

    @State private var dropTargeted = false

    private var scanner: ScannerService { session.scanner }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Dokumente importieren"
        panel.message = "PDFs oder Bilder auswählen. Jede Datei wird ein eigenes Dokument."
        panel.prompt = "Importieren"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ScanSession.importableTypes
        if panel.runModal() == .OK {
            session.importFiles(Self.sortedByName(panel.urls))
        }
    }

    private static func sortedByName(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            scannerBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Scannerauswahl

    private var scannerBar: some View {
        HStack {
            Image(systemName: "scanner")
            if scanner.scanners.isEmpty {
                Text("Kein Scanner gefunden")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Scanner", selection: Binding(
                    get: { scanner.selected.map(ObjectIdentifier.init) },
                    set: { id in
                        if let device = scanner.scanners.first(where: { ObjectIdentifier($0) == id }) { scanner.select(device) }
                    })
                ) {
                    ForEach(scanner.scanners, id: \.self) { device in
                        Text(device.name ?? "Scanner").tag(Optional(ObjectIdentifier(device)))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                .disabled(isBusy)
            }
            Circle()
                .fill(scanner.isReady ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(scanner.statusText)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Nächste Nummer: \(model.archive.map { Archive.formatNumber($0.peekNextNumber()) } ?? "–")")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .id(model.revision)
        }
        .padding(10)
    }

    private var isBusy: Bool {
        switch session.phase {
        case .scanningFronts, .scanningBacks, .processing: return true
        default: return false
        }
    }

    // MARK: Phasen

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .ready:
            Instruction(
                step: "Schritt 1 von 2",
                icon: "doc.on.doc",
                title: "Vorderseiten scannen",
                text: "Lege den Stapel mit den Vorderseiten nach oben in den Einzug, die erste Seite obenauf.\nOder übernimm vorhandene PDFs bzw. Bilder – per Dateiauswahl oder indem du sie hierher ziehst. Jede Datei wird ein eigenes Dokument.")
            {
                Button("Dateien importieren …") { chooseFiles() }
                Button("Vorderseiten scannen") { session.scanFronts() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!scanner.isReady)
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter { url in
                    ScanSession.importableTypes.contains { UTType(filenameExtension: url.pathExtension)?.conforms(to: $0) == true }
                }
                guard !files.isEmpty else { return false }
                session.importFiles(Self.sortedByName(files))
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                }
            }

        case .scanningFronts, .scanningBacks:
            VStack(spacing: 16) {
                ProgressView()
                Text(session.phase == .scanningFronts ? "Vorderseiten werden gescannt …" : "Rückseiten werden gescannt …")
                    .font(.title2)
                Text("\(scanner.pagesInCurrentScan) Seite(n)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Abbrechen") { session.cancelScan() }
            }

        case .awaitingFlip:
            Instruction(
                step: "Schritt 2 von 2",
                icon: "arrow.triangle.2.circlepath",
                title: "\(session.fronts.count) Vorderseite(n) gescannt – jetzt wenden",
                text: "Nimm den Stapel aus der Ablage, drehe ihn als Ganzes um (Reihenfolge nicht ändern!) und lege ihn wieder in den Einzug.")
            {
                Button("Nur einseitig – fertig") { session.finishSimplex() }
                Button("Rückseiten scannen") { session.scanBacks() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!scanner.isReady)
            }

        case let .countMismatch(fronts, backs):
            Instruction(
                step: "Achtung",
                icon: "exclamationmark.triangle",
                title: "Seitenzahl passt nicht",
                text: "Es wurden \(fronts) Vorderseite(n), aber \(backs) Rückseite(n) gescannt. Wurde ein Blatt doppelt eingezogen oder fehlt eines?")
            {
                Button("Abbrechen", role: .cancel) { session.reset() }
                Button("Trotzdem zusammenführen") { session.acceptMismatch() }
                Button("Rückseiten erneut scannen") { session.scanBacks() }
                    .keyboardShortcut(.defaultAction)
            }

        case .preview:
            PagePreviewView(session: session)

        case let .processing(message):
            VStack(spacing: 16) {
                ProgressView()
                if session.importTotal > 1 {
                    Text("Datei \(session.importPosition) von \(session.importTotal)\(session.autoSaveRemaining ? " – automatisch" : "")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(message).font(.title3)
                if session.autoSaveRemaining {
                    Button("Automatik stoppen") { session.stopAutoSave() }
                }
            }

        case let .saved(url):
            Instruction(
                step: "Fertig",
                icon: "checkmark.circle",
                title: "Gespeichert als \(url.lastPathComponent)",
                text: [session.lastSavedName, url.deletingLastPathComponent().path].compactMap { $0 }.joined(separator: "\n"))
            {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Öffnen") { NSWorkspace.shared.open(url) }
                Button("Neuer Scan") { session.reset() }
                    .keyboardShortcut(.defaultAction)
            }

        case let .failed(message):
            Instruction(step: "Fehler", icon: "xmark.octagon", title: "Das hat nicht geklappt", text: message) {
                if !session.pages.isEmpty {
                    Button("Zurück zur Vorschau") { session.backToPreview() }
                }
                if !session.importQueue.isEmpty {
                    Button("Nächste Datei") { session.skipFile() }
                }
                Button("Neu beginnen") { session.reset() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct Instruction<Actions: View>: View {
    let step: String
    let icon: String
    let title: String
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text(step.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
                .textSelection(.enabled)
            HStack { actions }
                .controlSize(.large)
                .padding(.top, 8)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}
