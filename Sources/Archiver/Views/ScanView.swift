import ImageCaptureCore
import ArchiverCore
import SwiftUI

struct ScanView: View {
    @Bindable var session: ScanSession
    @Environment(AppModel.self) private var model
    @Environment(InboxService.self) private var inbox

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
        case .checkingFeeder, .scanningFronts, .scanningBacks, .scanningSingle, .processing, .analyzingStack: return true
        default: return false
        }
    }

    // MARK: Phasen

    @ViewBuilder
    private var content: some View {
        switch session.phase {
        case .ready:
            Instruction(
                step: "Scannen",
                icon: "doc.on.doc",
                title: "Dokument scannen",
                text: "Blätter in den Einzug oder eine Seite auf das Vorlagenglas legen und „Scannen“ wählen.\nVorhandene PDFs oder Bilder einfach mit der Maus hierher oder in den Tab „Eingang“ ziehen.")
            {
                Button("Scannen") { session.startScan() }
                    .keyboardShortcut(.defaultAction)
                    .help(plannedScan)
                    .disabled(!canScan)
            } footer: {
                VStack(spacing: 12) {
                    Text(plannedScan)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    scanOptions
                    if session.scanMode != .flatbed { splitToggle }
                }
            }
            .importDrop(inbox) { model.selectedTab = .inbox }  // beim Scannen sieht man den Fortschritt sonst nicht

        case .checkingFeeder, .scanningFronts, .scanningBacks, .scanningSingle:
            VStack(spacing: 16) {
                ProgressView()
                Text(scanningTitle)
                    .font(.title2)
                if let route = session.scanRoute, session.phase != .checkingFeeder {
                    Text(route).foregroundStyle(.secondary)
                }
                Text("\(scanner.pagesInCurrentScan) Seite(n)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Abbrechen") { session.cancelScan() }
            }

        case .awaitingFlip:
            Instruction(
                step: session.expectBacks ? "Schritt 2 von 2" : "Stapel gescannt",
                icon: "arrow.triangle.2.circlepath",
                title: session.expectBacks
                    ? "\(session.fronts.count) Vorderseite(n) gescannt – jetzt wenden"
                    : session.stackDuplex
                        ? "\(session.stackSheetCount) Blatt beidseitig gescannt (\(session.fronts.count) Seiten)"
                        : "\(session.fronts.count) Seite(n) gescannt",
                text: (session.feederNote.map { "⚠︎ \($0)\n" } ?? "")
                    + (session.stackDuplex ? ""
                       : session.expectBacks
                       ? "Nimm den Stapel aus der Ablage, drehe ihn als Ganzes um (Reihenfolge nicht ändern!) und lege ihn wieder in den Einzug.\n"
                       : "Beidseitig bedruckt? Dann den Stapel als Ganzes umdrehen (Reihenfolge nicht ändern!), wieder einlegen und „Rückseiten scannen“ wählen.\n")
                    + "Stimmt die Zahl nicht, weil der Scanner vorzeitig aufgehört hat? Dann die übrigen Blätter (ohne die ersten \(session.stackSheetCount)) wieder einlegen und „Weitere Seiten“ wählen.")
            {
                Button("Weitere Seiten") { session.scanMorePages() }
                    .help("Die noch nicht gescannten Blätter erneut einlegen; sie werden hinten angehängt")
                    .disabled(!scanner.isReady)
                if session.stackDuplex {
                    Button("Fertig") { session.finishStackScan() }
                        .keyboardShortcut(.defaultAction)
                } else if session.expectBacks {
                    Button("Fertig") { session.finishStackScan() }
                    Button("Rückseiten scannen") { session.scanBacks() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!scanner.isReady)
                } else {
                    Button("Fertig") { session.finishStackScan() }
                        .keyboardShortcut(.defaultAction)
                    Button("Rückseiten scannen") { session.scanBacks() }
                        .disabled(!scanner.isReady)
                }
            } footer: {
                splitToggle
            }

        case let .countMismatch(fronts, backs):
            Instruction(
                step: "Achtung",
                icon: "exclamationmark.triangle",
                title: "Seitenzahl passt nicht",
                text: "Es wurden \(fronts) Vorderseite(n), aber \(backs) Rückseite(n) gescannt. Wurde ein Blatt doppelt eingezogen oder fehlt eines?"
                    + (backs < fronts && backs > 0
                       ? "\n\nHat der Scanner vorzeitig aufgehört? Dann den Stapel wieder so einlegen wie eben, aber ohne die ersten \(backs) Blätter, und „Fehlende Rückseiten scannen“ wählen."
                       : ""))
            {
                Button("Abbrechen", role: .cancel) { session.reset() }
                Button("Trotzdem zusammenführen") { session.acceptMismatch() }
                if backs < fronts, backs > 0 {
                    Button("Fehlende Rückseiten scannen") { session.scanMissingBacks() }
                        .help("Die Blätter ohne gescannte Rückseite erneut einlegen; sie werden an die bisherigen Rückseiten angehängt")
                        .keyboardShortcut(.defaultAction)
                    Button("Rückseiten erneut scannen") { session.scanBacks() }
                } else {
                    Button("Rückseiten erneut scannen") { session.scanBacks() }
                        .keyboardShortcut(.defaultAction)
                }
            }

        case .singleNext:
            Instruction(
                step: "Seite für Seite",
                icon: session.singleError == nil ? "doc.badge.plus" : "exclamationmark.triangle",
                title: session.singleError == nil
                    ? "Seite \(session.pages.count) gescannt – noch eine?"
                    : "Seite konnte nicht gescannt werden",
                text: session.singleError.map { "\($0)\nBisher \(session.pages.count) Seite(n)." }
                    ?? "Lege die nächste Seite auf (\(session.scanRoute ?? ScanSource.flatbed.label)) und scanne sie – oder beende das Dokument.")
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

        case let .analyzingStack(done, total):
            VStack(spacing: 16) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(maxWidth: 320)
                Text("Stapel wird aufgeteilt …")
                    .font(.title2)
                Text("Texterkennung Seite \(min(done + 1, total)) von \(total)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Abbrechen") { session.reset() }
            }

        case .splitReview:
            StackSplitView(session: session)

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
                title: session.savedURLs.count > 1
                    ? "\(session.savedURLs.count) Dokumente gespeichert"
                    : "Gespeichert als \(url.lastPathComponent)",
                text: ([url.deletingLastPathComponent().path]
                       + (session.savedURLs.count > 1 ? session.savedURLs.map(\.lastPathComponent) : [])
                       + session.savedIssues.map { "⚠︎ " + $0.message }).joined(separator: "\n"))
            {
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting(session.savedURLs.isEmpty ? [url] : session.savedURLs)
                }
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
        case .checkingFeeder: return "Einzug wird geprüft …"
        case .scanningFronts: return "Vorderseiten werden gescannt …"
        case .scanningBacks: return "Rückseiten werden gescannt …"
        default: return "Seite \(session.pages.count + 1) wird gescannt …"
        }
    }

    private var canScan: Bool {
        guard scanner.isReady, !scanner.sources.isEmpty else { return false }
        switch session.scanMode {
        case .auto: return true
        case .batch: return scanner.sources.contains(.feeder)
        case .flatbed: return scanner.sources.contains(.flatbed)
        }
    }

    /// Optionen neben dem Scan-Button
    private var scanOptions: some View {
        Grid(alignment: .leading, verticalSpacing: 8) {
            GridRow {
                Text("Modus:").gridColumnAlignment(.trailing)
                Picker("Modus", selection: $session.scanMode) {
                    ForEach(ScanMode.allCases) { Text($0.label).tag($0) }
                }
                .help("Automatisch: Papier im Einzug → Stapel, sonst eine Seite vom Vorlagenglas")
            }
            GridRow {
                Text("Duplex:")
                Picker("Duplex", selection: $session.duplexMode) {
                    ForEach(DuplexMode.allCases) { Text($0.label).tag($0) }
                }
                .help("Automatisch: beidseitig, wenn der Einzug es kann. Ein: ohne Duplex-Einzug den Stapel für die Rückseiten wenden. Aus: nur Vorderseiten.")
                .disabled(session.scanMode == .flatbed || !scanner.sources.contains(.feeder))
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    /// Was „Scannen“ mit den aktuellen Optionen tun wird
    private var plannedScan: String {
        let feeder: String
        if scanner.supportsDuplex, session.duplexMode != .off {
            feeder = "Einzug, beidseitig"
        } else {
            switch session.duplexMode {
            case .off: feeder = "Einzug, einseitig"
            case .on: feeder = "Einzug, danach Stapel wenden für die Rückseiten"
            case .auto: feeder = "Einzug, einseitig (Rückseiten nach dem Wenden möglich)"
            }
        }
        let hasFeeder = scanner.sources.contains(.feeder)
        let hasGlass = scanner.sources.contains(.flatbed)
        switch session.scanMode {
        case .batch:
            return hasFeeder ? feeder : "Dieser Scanner hat keinen Einzug."
        case .flatbed:
            return hasGlass ? "Seite für Seite über das Vorlagenglas" : "Dieser Scanner hat kein Vorlagenglas."
        case .auto:
            if !hasFeeder { return "Seite für Seite über Vorlagenglas" }
            if !hasGlass { return feeder }
            if scanner.feederLoaded == true { return "Papier im Einzug erkannt → \(feeder)" }
            return "Papier im Einzug → \(feeder); sonst Vorlagenglas"
        }
    }

    /// Stapel nach dem Scan in einzelne Dokumente aufteilen
    private var splitToggle: some View {
        Toggle("Mehrere Dokumente im Stapel aufteilen", isOn: $session.splitStack)
            .help("Nach dem Scan werden Trennstellen zwischen den Briefen vorgeschlagen (zum Prüfen). Ein beidseitig leeres Blatt zwischen zwei Briefen trennt sicher.")
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
