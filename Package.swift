// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Archiver",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    targets: [
        // Scanner-unabhängige Logik: Seitenreihenfolge, OCR, PDF, Archiv, Suchindex
        .target(name: "ArchiverCore", linkerSettings: [
            .linkedLibrary("sqlite3"),
            // Apple Intelligence nur, wenn vorhanden (macOS 26+); ältere Systeme starten trotzdem
            .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
        ]),
        // SwiftUI-App mit Scanner-Steuerung (ImageCaptureCore)
        .executableTarget(name: "Archiver", dependencies: ["ArchiverCore"]),
        .testTarget(name: "ArchiverCoreTests", dependencies: ["ArchiverCore"]),
    ],
    swiftLanguageModes: [.v5]
)
