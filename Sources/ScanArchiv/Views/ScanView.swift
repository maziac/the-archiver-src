import ImageCaptureCore
import ScanArchivCore
import SwiftUI

struct ScanView: View {
    @Bindable var session: ScanSession
    @Environment(AppModel.self) private var model
    @Environment(InboxService.self) private var inbox

    @State private var dropTargeted = false

    private var scanner: ScannerService { session.scanner }


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
        case .scanningFronts, .scanningBacks, .scanningSingle, .processing: return true
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
                text: "Lege den Stapel mit den Vorderseiten nach oben in den Einzug, die erste Seite obenauf.\nOder scanne Seite für Seite – etwa für gebundene, empfindliche oder sehr unterschiedliche Blätter.\nVorhandene PDFs oder Bilder kannst du einfach hierher oder in den Tab „Eingang“ ziehen – sie werden automatisch verarbeitet.")
            {
                Button("Seite für Seite …") { session.scanSinglePage() }
                    .help("Jede Seite einzeln scannen; nach jeder Seite wird gefragt, ob noch eine kommt")
                    .disabled(!scanner.isReady || scanner.sources.isEmpty)
                Button("Vorderseiten scannen") { session.scanFronts() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!scanner.isReady || !scanner.sources.contains(.feeder))
            } footer: {
                sourcePicker
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                inbox.accept(urls)  // läuft automatisch über den Eingang (Ordner mit Auswahldialog)
                model.selectedTab = .inbox
                return true
            } isTargeted: { dropTargeted = $0 }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                }
            }

        case .scanningFronts, .scanningBacks, .scanningSingle:
            VStack(spacing: 16) {
                ProgressView()
                Text(scanningTitle)
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

        case .singleNext:
            Instruction(
                step: "Seite für Seite",
                icon: session.singleError == nil ? "doc.badge.plus" : "exclamationmark.triangle",
                title: session.singleError == nil
                    ? "Seite \(session.pages.count) gescannt – noch eine?"
                    : "Seite konnte nicht gescannt werden",
                text: session.singleError.map { "\($0)\nBisher \(session.pages.count) Seite(n)." }
                    ?? "Lege die nächste Seite auf (\(session.singleSource.label)) und scanne sie – oder beende das Dokument.")
            {
                Button(session.pages.isEmpty ? "Abbrechen" : "Alles verwerfen", role: .destructive) { session.reset() }
                if session.singleError == nil, !session.pages.isEmpty {
                    Button("Letzte Seite wiederholen") { session.rescanLastPage() }
                }
                Button("Fertig") { session.finishSingle() }
                    .disabled(session.pages.isEmpty)
                Button("Nächste Seite scannen") { session.scanSinglePage() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!scanner.isReady)
            } footer: {
                VStack(spacing: 12) {
                    sourcePicker
                    if let last = session.pages.last {
                        Image(nsImage: last.thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 160)
                            .background(Color.white)
                            .shadow(radius: 2)
                            .help("Zuletzt gescannte Seite")
                    }
                }
            }

        case .preview:
            PagePreviewView(session: session)

        case let .processing(message):
            VStack(spacing: 16) {
                ProgressView()
                Text(message).font(.title3)
            }

        case let .saved(url):
            Instruction(
                step: "Fertig",
                icon: "checkmark.circle",
                title: "Gespeichert als \(url.lastPathComponent)",
                text: ([url.deletingLastPathComponent().path]
                       + session.savedIssues.map { "⚠︎ " + $0.message }).joined(separator: "\n"))
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
                Button("Neu beginnen") { session.reset() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var scanningTitle: String {
        switch session.phase {
        case .scanningFronts: return "Vorderseiten werden gescannt …"
        case .scanningBacks: return "Rückseiten werden gescannt …"
        default: return "Seite \(session.pages.count + 1) wird gescannt …"
        }
    }

    /// Quelle für „Seite für Seite“ – nur wenn der Scanner Einzug und Vorlagenglas hat.
    @ViewBuilder
    private var sourcePicker: some View {
        if scanner.sources.count > 1 {
            Picker("Seite für Seite über", selection: $session.singleSource) {
                ForEach(scanner.sources) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }
}

private struct Instruction<Actions: View, Footer: View>: View {
    let step: String
    let icon: String
    let title: String
    let text: String
    @ViewBuilder let actions: Actions
    @ViewBuilder var footer: Footer

    init(step: String, icon: String, title: String, text: String,
         @ViewBuilder actions: () -> Actions, @ViewBuilder footer: () -> Footer = { EmptyView() }) {
        self.step = step
        self.icon = icon
        self.title = title
        self.text = text
        self.actions = actions()
        self.footer = footer()
    }

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
            footer
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}
