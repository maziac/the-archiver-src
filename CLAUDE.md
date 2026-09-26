# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

ScanArchiv ist eine deutschsprachige macOS-App (SwiftUI, macOS 14+) zum Scannen, Importieren und
Archivieren von Dokumenten. **Oberfläche, Kommentare, Commit-Nachrichten und Antworten an den Benutzer
sind deutsch.**

## Befehle

```bash
swift build                      # schnell prüfen
swift test                       # alle Tests (swift-testing)
swift test --filter TagTests     # ein Suite/Test (Name des Typs, @Test-Namen oder @Suite-Titel)
./build.sh                       # Release bauen → build/ScanArchiv.app (setzt CFBundleVersion = Zeitstempel)
open build/ScanArchiv.app        # starten (vorher: pkill -x ScanArchiv)
swift scripts/make_icon.swift    # App-Icon neu erzeugen
```

App mit eigenen Ordnern starten (für Tests von Hand):
`build/ScanArchiv.app/Contents/MacOS/ScanArchiv -archivePath /tmp/a -inboxPath /tmp/e`

Nach Code-Änderungen: `swift test`, dann `./build.sh` und die App neu starten — der Benutzer prüft die
Oberfläche selbst (Claude hat keinen Bildschirmzugriff). Apple Intelligence und Scanner sind in Tests
nicht verlässlich verfügbar; `SummarizerTests` schwankt gelegentlich (Modell wählt Zeitraum statt
Rechnungsdatum) und ist kein Regressionssignal.

## Architektur

Drei Targets (`Package.swift`): `ScanArchivCore` (gesamte Logik, testbar, ohne UI; linkt `sqlite3`, hat
FoundationModels **weak-linked**), `ScanArchiv` (SwiftUI-App, Scanner, Eingangsordner),
`ScanArchivCoreTests`. Ausführliche Diagramme: `docs/ARCHITEKTUR.md`. Eine vollständige Spezifikation
(für eine Neuimplementierung) steht in `docs/NEUIMPLEMENTIERUNG-PROMPT.md`.

### Unverhandelbare Prinzipien

- **Das PDF ist der Master.** Alle Angaben (`DocumentMetadata`) stehen als ASCII-JSON in einer versteckten
  Anmerkung `/ScanArchiv` auf Seite 1. PDFKit verwirft eigene Info-Schlüssel — deshalb die Anmerkung.
  Der SQLite-Index ist ein Cache und muss sich per `SearchIndex.sync(full: true)` vollständig aus den
  PDFs neu aufbauen lassen. Jede neue Metadaten-Information muss also im PDF landen.
- **Importierte PDFs bleiben bitgenau.** Ergänzungen (Stempel, OCR-Ebene, Metadaten, Umsortierung,
  Drehung) hängt `PDFAppender` als inkrementelles Update an; das Original bleibt Präfix der Datei.
  Beim Import konkurrieren drei Fassungen (`appended`, `rewritten` via PDFKit, `rebuilt` komprimiert);
  jede wird validiert (`ImportProcessor.validate`), die kleinste gültige gewinnt und steht als
  `DocumentMetadata.storage` im PDF.
- **Nummern werden nie wiederverwendet:** `max(counter.json, höchste Nummer im Ordner) + 1`.
- Schreiben immer atomar (temporäre Datei + `replaceItemAt`), Ergebnis vorher prüfen.

### Core-Module (Sources/ScanArchivCore)

- `Archive` – Nummern, Dateinamen (`JJJJ-MM-TT_NNNNNN_Titel.pdf`), `save`, `updateMetadata`,
  `rearrange` (Seiten umsortieren/drehen), Migration von Altbestand. Threadsicher per Lock.
- `ImportProcessor.process` – der zentrale Import-Ablauf: Duplikat (SHA-256) → Text/OCR je Seite →
  leere Seiten (`BlankPage`) → Seitenreihenfolge (`PageNumbering`) → Vorschlag (`Summarizer`) →
  Datum (Text → `FileDate` → heute) → Fassungen → Index.
- `PDFRaw` / `PDFAppender` – eigener PDF-Parser und -Writer (Querverweis-Tabellen und -Streams inkl.
  PNG-Prädiktor, Objekt-Streams, Seitenbaum). Kein Fremdcode, keine Abhängigkeiten.
- `PDFBuilder` (+ `ImageTools`), `PDFStamper`, `GlyphlessFont`, `PageCompressor` – PDF erzeugen,
  unsichtbare OCR-Textebene, Stempelgeometrie (`PDFBuilder.stampGeometry` ist **die** gemeinsame
  Quelle für alle Wege), Kompression.
- `SearchIndex` – SQLite FTS5 (+ `fts5vocab` für führende Platzhalter), Suche, Tag-Filter,
  Problemfilter, Duplikate, Neuaufbau.
- Kleinteile: `OCRService`, `Summarizer`, `DateExtractor`, `FileDate`, `PageNumbering`, `BlankPage`,
  `PageOrder`, `ImagesToPDF`, `FolderScan`, `TagQuery`/`TagStore`, `DocumentMetadata`/`PDFMetadata`,
  `DocumentIssue`, `DocumentInfo`.

### App-Schicht (Sources/ScanArchiv)

`AppModel` (@Observable, MainActor) hält Archiv, Index, Tags, Einstellungen (`SettingsKey`) und die
Dokument-Aktionen; ein `revision`-Zähler löst das Neuladen der Listen aus. `ScanSession` ist der
Zustandsautomat des Scans (Stapel zweiteilig oder Seite für Seite, Vorschau, OCR-Cache, Vorschläge).
`ScannerService` kapselt ImageCaptureCore, `InboxService` die Ordnerüberwachung und Warteschlange.
Views liegen in `Sources/ScanArchiv/Views`.

Einmalige Reparaturen/Nachprüfungen laufen in `AppModel.reindex` über versionierte
UserDefaults-Schlüssel (`legacyRepairV1`, `blankPagesV2:<Archivpfad>`); bei geänderter Heuristik den
Schlüssel hochzählen, damit Bestandsdokumente erneut geprüft werden.

## Fallstricke (teuer erkauft)

- **Vision muss auf einer eigenen seriellen DispatchQueue laufen** (`OCRService`). Parallel auf dem
  Cooperative Thread Pool erschöpft sich der Pool und alles hängt, auch in Tests.
- **Unsichtbaren OCR-Text nicht horizontal stauchen** — sonst extrahieren Reader „E U R O“. Stattdessen
  Schriftgröße verkleinern (`PDFBuilder.drawInvisibleText`).
- **PDFKit**: verwirft eigene Info-Keys, überschreibt `CreationDate`, bläht beim Neuschreiben auf
  (CCITT→Flate, Schriften je Seite). Metadaten nachträglich immer erst anhängen, PDFKit nur als Fallback.
- **Datumscodierung** in `DocumentMetadata` ist `.deferredToDate`; JSON ASCII-only, sonst brechen
  Roundtrip-Vergleiche (`PDFMetadata.read(pdf) == meta`).
- Swift-Regex-Literale können kein Lookbehind → `NSRegularExpression` (siehe `DateExtractor`).
- `Data.write` erlaubt nicht `.atomic` zusammen mit `.withoutOverwriting`.
- Verschachtelte `#require`/`#expect` in swift-testing können still fehlschlagen zu kompilieren; Tests
  flach halten.

## Git

Nur auf Bitten committen. **Nie `git add -A`**: `Anmerkungen.md` ist die Notizdatei des Benutzers und
wird von ihm selbst gepflegt. Stattdessen gezielt vormerken, z. B. `git add Sources Tests README.md docs`.
