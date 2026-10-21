import ScanArchivCore
import SwiftUI

/// Schließen des Hauptfensters beendet die App nicht (sie bleibt im Dock bzw. in der Menüleiste)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct ScanArchivApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var session: ScanSession
    @State private var inbox: InboxService
    @AppStorage(SettingsKey.showInMenuBar) private var showInMenuBar = false

    /// Anzeigename aus dem Bundle („The Archiver“)
    static var displayName: String {
        Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "The Archiver"
    }

    /// Programmversion aus dem Bundle, z. B. „The Archiver 1.1 (Build 202609191030)“
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = (info?["CFBundleVersion"] as? String).map { " (Build \($0))" } ?? ""
        return "\(displayName) \(version)\(build)"
    }

    init() {
        // wird in jedes neu erstellte bzw. geänderte Dokument geschrieben
        DocumentMetadata.appName = Self.versionString
        let model = AppModel()
        let inbox = InboxService(model: model)
        _model = State(initialValue: model)
        _session = State(initialValue: ScanSession(scanner: ScannerService(), model: model))
        _inbox = State(initialValue: inbox)
        // Eingangsordner sofort beim Start einlesen und überwachen
        inbox.start()
    }

    var body: some Scene {
        Window(Self.displayName, id: "main") {
            @Bindable var model = model
            TabView(selection: $model.selectedTab) {
                ScanView(session: session)
                    .tabItem { Label("Scannen", systemImage: "scanner") }
                    .tag(AppTab.scan)
                InboxView()
                    .tabItem { Label("Eingang", systemImage: "tray.and.arrow.down") }
                    .badge(inbox.waitingCount + inbox.processingCount + inbox.failedCount)
                    .tag(AppTab.inbox)
                SearchView()
                    .tabItem { Label("Archiv", systemImage: "magnifyingglass") }
                    .tag(AppTab.archive)
            }
            .frame(minWidth: 900, minHeight: 600)
            // Dialoge hängen am Fenster, damit sie auch bei Ablage im Archiv oder beim Scannen erscheinen
            .sheet(isPresented: Binding(get: { !inbox.pendingFolders.isEmpty }, set: { if !$0 { inbox.pendingFolders = [] } })) {
                FolderImportSheet(folders: inbox.pendingFolders) { files in inbox.add(files: files) }
            }
            .sheet(isPresented: Binding(get: { !inbox.pendingImages.isEmpty }, set: { if !$0 { inbox.pendingImages = [] } })) {
                let images = inbox.pendingImages
                MultipleImagesSheet(images: images,
                                    onCombine: { inbox.addCombined(images: images) },
                                    onSeparate: { inbox.add(files: images) })
            }
            .environment(model)
            .environment(inbox)
        }
        Settings {
            SettingsView()
                .environment(model)
                .environment(inbox)
        }
        MenuBarExtra(Self.displayName, systemImage: "archivebox", isInserted: $showInMenuBar) {
            MenuBarContent()
                .environment(model)
                .environment(inbox)
        }
    }
}
