import ScanArchivCore
import SwiftUI

/// Miniaturen in der fertigen Reihenfolge; Seiten lassen sich drehen, verschieben oder entfernen.
struct PagePreviewView: View {
    @Bindable var session: ScanSession
    @AppStorage(SettingsKey.pageThumbHeight) private var thumbHeight = SettingsKey.defaultPageThumbHeight

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(session.pages.count) Seite(n)")
                    .font(.headline)
                Text("Klick dreht um 180°, Rechtsklick um 90°. Ziehen ändert die Reihenfolge.")
                    .foregroundStyle(.secondary)
                Spacer()
                PageSizeSlider(height: $thumbHeight)
                Button("Seite scannen", systemImage: "plus.viewfinder") { session.scanSinglePage() }
                    .help("Eine weitere Seite scannen und hinten anhängen")
                    .disabled(!session.scanner.isReady)
                Button("Verwerfen", role: .destructive) { session.reset() }
                Button("Speichern") { session.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.pages.isEmpty)
            }
            .padding(10)
            Divider()
            MetadataForm(session: session)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if let hint = session.orderHint {
                OrderHintBar(session: session, hint: hint)
                Divider()
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbHeight * 0.72), spacing: 16)], spacing: 16) {
                    ForEach(Array(session.pages.enumerated()), id: \.element.id) { index, page in
                        PageThumb(session: session, page: page, number: index + 1, height: thumbHeight)
                    }
                }
                .padding(16)
            }
        }
    }
}

/// Gelber Hinweis, wenn die gedruckten Seitenzahlen nicht zur Reihenfolge passen.
private struct OrderHintBar: View {
    let session: ScanSession
    let hint: ScanSession.OrderHint

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: DocumentIssue.Severity.warning.symbol)
                .foregroundStyle(DocumentIssue.Severity.warning.color)
            switch hint {
            case let .reorder(_, sequence):
                Text("Laut Seitenzahlen liegen die Seiten in der Reihenfolge \(sequence.map(String.init).joined(separator: ", ")) vor.")
                Spacer()
                Button("Ignorieren") { session.dismissOrderHint() }
                Button("Umsortieren") { withAnimation { session.applyOrderHint() } }
                    .buttonStyle(.borderedProminent)
            case let .uncertain(numbers):
                Text("Die Seitenzahlen passen nicht zur Reihenfolge (\(numbers.map { $0.map(String.init) ?? "?" }.joined(separator: ", "))) – bitte prüfen.")
                Spacer()
                Button("Ausblenden") { session.dismissOrderHint() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

/// Datum, Titel und Beschreibung – vorgeschlagen aus dem Text, frei bearbeitbar.
private struct MetadataForm: View {
    @Bindable var session: ScanSession

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Datum").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                HStack {
                    DatePicker("Datum", selection: $session.documentDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .fixedSize()
                    Text(dateHint).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    status
                }
            }
            GridRow {
                Text("Titel").foregroundStyle(.secondary)
                TextField("z. B. Stromrechnung Stadtwerke 2026", text: $session.title)
                    .font(.title3)
            }
            GridRow {
                Text("Beschreibung").foregroundStyle(.secondary)
                TextField("Kurzbeschreibung", text: $session.summary, axis: .vertical)
                    .lineLimit(2...4)
            }
            GridRow {
                Text("Kategorien").foregroundStyle(.secondary)
                CategoryEditor(categories: $session.categories, known: session.model.knownCategories)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private var dateHint: String {
        switch session.dateSource {
        case .document: return "aus dem Dokument"
        case .today: return "heute – kein Datum im Text gefunden"
        case .manual: return "manuell"
        }
    }

    @ViewBuilder
    private var status: some View {
        switch session.suggestionState {
        case .idle:
            EmptyView()
        case .recognizing:
            ProgressView().controlSize(.small)
            Text("Texterkennung …").foregroundStyle(.secondary)
        case .suggesting:
            ProgressView().controlSize(.small)
            Text("Vorschlag wird erstellt …").foregroundStyle(.secondary)
        case .done:
            Button("Neu vorschlagen", systemImage: "sparkles") { session.resuggest() }
        case let .unavailable(reason):
            Label(reason, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            Button("Erneut versuchen") { session.resuggest() }
        }
    }
}

private struct PageThumb: View {
    let session: ScanSession
    let page: ScannedPage
    let number: Int
    let height: Double
    @State private var dropTargeted = false

    private var label: String {
        switch page.kind {
        case .front: return "Seite \(number) · Vorderseite"
        case .back: return "Seite \(number) · Rückseite"
        case .single: return "Seite \(number)"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: page.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .background(Color.white)
                .shadow(radius: 2)
                .overlay(alignment: .topTrailing) {
                    if page.autoRotated {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(4)
                            .help("Automatisch aufrecht gedreht (\(page.rotation)°)")
                    }
                }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(dropTargeted ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { session.rotate(page, by: 180) }
        .contextMenu {
            Button("90° nach rechts drehen", systemImage: "rotate.right") { session.rotate(page, by: 90) }
            Button("90° nach links drehen", systemImage: "rotate.left") { session.rotate(page, by: -90) }
            Button("Um 180° drehen") { session.rotate(page, by: 180) }
            Divider()
            Button("Seite entfernen", role: .destructive) { session.remove(page) }
        }
        .draggable(page.id.uuidString) {
            Image(nsImage: page.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 120)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            withAnimation { session.move(pageID: dragged, to: page.id) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}
