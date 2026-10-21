import SwiftUI

/// Menü des Symbols in der macOS-Menüleiste
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(InboxService.self) private var inbox
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Scannen") { show(.scan) }
        Button(inboxTitle) { show(.inbox) }
        Button("Archiv") { show(.archive) }
        Divider()
        Button("Einstellungen …") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("ScanArchiv beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var inboxTitle: String {
        let count = inbox.waitingCount + inbox.processingCount + inbox.failedCount
        return count > 0 ? "Eingang (\(count))" : "Eingang"
    }

    /// Hauptfenster nach vorne holen (bzw. wieder öffnen) und den Reiter wählen
    private func show(_ tab: AppTab) {
        model.selectedTab = tab
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
