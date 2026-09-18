import SwiftUI

/// Miniaturen in der fertigen Reihenfolge; Seiten lassen sich drehen oder entfernen.
struct PagePreviewView: View {
    @Bindable var session: ScanSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(session.pages.count) Seite(n) in Originalreihenfolge")
                    .font(.headline)
                Text("Klick auf eine Seite dreht sie um 180°.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Verwerfen", role: .destructive) { session.reset() }
                Button("Speichern") { session.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.pages.isEmpty)
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    ForEach(Array(session.pages.enumerated()), id: \.element.id) { index, page in
                        PageThumb(page: page, number: index + 1)
                            .onTapGesture { session.toggleRotation(page) }
                            .contextMenu {
                                Button("Um 180° drehen") { session.toggleRotation(page) }
                                Button("Seite entfernen", role: .destructive) { session.remove(page) }
                            }
                    }
                }
                .padding(16)
            }
        }
    }
}

private struct PageThumb: View {
    let page: ScannedPage
    let number: Int

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: page.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .rotationEffect(.degrees(page.rotated180 ? 180 : 0))
                .frame(height: 200)
                .background(Color.white)
                .shadow(radius: 2)
                .animation(.easeInOut(duration: 0.2), value: page.rotated180)
            Text("Seite \(number) · \(page.isBack ? "Rückseite" : "Vorderseite")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
