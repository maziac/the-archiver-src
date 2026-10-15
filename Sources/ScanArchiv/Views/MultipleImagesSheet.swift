import ScanArchivCore
import SwiftUI

/// Beim Ablegen mehrerer Bilder: ein Dokument aus allen Bildern oder je Bild ein eigenes?
struct MultipleImagesSheet: View {
    let images: [URL]
    let onCombine: () -> Void
    let onSeparate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("\(images.count) Bilder abgelegt", systemImage: "photo.on.rectangle.angled")
                .font(.headline)
            Text("Sollen die Bilder zu einem Dokument verbunden werden – etwa mehrere Seiten oder Vorder- und Rückseite – oder wird jedes Bild ein eigenes Dokument?")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(images.prefix(8), id: \.self) { url in
                        Text(url.lastPathComponent).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if images.count > 8 {
                        Text("… und \(images.count - 8) weitere").font(.callout).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Reihenfolge nach Dateiname")
            }

            Text("Beim Verbinden entsteht ein PDF mit einer Seite je Bild. Texterkennung, Titel, Datum und Nummer vergibt The Archiver danach wie gewohnt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Einzeln speichern") {
                    onSeparate()
                    dismiss()
                }
                Button("Zu einem Dokument verbinden") {
                    onCombine()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
