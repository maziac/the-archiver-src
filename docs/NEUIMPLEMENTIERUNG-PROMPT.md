# Prompt: ScanArchiv von Grund auf neu implementieren

> Diesen Text vollständig als Auftrag an einen Coding-Assistenten geben. Er beschreibt Ziel, Funktionen,
> Datenformate, Architektur, bekannte Fallstricke und Abnahmekriterien. Ergänzend kann
> `docs/ARCHITEKTUR.md` (Mermaid-Diagramme) mitgegeben werden.

---

## Auftrag

Entwickle **ScanArchiv**, eine native macOS-App (Swift 6-Toolchain, Sprachmodus Swift 5, SwiftUI, macOS 14+),
die Papierdokumente mit einem Netzwerk-Scanner digitalisiert, vorhandene PDFs und Bilder importiert und
alles in einem durchsuchbaren, fortlaufend nummerierten PDF-Archiv ablegt. Die Oberfläche und alle Texte
sind **deutsch**. Der Benutzer ist technisch versiert, möchte aber eine App, die ohne Nachdenken
funktioniert.

Arbeite in Etappen (siehe „Umsetzungsreihenfolge“), schreibe zu jeder Etappe Tests und halte die Tests
grün. Frage nach, wenn eine Anforderung unklar ist, statt zu raten.

---

## 1. Projektaufbau

- **SwiftPM-Paket** mit drei Targets:
  - `ScanArchivCore` – Bibliothek ohne UI (die gesamte Logik), verlinkt `sqlite3`, **FoundationModels
    schwach gelinkt** (`-Xlinker -weak_framework -Xlinker FoundationModels`), damit die App auch ohne
    Apple Intelligence startet.
  - `ScanArchiv` – ausführbares SwiftUI-Target (Oberfläche, Scanner, Eingangsordner).
  - `ScanArchivCoreTests` – Tests mit **swift-testing** (`import Testing`).
- `build.sh`: `swift build -c release`, App-Bundle `build/ScanArchiv.app` zusammensetzen (Info.plist aus
  `Resources/`, Icon), `CFBundleVersion` = Zeitstempel `yyyyMMddHHmm`, ad-hoc signieren.
- Info.plist braucht u. a. die Scanner-/Netzwerk-Nutzungsbeschreibungen (ImageCaptureCore, Bonjour).
- Die App-Version (`ScanArchiv 1.1 (Build …)`) wird beim Start aus dem Bundle gelesen und in jedes
  Dokument geschrieben.
- Für End-to-End-Tests akzeptiert die App die Startargumente `-archivePath <Pfad>` und
  `-inboxPath <Pfad>` (überschreiben die Einstellungen).

---

## 2. Grundprinzipien (nicht verhandelbar)

1. **Das PDF ist der Master.** Alle Angaben zu einem Dokument stehen im PDF selbst. Der Suchindex ist ein
   reiner Cache und muss sich jederzeit vollständig aus den PDFs neu aufbauen lassen.
2. **Eindeutige, fortlaufende Nummern, nie wiederverwendet.** Nächste Nummer = max(`counter.json`,
   höchste Nummer eines PDFs im Archivordner) + 1. Auch gelöschte Nummern werden nicht neu vergeben.
3. **Importierte PDFs bleiben inhaltlich unverändert.** Ergänzungen (Stempel, OCR-Textebene, Metadaten,
   spätere Änderungen) werden per **inkrementellem PDF-Update** angehängt – das Original bleibt als
   bitgenaues Präfix der Datei erhalten. Nur wenn eine andere Fassung nachweislich kleiner und gültig ist,
   darf sie gewinnen.
4. **Nichts geht verloren:** Jede erzeugte Datei wird vor dem Ersetzen geprüft (Seitenzahl, Text,
   Stempel, Metadaten). Schreiben immer atomar (temporäre Datei im selben Ordner + `replaceItemAt`).
5. **Alles lokal.** OCR mit Vision, Zusammenfassung mit Apple Intelligence auf dem Gerät; kein Netzwerk
   außer zum Scanner.

---

## 3. Dateien und Formate

### 3.1 Archivordner (Standard `~/Documents/ScanArchiv`)
- Dateiname: `JJJJ-MM-TT_NNNNNN_Titel.pdf` (Dokumentdatum, 6-stellige Nummer, Titel als „Slug“:
  Umlaute erhalten, unzulässige Zeichen entfernt, Länge begrenzt; ohne Titel `JJJJ-MM-TT_NNNNNN.pdf`).
- `counter.json` – letzte vergebene Nummer.
- `.scanarchiv-index.sqlite` – Suchindex (Cache).
- `.scanarchiv-tags.json` – gespeicherte Suchen (Tags), gehören zum Archiv.

### 3.2 Eingangsordner (Standard `~/Documents/ScanArchiv-Eingang`)
- Unterordner `Fehler/` (nicht verarbeitbar) und `Duplikate/` (gleiche SHA-256 wie ein archiviertes
  Original).

### 3.3 Inhalt jedes Archiv-PDFs
- **Roter Stempel** oben rechts auf Seite 1: `Nr. 000123 · TT.MM.JJJJ` (Helvetica-Bold 9 pt, Rot
  0.85/0.05/0.05, weißer Kasten mit rotem Rahmen, 14 pt Rand, 3 pt Innenabstand). Die Geometrie ist in
  einer einzigen Funktion `stampGeometry(text, pageSize)` definiert und wird von allen Erzeugungswegen
  benutzt (wichtig für das spätere Verschieben des Stempels).
- **Unsichtbare OCR-Textebene** auf Bildseiten (Textmodus 3), so dass Kopieren und Suchen in jedem
  PDF-Betrachter funktionieren.
- **Dokumentinfos:** Titel (oder Dateiname ohne Endung), Betreff = Beschreibung, Stichwörter
  `000123, Nr. 000123`, Creator = App-Version, Erstelldatum = Archivierungszeit.
- **Metadaten** als JSON in einer **versteckten Anmerkung** auf Seite 1 (Subtype Text, Rect 0 0 0 0,
  Flags hidden + readonly, eigener Schlüssel `/ScanArchiv`). Grund: PDFKit verwirft eigene Info-Schlüssel
  beim Speichern. JSON **ASCII-only** (`\uXXXX`-Escapes), Datumswerte im Codable-Standardformat
  (`.deferredToDate`), damit sie verlustfrei hin und zurück kommen.

### 3.4 `DocumentMetadata` (Codable)
`number`, `documentDate`, `dateSource` (text, ai, fileName, pdfCreation, fileDate, today, manual,
unknown), `titleSource` (ai, manual, none), `titleUpdated`, `archivedAt`, `source` (scan, pdf, image),
`originalFileName`, `originalSize`, `originalSHA256`, `scan` (Scanner, dpi, Farbmodus), `compression`
(Stufe, Farbmodus, angewendet ja/nein, Größen), `pages: [TextSource]` (embedded, ocr, none, blank,
unknown), `ocr` (Engine, Sprachen, Datum), `issues: [DocumentIssue]`, `app` (Erstellversion),
`updatedWith` (letzte Änderung), `storage` (appended, rewritten, rebuilt, created), `pageOrder: [Int]?`
(beim Import umsortiert: Originalindizes in neuer Reihenfolge).

### 3.5 `DocumentIssue` (Codable, mit Schweregrad)
| Fall | Meldung | Schwere |
|---|---|---|
| `noText(pages)` | „Seite(n) x: kein Text erkannt“ | Fehler (rot) |
| `noSuggestion(reason)` | „kein Titel/keine Beschreibung – Grund“ | Fehler; Hinweis (gelb), wenn Grund „deaktiviert“ |
| `noDate` | „kein Datum gefunden (Tagesdatum verwendet)“ | Fehler |
| `pageOrderCorrected(original)` | „Seitenreihenfolge laut Seitenzahlen korrigiert (vorher 1, 3, 2) – bitte prüfen“ | Hinweis |
| `pageOrderUncertain(numbers)` | „Seitenreihenfolge prüfen – Seitenzahlen: 1, 3, ?, 2“ | Hinweis |

Gelb wird als Orange dargestellt (reines Gelb ist auf Weiß kaum lesbar). Die Farbe einer Zeile richtet
sich nach dem schwersten Problem.

---

## 4. Funktionen

### 4.1 Scanner
- Gerät: Brother MFC-L2710DN im LAN (Einzug nur einseitig, zusätzlich Vorlagenglas). Allgemein jeder
  ImageCaptureCore-Scanner.
- `ICDeviceBrowser` (lokal, Bonjour, geteilt), erster Scanner wird automatisch gewählt, Auswahl im UI.
- Nach dem Öffnen der Sitzung ist das Flachbett aktiv; **erst dann** den Einzug wählen
  (`requestSelect(.documentFeeder)`) und auf `didSelect` warten. Wechsel Einzug ↔ Vorlagenglas vor jedem
  Scan bei Bedarf, mit Zeitlimit (20 s).
- Dateibasierte Übertragung als PNG in einen Arbeitsordner, Auflösung (200/300/600 dpi, nächstliegende
  unterstützte), 8 Bit, Farbe oder Grau, A4 (Glas: A4 ab Anlegeecke, höchstens Glasgröße).
- Statusanzeige (Bereit, Scanne …, Seite n gescannt …), Abbrechen.

### 4.2 Scannen – zwei Wege
**Stapel (Standardknopf „Stapel scannen“, Überschrift „Dokument scannen“):**
1. Vorderseiten über den Einzug scannen.
2. Anweisung: Stapel als Ganzes wenden (Reihenfolge nicht ändern). „Nur einseitig – fertig“ oder
   „Rückseiten scannen“.
3. Rückseiten kommen in umgekehrter Reihenfolge; verzahnen: V1 R1 V2 R2 … Bei ungleicher Anzahl:
   „Trotzdem zusammenführen“, „Rückseiten erneut scannen“, „Abbrechen“.
4. Einstellung „Rückseiten automatisch um 180° drehen“ (für Wenden über die kurze Kante).

**Seite für Seite („Seite für Seite …“):** Quelle Vorlagenglas oder Einzug (gemerkt). Nach jeder Seite:
„Seite n gescannt – noch eine?“ mit Miniatur der letzten Seite und „Nächste Seite scannen“ (Return),
„Letzte Seite wiederholen“, „Fertig“, „Alles verwerfen“. Fehler verlieren die bisherigen Seiten nicht.

Auf der Startseite kann man außerdem Dateien ablegen; sie gehen in den Eingang (4.5).

### 4.3 Scan-Vorschau
- Miniaturen in Seitenreihenfolge, **Größenregler** (200–1200 pt, Standard 560, gemerkt, scharf genug,
  dass Seitenzahlen lesbar sind).
- Klick dreht um 180°, Kontextmenü 90° rechts/links, 180°, Seite entfernen. **Ziehen** ändert die
  Reihenfolge (Ablageziel hervorgehoben). „Seite scannen“ hängt eine Seite an.
- **Automatische Ausrichtung** (Einstellung, Standard an): je Seite schnelle OCR in 0/90/180/270°,
  Bewertung nach Plausibilität der Wörter (Anteil wohlgeformter Wörter + häufige de/en-Wörter –
  kopfstehender Text ergibt Buchstabensalat); nur bei klarem Sieger (≥ 3× Zweitbester, Mindestpunktzahl)
  drehen. Symbol ↻ an automatisch gedrehten Seiten. Manuell gedrehte Seiten nicht mehr anfassen.
- **Hintergrundanalyse:** OCR der ersten zwei Seiten zuerst → Datum (DateExtractor) und Vorschlag
  (Apple Intelligence); danach die restlichen Seiten. OCR-Ergebnisse werden je Seite und Drehung gecacht.
  Gleicher Text wie beim letzten Vorschlag → nicht erneut fragen.
- Formular: Datum (mit Herkunft „aus dem Dokument“ / „heute – kein Datum gefunden“ / „manuell“), Titel,
  Beschreibung, Status (Texterkennung …, Vorschlag wird erstellt …, „Neu vorschlagen“, Fehlergrund).
  Eigene Eingaben werden nicht überschrieben.
- **Reihenfolge-Hinweis:** Sind alle Seiten erkannt, prüft `PageNumbering` die Reihenfolge; gelbe Leiste
  „Laut Seitenzahlen liegen die Seiten in der Reihenfolge 1, 3, 2 vor.“ mit „Umsortieren“ / „Ignorieren“
  (bzw. nur Hinweis, wenn unklar). Klickt der Benutzer vorher „Speichern“, wird erst fertig erkannt; ist
  die Reihenfolge verdächtig und der Hinweis neu, zurück zur Vorschau. **Bei Scans nie einen
  Reihenfolge-Vermerk speichern** – der Benutzer hat entschieden.
- **Speichern:** Ausrichtung/OCR aller Seiten sicherstellen, je Seite ohne Text leere Seite erkennen
  (`blank`, kein Problem) oder `none` + Problem, komprimieren (Einstellungen), PDF bauen, Metadaten
  (Speicherart `created`), Index. Danach „Gespeichert als …“ mit „Im Finder zeigen“, „Öffnen“,
  „Neuer Scan“ und etwaigen Problemen.

### 4.4 Texterkennung (Vision)
- `VNRecognizeTextRequest`, Stufe `.accurate`, Sprachen `de-DE`, `en-US`, Sprachkorrektur an.
- **Wichtig:** Alle Vision-Aufrufe auf **einer eigenen seriellen DispatchQueue**, aus Swift Concurrency
  per Continuation. Vision blockiert und braucht selbst Threads; auf dem Cooperative Thread Pool
  (mehrere parallel) hängt sonst alles (Deadlock, auch in Tests).
- Zeilen mit normierten Boxen (Vision-Konvention, Ursprung unten links).

### 4.5 Eingang (automatischer Import)
- Tab „Eingang“ mit Ablagefläche; Ordnerüberwachung per `DispatchSource` + 30-s-Timer; Datei erst
  verarbeiten, wenn ihre Größe 2 s stabil ist; beim Start liegende Dateien einreihen.
- Abgelegte Dateien werden in den Eingangsordner **kopiert** (im Hintergrund, mit Fortschritt).
  Kopieren erhält Erstell-/Änderungsdatum (wichtig für das Dokumentdatum).
- **Ordner abgelegt:** Dialog „Unterordner einbeziehen“, „PDFs“, „Bilder“ (mit Anzahl).
- **Mehrere Bilder abgelegt:** Dialog „zu einem PDF verbinden“ oder „einzeln“. Verbundenes PDF bekommt
  als Dateidatum das früheste Bilddatum.
- Warteschlange: nacheinander verarbeiten, Liste mit Status (wartet, läuft mit Schritt, erledigt
  grün/gelb/rot mit Meldung, Fehler → `Fehler/`, Duplikat → `Duplikate/`). Erfolgreich archivierte
  Originale in den **Papierkorb**.

### 4.6 Import-Verarbeitung (`ImportProcessor`)
1. Typ prüfen (PDF oder PNG/JPEG/TIFF/HEIC/BMP/GIF), SHA-256 → schon im Index? → Duplikat.
2. **PDF:** Text je Seite über PDFKit. Seite mit Text → `embedded` (Vektorseite bleibt). Seite ohne Text
   → rendern (300 dpi, angezeigte Lage) → OCR → `ocr`; ohne Text → **leer?** (`blank`, kein Problem)
   sonst `none` + `noText`.
3. **Bild:** OCR, Auflösung aus den Bild-Metadaten (sonst A4-Breite), einseitiges PDF in voller
   Auflösung; JPEG-Originale ohne erneute Kompression einbetten.
4. **Seitenreihenfolge** (nur PDFs): `PageNumbering.analyze`. Eindeutig falsch → vor dem Stempeln
   umsortieren (Texte, Textherkunft, OCR-Ebenen, Seitennummern in `noText` mitziehen), Hinweis
   `pageOrderCorrected`, `meta.pageOrder`; unklar → Hinweis `pageOrderUncertain`.
5. **Vorschlag** aus den ersten zwei Seiten (Apple Intelligence), sofern Text vorhanden und eingeschaltet.
6. **Datum** in dieser Reihenfolge: (a) im Text – Datum von Apple Intelligence, sonst DateExtractor
   (erst Seite 1, dann Seiten 1–2); (b) Datei – Datum im **Dateinamen** (`2025-12-11_…`, `20251211_…`,
   `11.12.2025 …`), dann **PDF-Erstelldatum**, dann das **frühere von Erstell-/Änderungsdatum** im
   Dateisystem (plausibel: 1970 bis morgen); (c) heute + Problem `noDate`.
7. **Fassungen erzeugen** (Nummer vom Archiv): (1) *angehängt* – Original + inkrementelles Update
   (Stempel, Textebene, Metadaten, ggf. neuer Seitenbaum); (2) *neu geschrieben* mit PDFKit; (3) *neu
   erzeugt* aus komprimierten Seitenbildern (nur wenn Bildseiten vorhanden und Kompression/Farbe nicht
   „Original“).
8. **Prüfen** jeder Fassung (Seitenzahl, Text auf allen Textseiten, Stempeltext findbar, Metadaten
   lesbar mit richtiger Nummer, bei Umsortierung Stichprobe typischer Wörter je Seite) und die
   **kleinste gültige** speichern; Speicherart in den Metadaten.
9. Index-Eintrag.

### 4.7 Kompression (Einstellungen, je Scan / importierte PDFs / importierte Bilder)
- Stufen: Original, ca. 300 / 150 / 80 / 40 KB pro A4-Seite. Farbe: Original, Graustufen,
  Schwarz-Weiß (1 Bit, Otsu-Schwelle).
- JPEG-Qualität per Binärsuche (0,25–0,9), notfalls Auflösung auf 200/150 dpi senken; verlustfreie
  Kodierung bevorzugen, wenn sie kleiner ist (Textseiten). **Nur Bildseiten** werden komprimiert.
- Die kleinere Datei gewinnt immer; ist die „komprimierte“ größer, bleibt das Original.
- Standard: Scan 150 KB + Graustufen, PDFs Original, Bilder 150 KB, Import-Farbe Original, 300 dpi.

### 4.8 PDF-Technik
- **Neues PDF** (`PDFBuilder`): CGContext-PDF; Seiteninhalt Bild (oder Vektorseite), unsichtbare
  Textebene, Stempel auf Seite 1. Metadaten danach mit PDFKit.
- **Unsichtbare Textebene mit eigener glyphloser TrueType-Schrift**, zur Laufzeit erzeugt (nur benutzte
  Zeichen, großer Zeichenvorrat inkl. Umlaute und €, Laufweiten wie Helvetica). Text **nicht horizontal
  stauchen**, sondern die Schriftgröße verkleinern, bis die Zeile in die Box passt – sonst liefert die
  Textextraktion „E U R O“ mit Leerzeichen.
- **Eigener PDF-Parser/Writer (`PDFRaw`)** für inkrementelle Updates: klassische Querverweistabellen und
  Querverweis-Streams (inkl. PNG-Prädiktor), Objekt-Streams, Seitenbaum mit geerbten Attributen
  (Resources, MediaBox, CropBox, Rotate), Flate. Strings hex/oktal escapen. Schreibt eine
  Querverweis-Tabelle bzw. einen Querverweis-Stream passend zum Original, Trailer mit `/Prev`.
- **`PDFAppender`:**
  - `stamp(original, stampText, overlays, meta, title, summary, order?)`: Stempel in Standardschrift
    Helvetica-Bold (WinAnsi, nicht eingebettet), Textebene in der glyphlosen Type0-Schrift mit ToUnicode,
    Inhalte als zusätzliche Content-Streams mit vorangestelltem `q` und `Q q <Matrix> cm …Q` (damit sie
    mit dem Grafikzustand der Seite beginnen), Metadaten-Anmerkung, Info-Dictionary; optional neuer
    flacher Seitenbaum (geerbte Attribute in die Seiten kopieren, Catalog neu).
  - `updateMetadata(data, meta, title, summary)`.
  - `rearrange(data, order, rotations, stampText, meta, …)`: neuer Seitenbaum, `Rotate` je Seite; wird
    eine andere Seite zur ersten (oder die erste gedreht): alte Stempelfläche weiß überdecken (in der alten
    Lage), Stempel auf der neuen ersten Seite, Metadaten-Anmerkung umziehen.
- **PDFKit-Fallstricke:** eigene Info-Schlüssel gehen verloren (→ Anmerkung); `CreationDate` wird beim
  Speichern überschrieben; Neuschreiben kodiert CCITT-Bilder als Flate um und bettet Schriften je Seite
  ein (Dateien werden viel größer) – deshalb Anhängen bevorzugen. Eigene `PDFPage`-Unterklasse
  (`draw(with:to:)`) nur für Seiten, die wirklich etwas brauchen (Seite 1, OCR-Seiten), über einen zweiten
  Dokument-Delegate.
- Metadaten nachträglich immer zuerst **anhängen**, nur als Fallback mit PDFKit neu schreiben.

### 4.9 Apple Intelligence (`Summarizer`)
- `FoundationModels`, `@Generable struct` mit `title` (3–6 Wörter: Dokumentart, Absender, ggf.
  Zeitraum), `summary` (1–2 Sätze: Absender, Art, wichtigste Angaben), `documentDate` (Ausstellungsdatum
  JJJJ-MM-TT, nicht Fälligkeit/Zeitraum; leer, wenn keins).
- Eingabe: Text der ersten **zwei** Seiten, höchstens 3000 Zeichen. Vorher **Maschinenzeilen
  entfernen** (z. B. `#!#METASTART…`, lange Codezeilen); bei `unsupportedLanguageOrLocale` einmal mit
  strenger Bereinigung erneut versuchen.
- Session vorwärmen (`prewarm`), Verfügbarkeit prüfen und verständlichen Grund liefern
  (nicht unterstützt, abgeschaltet, Modell lädt …).
- Bekannte Schwäche: gelegentlich Zeitraum- statt Rechnungsdatum – der Datumsvorschlag bleibt editierbar.

### 4.10 Hilfsmodule
- `DateExtractor`: deutsche/englische Datumsformate (TT.MM.JJJJ, TT. Monat JJJJ, JJJJ-MM-TT …), bestes
  Datum (bevorzugt Briefkopf-Nähe). Regex per `NSRegularExpression` (Swift-Regex-Literale unterstützen
  kein Lookbehind).
- `FileDate`: Datum aus Dateiname → PDF-Erstelldatum → Dateisystem.
- `PageNumbering`: gedruckte Seitenzahlen nur in den **ersten/letzten 4 Zeilen** (Zeilen nach Höhe
  sortiert): „Seite 2 von 5“, „Seite: 2/5“, „Seite 2“, „S. 2“, „Blatt 2“, „Page 2 of 5“, Zeile nur „2/5“,
  „- 2 -“. Nackte Zahlen zählen **nicht**. Eindeutig nur bei: ≥ 2 Nummern, alle verschieden, Gesamtzahl
  konsistent und = Seitenzahl, lückenlos, höchstens eine unnummerierte Seite (nur die **erste** darf
  unnummeriert vorn bleiben, eine hintere könnte eine Anlage sein). Aufsteigend = in Ordnung.
- `BlankPage`: auf ≤ 1000 px verkleinern, Rand ignorieren (links/rechts 10 %, oben/unten 6 % –
  Lochung, Scannerschatten, Maschinencodes wie DataMatrix am Rand), Pixel < 160 als Druck zählen; leer bei
  < 0,05 % Druckanteil. Durchscheinender Text der Rückseite ist heller und zählt nicht; eine dünne
  Unterschrift schon.
- `PageOrder`: Duplex verzahnen. `ImagesToPDF`: Bilder zu einem PDF. `FolderScan`: Ordner rekursiv mit
  Typfilter.
- `DocumentInfo`: Info-Zeilen (Quelle, Originaldatei mit Größe, Archiviert, Dokumentdatum mit Herkunft
  „aus dem Dateinamen – kein Datum im Text“ usw., Titel-Herkunft, Scan, Speicherung, Kompression,
  Dateigröße mit Änderung „+4 KB: Stempel, Metadaten angehängt“ bzw. „−120 KB durch Kompression“ – nur
  tatsächlich Hinzugefügtes nennen, Text je Seite inkl. „2 Seiten leer“, Seitenreihenfolge, OCR,
  Erstellt mit, Zuletzt geändert mit).

### 4.11 Suchindex (`SearchIndex`, SQLite FTS5)
- Tabelle `docs` (FTS5, `unicode61 remove_diacritics`): number, date, path, pages, issues, archivedAt,
  source, sha256, meta (JSON), originalName, title, summary, text; nicht durchsuchte Spalten `UNINDEXED`.
  Schema-Version in `user_version`; bei Änderung neu aufbauen.
- `fts5vocab`-Tabelle `docs_vocab` (row) für Platzhalter am Wortanfang.
- **Suche:** alle Wörter UND, Wortanfänge (`"wort"*`), Umlaute/Groß-Klein egal; Ergebnis mit markiertem
  Textausschnitt (`snippet`). Filter „nur mit Problemen“. Sortierung nach Nummer absteigend.
- **Sync** mit dem Archivordner: neue/geänderte PDFs (Änderungsdatum/Größe) einlesen, fehlende entfernen,
  vollständiger Neuaufbau möglich (alles aus den PDFs). Altbestand ohne Metadaten migrieren.
- `record(forSHA256:)` für Duplikate, `count(tagQuery:)`, `update(…, meta:, text:)`, `remove(path:)`.

### 4.12 Tags (gespeicherte Suchen)
- Name + Ausdruck, z. B. `("Rente" AND "DRV") OR "Rentenversicherung"`. `AND`/`UND`, `OR`/`ODER`,
  `NOT`/`NICHT` (nur binär: „Rente NOT Witwe“), Klammern, ohne Operator = AND. Wörter **exakt**
  (Groß-/Klein, Umlaute egal), Anführungszeichen optional, Wortfolgen in Anführungszeichen.
  Platzhalter: `rente*`, `*rente`, `*rente*` (führende über das Wörterbuch, höchstens 500 Wörter).
  Verständliche Fehlermeldungen („Klammer nicht geschlossen“, „Nach AND fehlt ein Begriff“ …).
- Leiste über dem Suchfeld: Tags als Umschaltknöpfe mit **Trefferzahl** (im Hintergrund gezählt; wird
  eine Zählung zu langsam, nur Namen), „+“ zum Anlegen, Kontextmenü Bearbeiten/Löschen, „Alle aufheben“.
- Aktive Tags und Suchfeld werden **UND**-verknüpft. **Tags markieren nichts** – weder im Textausschnitt
  (Ausschnitt dann in Swift bilden, nur Suchfeld-Wörter markieren) noch in der PDF-Vorschau.
- Editor mit Live-Prüfung („Gültig – 23 Dokumente“) und Syntaxhilfe.

### 4.13 Archiv-Tab
- Suchfeld, Tag-Leiste, Schalter **„Nur mit Problemen (n)“** (ohne Symbol, orange getönt), Anzahl,
  „Titel erzeugen (n)“ für Dokumente ohne Titel (Stapel mit Fortschritt und Abbrechen).
- Tabelle: Nr. (mit Problemsymbol), Datum, Dokument (Titel fett, Problemtext, Beschreibung; Tooltip mit
  vollständiger Beschreibung), Seiten, Datei (Tooltip mit allen Info-Zeilen). Rot/gelb je Schwere.
  Doppelklick öffnet in Vorschau.app.
- Kontextmenü: „Reihenfolge prüfen …“ (nur mit Reihenfolge-Hinweis, oben), Öffnen, Bearbeiten …,
  Seiten bearbeiten …, Drucken …, Im Finder zeigen, Als geprüft markieren, Löschen … (Rückfrage,
  Papierkorb, auch Entf-Taste).
- **Bearbeiten:** Datum, Titel, Beschreibung; Datei wird umbenannt, Metadaten angehängt, erledigte
  Probleme entfernt (Titel gesetzt → `noSuggestion`, Datum bestätigt → `noDate`). Der Stempel behält sein
  Datum.
- **Seiten bearbeiten:** Miniaturen mit Größenregler, Ziehen, Klick 180°, Rechtsklick 90°, „Wie im
  Original“ (bei `pageOrder`), „Zurücksetzen“; **„Sichern“ immer aktiv** – ohne Änderung bestätigt es die
  Reihenfolge (nur Hinweis entfernen). Mit Änderung: `Archive.rearrange` (anhängen, prüfen, atomar
  ersetzen), `pageOrder` verketten (Identität → nil), Reihenfolge-Hinweise entfernen, `noText`-Seiten
  umnummerieren, Index-Text erneuern.
- **Vorschau rechts** (geteilte Ansicht, feste Breiten – kein Umspringen beim ersten Dokument): eigenes
  Suchfeld, vorbelegt mit der Archivsuche; alle Treffer gelb markiert, aktueller ausgewählt;
  ⏎/⌘G weiter, ⇧⌘G zurück; Trefferliste mit Seite und Kontext (Klick springt). Knöpfe: ⓘ Info
  (Popover mit allen Angaben und „Zu prüfen“ inkl. „Seiten bearbeiten …“), **Drucken** (⌘P,
  `printOperation`, Sheet am Fenster), **Teilen** (`ShareLink`: Mail als Anhang, Nachrichten, AirDrop),
  in Vorschau.app öffnen.

### 4.14 Einstellungen (⌘,)
Archivordner, Eingangsordner, Auflösung, Scan-Farbe, Ausrichtung automatisch erkennen, Rückseiten 180°,
Kompression je Scan/PDF/Bild, Import-Farbe.

### 4.15 Programmstart / Migrationen
Archiv und Index öffnen, Eingang starten, Index im Hintergrund abgleichen. Einmalige Nachprüfungen je
Archiv über versionierte UserDefaults-Schlüssel (z. B. leere Seiten nachträglich erkennen und
`noText`-Vermerke dafür entfernen). Nach Änderungen einen `revision`-Zähler erhöhen, damit Listen neu
laden.

---

## 5. Architektur

Siehe `docs/ARCHITEKTUR.md`. Kurzfassung:

- **App:** `AppModel` (@Observable, MainActor: Archiv, Index, Tags, Einstellungen, Dokument-Aktionen,
  Migrationen), `ScanSession` (Zustandsautomat des Scans), `ScannerService`, `InboxService`, Views.
- **Core:** Verarbeitung (`ImportProcessor`, `OCRService`, `Summarizer`, `DateExtractor`, `FileDate`,
  `PageNumbering`, `BlankPage`, `PageOrder`, `ImagesToPDF`, `FolderScan`), PDF (`PDFBuilder` +
  `ImageTools`, `PDFStamper`, `PDFAppender`, `PDFRaw`, `GlyphlessFont`, `PageCompressor`), Ablage
  (`Archive`, `SearchIndex`, `TagStore`, `TagQuery`, `DocumentMetadata`/`PDFMetadata`, `DocumentIssue`,
  `DocumentInfo`).
- `Archive` und `SearchIndex` sind threadsicher (Lock); schwere Arbeit in `Task.detached`, UI-Zustand auf
  dem MainActor.

---

## 6. Umsetzungsreihenfolge (Etappen)

1. Paket, Build-Skript, Archiv (Nummern, Dateinamen), PDFBuilder mit Stempel und Textebene,
   OCRService, Tests.
2. Scanner + Stapelscan + Vorschau + Speichern.
3. Suchindex + Archiv-Tab (Liste, Suche, Öffnen, Löschen) + Vorschau mit Suche.
4. Apple Intelligence (Titel, Beschreibung, Datum), Bearbeiten, „Titel erzeugen“.
5. Metadaten im PDF, Index-Neuaufbau, Probleme mit Filter.
6. Eingang mit Ordnerüberwachung, Import-Verarbeitung, Duplikate, Ordner-/Bilder-Dialoge.
7. Kompression, PDFRaw + PDFAppender (inkrementell), Fassungsauswahl, Info-Anzeige.
8. Tags.
9. Dokumentdatum aus Datei, Ausrichtung, Seite für Seite, Vorlagenglas, Ziehen in der Vorschau.
10. Seitenreihenfolge, Schweregrade, Seiten bearbeiten, leere Seiten, Drucken/Teilen.

---

## 7. Abnahmekriterien / Tests (Auswahl)

- Nummern: fortlaufend, nach Löschen nicht wiederverwendet, Zähler und Dateien konsistent.
- Stempel „Nr. 000001 · TT.MM.JJJJ“ per PDFKit-Textsuche auf Seite 1 findbar; OCR-Text durchsuchbar,
  ohne Leerzeichen zwischen Buchstaben.
- Metadaten überstehen Schreiben/Lesen exakt (inkl. Datum, Umlaute).
- Importiertes Text-PDF: Original ist Präfix der Archivdatei, nur wenige KB angehängt, Links bleiben.
- PDF mit Objekt- und Querverweis-Streams wird korrekt angehängt (handgebautes Test-PDF).
- Bild-PDF mit Kompression wird deutlich kleiner; Textseite wird nie größer.
- Duplikat per SHA-256 erkannt, auch nach Index-Neuaufbau.
- Index-Neuaufbau stellt alles aus den PDFs wieder her.
- Tags: Parser (Syntax, Fehler), Platzhalter über Wörterbuch, Kombination mit Suche, keine Markierung.
- Datum: Text vor Dateiname vor PDF-Erstelldatum vor Dateisystem vor heute; Kopieren erhält Dateidatum.
- Ausrichtung: synthetische Seite in 0/90/180/270° wird korrekt erkannt; leere Seite → keine Entscheidung.
- Seitenreihenfolge: Muster, vertauschte Seiten, Duplex-Fehler, unnummerierte erste Seite, doppelte
  Nummern (unklar), nackte Zahlen ignoriert; Import sortiert um (alle Fassungen).
- Seiten bearbeiten: Stempel wandert (Pixelprüfung: rot vorn, alte Fläche ohne Rot), Drehung,
  Metadaten, Original-Präfix erhalten; „Wie im Original“ ergibt `pageOrder == nil`.
- Leere Seiten: weiß, Staub, Scannerrand, Lochung + DataMatrix, durchscheinender Text → leer;
  Unterschrift, Kritzelei, Text → nicht leer.
- Apple-Intelligence-Test nur, wenn verfügbar (sonst übersprungen); er darf gelegentlich schwanken.

---

## 8. Stil

- Code und Kommentare knapp, Kommentare deutsch, erklären das *Warum*.
- Keine Warnungen zu Concurrency ignorieren; `@unchecked Sendable` nur mit Lock.
- UI-Texte kurz und freundlich, deutsche Anführungszeichen „…“, Auslassungspunkte „…“ bei Knöpfen,
  die einen Dialog öffnen.
- README mit Bedienung, Eingang, Tags, Dokumentdatum, Problemen, Seitenreihenfolge, Kompression,
  Speicherformat, Einstellungen.
