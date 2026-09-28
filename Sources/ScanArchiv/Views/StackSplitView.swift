import ScanArchivCore
import SwiftUI

/// Vorschlag, wie ein Stapel in Dokumente aufgeteilt wird: je Dokument eine Zeile mit seinen Blättern.
/// Die Schere zwischen zwei Blättern trennt, „Zusammenführen“ hängt ein Dokument an das vorige.
struct StackSplitView: View {
    @Bindable var session: ScanSession

    private var documents: [[Int]] { session.stackDocuments }
    private var separatorNote: String {
        switch session.stackAnalysis?.separators.count ?? 0 {
        case 0: return ""
        case 1: return "Ein leeres Trennblatt wird entfernt. "
        case let n: return "\(n) leere Trennblätter werden entfernt. "
        }
    }

    var body: some View {
        let documents = documents
        VStack(spacing: 0) {
            HStack {
                Text("\(documents.count) Dokument(e) aus \(session.stackSheets.count) Blättern")
                    .font(.headline)
                Text(separatorNote + (session.removedShowThrough > 0 ? showThroughNote(session.removedShowThrough) + " " : "")
                     + "Schere trennt, „Zusammenführen“ verbindet. Orange = unsicher, bitte prüfen.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Verwerfen", role: .destructive) { session.reset() }
                Button("Nicht aufteilen") { session.skipSplit() }
                    .help("Alle Blätter als ein einziges Dokument speichern")
                Button("Weiter (\(documents.count) Dokument\(documents.count == 1 ? "" : "e"))") { session.confirmSplit() }
                    .keyboardShortcut(.defaultAction)
                    .help("Jedes Dokument wird danach wie gewohnt mit Titel und Datum gespeichert")
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(documents.enumerated()), id: \.element.first) { number, document in
                        DocumentRow(session: session, number: number + 1, sheets: document)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DocumentRow: View {
    let session: ScanSession
    let number: Int
    let sheets: [Int]

    private static let thumbHeight = 400.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(sheets.enumerated()), id: \.element) { position, sheet in
                        if position > 0 {
                            GapButton(session: session, sheet: sheet)
                        }
                        SheetCard(session: session, sheet: session.stackSheets[sheet], height: Self.thumbHeight)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Dokument \(number)")
                .font(.headline)
            Text(sheets.count == 1 ? "1 Blatt" : "\(sheets.count) Blätter")
                .foregroundStyle(.secondary)
            if let order = session.sheetOrder(sheets) {
                Label("wird laut Seitenzahlen umsortiert (Blatt \(order.map { String($0 + 1) }.joined(separator: ", ")))",
                      systemImage: "arrow.up.arrow.down")
                    .foregroundStyle(.secondary)
            }
            if let first = sheets.first, first > 0 {
                GapInfo(session: session, sheet: first)
            }
            Spacer()
            if let first = sheets.first, first > 0, session.stackAnalysis?.separators.contains(first - 1) == false, number > 1 {
                Button("Mit vorherigem zusammenführen", systemImage: "arrow.up.to.line") {
                    withAnimation { session.toggleSplit(beforeSheet: first) }
                }
            }
        }
    }
}

/// Begründung und Sicherheit der Entscheidung vor einem Blatt.
private struct GapInfo: View {
    let session: ScanSession
    let sheet: Int

    var body: some View {
        if let gap = session.stackAnalysis?.gaps[sheet - 1] {
            let changed = session.splits[sheet - 1] != gap.split
            if changed {
                Label("von Hand geändert", systemImage: "hand.point.up.left")
                    .foregroundStyle(.secondary)
            } else if gap.confidence == .uncertain {
                Label("unsicher: \(gap.reason)", systemImage: DocumentIssue.Severity.warning.symbol)
                    .foregroundStyle(.orange)
            } else {
                Text(gap.reason)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Schere zwischen zwei Blättern desselben Dokuments; orange, wenn die Zusammengehörigkeit unsicher ist.
private struct GapButton: View {
    let session: ScanSession
    let sheet: Int

    private var gap: DocumentSplitter.Gap? { session.stackAnalysis?.gaps[sheet - 1] }
    private var uncertain: Bool {
        guard let gap else { return false }
        return gap.confidence == .uncertain && session.splits[sheet - 1] == gap.split
    }

    var body: some View {
        Button {
            withAnimation { session.toggleSplit(beforeSheet: sheet) }
        } label: {
            Image(systemName: "scissors")
                .font(.title3)
                .foregroundStyle(uncertain ? Color.orange : Color.secondary)
                .frame(width: 36, height: 120)
                .background(RoundedRectangle(cornerRadius: 6).fill(uncertain ? Color.orange.opacity(0.15) : Color.clear))
        }
        .buttonStyle(.plain)
        .help("Hier trennen" + (gap.map { " – bisher: \($0.reason)" } ?? ""))
    }
}

/// Vorder- und Rückseite eines Blatts nebeneinander; leere Seiten blass.
private struct SheetCard: View {
    let session: ScanSession
    let sheet: ScanSession.StackSheet
    let height: Double

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 3) {
                thumb(sheet.front)
                if let back = sheet.back { thumb(back) }
            }
            Text("Blatt \(sheet.id + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func thumb(_ id: UUID) -> some View {
        if let page = session.pages.first(where: { $0.id == id }) {
            Image(nsImage: page.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .background(Color.white)
                .shadow(radius: 1)
                .opacity(session.isBlank(id) ? 0.35 : 1)
                .help(session.isBlank(id) ? "Leere Seite" : (page.kind == .back ? "Rückseite" : "Vorderseite"))
        }
    }
}
