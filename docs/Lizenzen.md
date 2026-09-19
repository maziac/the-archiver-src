**ScanArchiv verwendet keine externen Bibliotheken.** Es gibt keine Paketabhängigkeiten: `Package.swift` listet nur die eigenen Targets, und eine `Package.resolved` existiert nicht. Nichts wird beim Bauen heruntergeladen.

**Verwendet werden ausschließlich Apple-Systemframeworks**, die zu macOS bzw. Xcode gehören. Sie werden nicht mitgeliefert, sondern zur Laufzeit vom System bereitgestellt. Es gilt die **Apple-Software-Lizenz (macOS SLA) bzw. das Xcode-SDK-Agreement**; eine Weitergabepflicht für Lizenztexte entsteht dadurch nicht.

| Framework                       | Wofür                                       |
| ------------------------------- | ------------------------------------------- |
| Foundation, Observation         | Grundlagen, Datenmodell                     |
| SwiftUI, AppKit                 | Oberfläche, Drucken, Teilen                 |
| PDFKit                          | PDFs lesen, stempeln, anzeigen, drucken     |
| CoreGraphics, CoreText, ImageIO | PDFs erzeugen, Bilder, Schriftmaße          |
| Vision                          | Texterkennung und Ausrichtung               |
| FoundationModels                | Apple Intelligence (lokal), schwach gelinkt |
| ImageCaptureCore                | Scanner-Steuerung                           |
| UniformTypeIdentifiers          | Dateitypen                                  |
| CryptoKit                       | SHA-256 für die Duplikaterkennung           |
| Compression                     | Flate für die PDF-Streams                   |
| os                              | Protokollierung                             |

**Zwei Sonderfälle:**
- **SQLite3** (`import SQLite3`, `-lsqlite3`): Es wird die in macOS enthaltene Bibliothek benutzt. SQLite selbst ist **Public Domain**, die konkrete Bibliothek stammt aber von Apple und fällt unter deren Lizenz.
- **swift-testing** (`import Testing`): Teil der Swift-Toolchain und nur für Tests, nicht Teil der App. Es steht unter der **Apache-Lizenz 2.0 mit LLVM-Ausnahme**, wie Swift selbst. Auch die Swift-Standardbibliothek und -Laufzeit stehen unter dieser Lizenz; sie sind in macOS enthalten und werden nicht mitgebündelt.

**Folge für die Weitergabe:** Dein eigener Code ist frei von Fremdlizenzen. Möchtest du die App weitergeben, brauchst du keine Lizenztexte Dritter beizulegen. Die einzige Einschränkung ist ohnehin gegeben: Die App läuft nur auf macOS.

Eine **eigene Erwähnung wert** ist etwas anderes: Die Funktionen zum Lesen und Schreiben von PDFs (Querverweistabellen und -Streams, Objekt-Streams, inkrementelle Updates, die glyphlose Schrift für die Textebene) sind komplett selbst geschrieben, statt eine Bibliothek wie PDFBox oder qpdf zu verwenden. Das ist mehr Code, hält das Projekt aber abhängigkeitsfrei.