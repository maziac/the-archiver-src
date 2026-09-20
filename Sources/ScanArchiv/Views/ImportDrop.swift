import ScanArchivCore
import SwiftUI

/// Dateien, Ordner oder Bilder auf eine beliebige Ansicht ziehen: Alles geht über den Eingang
/// (`InboxService.accept`), egal in welchem Tab man gerade ist.
struct ImportDrop: ViewModifier {
    let inbox: InboxService
    /// zusätzlich nach dem Ablegen, z. B. zum Tab wechseln
    var afterDrop: () -> Void = {}
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                inbox.accept(urls)  // Dateien sofort, Ordner und mehrere Bilder über die Dialoge
                afterDrop()
                return true
            } isTargeted: { targeted = $0 }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func importDrop(_ inbox: InboxService, afterDrop: @escaping () -> Void = {}) -> some View {
        modifier(ImportDrop(inbox: inbox, afterDrop: afterDrop))
    }
}
