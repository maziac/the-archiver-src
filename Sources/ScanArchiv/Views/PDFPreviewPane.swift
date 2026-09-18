import Observation
import PDFKit
import SwiftUI

/// Vorschau eines Archiv-PDFs mit Suche: alle Treffer markiert, aktueller Treffer hervorgehoben,
/// Trefferliste mit Kontext zum schnellen Springen.
@Observable
@MainActor
final class PDFPreviewModel {
    struct Hit: Identifiable {
        let id: Int
        let selection: PDFSelection
        let pageNumber: Int
        let context: AttributedString
    }

    private(set) var url: URL?
    private(set) var document: PDFDocument?
    var query = "" { didSet { if query != oldValue { search() } } }
    private(set) var hits: [Hit] = []
    var currentHit: Int? { didSet { if currentHit != oldValue { navigationToken += 1 } } }
    /// ändert sich bei jedem Sprung, damit die PDF-Ansicht auch zum selben Treffer erneut scrollt
    private(set) var navigationToken = 0

    func show(url: URL?, query: String) {
        if url != self.url {
            self.url = url
            document = url.flatMap { PDFDocument(url: $0) }
            let queryChanged = query != self.query
            self.query = query  // löst bei Änderung die Suche aus
            if !queryChanged { search() }
        } else if query != self.query {
            self.query = query
        }
    }

    /// Findet alle Suchwörter (wie im Archiv: Umlaute/Groß-Klein egal, Wortanfänge genügen).
    private func search() {
        hits = []
        currentHit = nil
        guard let document else { return }
        let tokens = Set(query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        guard !tokens.isEmpty else { return }

        var found: [(page: Int, y: CGFloat, x: CGFloat, selection: PDFSelection)] = []
        for token in tokens {
            for selection in document.findString(token, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
                guard let page = selection.pages.first else { continue }
                let bounds = selection.bounds(for: page)
                found.append((document.index(for: page), bounds.maxY, bounds.minX, selection))
            }
        }
        // Lesereihenfolge: Seite, dann von oben nach unten, links nach rechts
        found.sort { ($0.page, -$0.y, $0.x) < ($1.page, -$1.y, $1.x) }

        hits = found.enumerated().map { i, hit in
            hit.selection.color = NSColor.systemYellow.withAlphaComponent(0.6)
            return Hit(id: i, selection: hit.selection, pageNumber: hit.page + 1, context: Self.context(for: hit.selection))
        }
        currentHit = hits.isEmpty ? nil : 0
    }

    func next() {
        guard !hits.isEmpty else { return }
        currentHit = ((currentHit ?? -1) + 1) % hits.count
    }

    func previous() {
        guard !hits.isEmpty else { return }
        currentHit = ((currentHit ?? 0) - 1 + hits.count) % hits.count
    }

    /// Text rund um den Treffer, Treffer fett.
    private static func context(for selection: PDFSelection) -> AttributedString {
        let match = selection.string ?? ""
        guard let wide = selection.copy() as? PDFSelection else { return AttributedString(match) }
        wide.extend(atStart: 40)
        wide.extend(atEnd: 40)
        let text = (wide.string ?? match).replacingOccurrences(of: "\n", with: " ")
        var result = AttributedString("…" + text + "…")
        if let range = result.range(of: match, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].font = .body.bold()
            result[range].foregroundColor = .primary
        }
        return result
    }
}

struct PDFPreviewPane: View {
    @Bindable var preview: PDFPreviewModel
    @FocusState private var searchFocused: Bool

    // Der Aufbau bleibt immer gleich (auch ohne Dokument), sonst berechnet die umgebende
    // Split-Ansicht beim ersten Anzeigen eines PDFs die Spaltenbreiten neu.
    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .disabled(preview.document == nil)
            Divider()
            VSplitView {
                PDFKitView(preview: preview)
                    .frame(minHeight: 200)
                hitList
                    .frame(minHeight: 60, idealHeight: 150, maxHeight: 300)
            }
        }
        .overlay {
            if preview.document == nil {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(preview.url == nil ? "Dokument in der Liste auswählen" : "PDF kann nicht geöffnet werden")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Im Dokument suchen", text: $preview.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { preview.next() }
            if !preview.query.isEmpty {
                Text(preview.hits.isEmpty ? "keine Treffer" : "\((preview.currentHit ?? 0) + 1) / \(preview.hits.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button { preview.previous() } label: { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Vorheriger Treffer (⇧⌘G)")
                .disabled(preview.hits.isEmpty)
            Button { preview.next() } label: { Image(systemName: "chevron.down") }
                .keyboardShortcut("g", modifiers: .command)
                .help("Nächster Treffer (⌘G oder ⏎)")
                .disabled(preview.hits.isEmpty)
            if let url = preview.url {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("In Vorschau.app öffnen")
            }
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    private var hitList: some View {
        ScrollViewReader { proxy in
            List(preview.hits, selection: $preview.currentHit) { hit in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("S. \(hit.pageNumber)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    Text(hit.context)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .tag(hit.id)
                .id(hit.id)
            }
            .listStyle(.plain)
            .overlay {
                if preview.hits.isEmpty {
                    Text(preview.query.isEmpty ? "Suchbegriff eingeben, um Fundstellen aufzulisten" : "Keine Fundstellen")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .onChange(of: preview.currentHit) { _, current in
                if let current { withAnimation { proxy.scrollTo(current) } }
            }
        }
    }
}

/// PDFKit-Ansicht: markiert alle Treffer gelb und springt zum aktuellen.
private struct PDFKitView: NSViewRepresentable {
    let preview: PDFPreviewModel

    final class Coordinator {
        var shownToken = -1
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== preview.document {
            view.document = preview.document
            context.coordinator.shownToken = -1
            view.autoScales = true
        }
        let hits = preview.hits
        view.highlightedSelections = hits.isEmpty ? nil : hits.map(\.selection)

        guard context.coordinator.shownToken != preview.navigationToken else { return }
        context.coordinator.shownToken = preview.navigationToken
        if let index = preview.currentHit, hits.indices.contains(index) {
            let selection = hits[index].selection
            view.setCurrentSelection(selection, animate: true)
            view.go(to: selection)
        } else {
            view.clearSelection()
        }
    }
}
