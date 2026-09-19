# ScanArchiv

Mac-App für beidseitige Dokumente mit einem Scanner, der über den Einzug nur einseitig scannt
(entwickelt für den Brother MFC-L2710DN im Netzwerk).

- steuert den Scanner direkt (ImageCaptureCore / AirScan), ganz ohne Brother-Software
- führt dich durch zwei Durchgänge: Vorderseiten → Stapel wenden → Rückseiten
- sortiert die Seiten in die Originalreihenfolge (V1, R1, V2, R2, …)
- Texterkennung mit Apple Vision (Deutsch/Englisch), erzeugt ein durchsuchbares PDF
- schlägt **Datum, Titel und Kurzbeschreibung** vor. Das Datum kommt aus dem Text, Titel und Beschreibung erzeugt Apple Intelligence lokal. Ohne gefundenes Datum gilt das heutige.
- Dateiname `JJJJ-MM-TT_NNNNNN_Titel.pdf` mit fortlaufender, eindeutiger Nummer
- automatischer Import vorhandener PDFs/Bilder über einen überwachten Eingangsordner oder per Drag & Drop
- Nummer als roter Stempel oben rechts auf Seite 1 und in den PDF-Metadaten (Stichwörter). Titel und Beschreibung stehen als PDF-Titel und PDF-Betreff im Dokument.
- Archiv-Tab: Stichwortsuche in Text, Titel und Beschreibung (UND-verknüpft, Präfix, Umlaute egal) oder nach Nummer; Doppelklick öffnet das PDF

## Bauen & Starten

Benötigt macOS 14+ und Xcode (bzw. die Command Line Tools).

```bash
./build.sh
open build/ScanArchiv.app
```

Tests: `swift test`

Icon neu erzeugen: `swift scripts/make_icon.swift`

## Bedienung

1. Stapel mit den Vorderseiten nach oben einlegen und **Vorderseiten scannen** klicken.
2. Stapel aus der Ablage nehmen, **als Ganzes umdrehen** (Reihenfolge nicht ändern) und wieder einlegen,
   dann **Rückseiten scannen** klicken. Bei einseitigen Dokumenten: **Nur einseitig – fertig**.
3. Vorschau prüfen: Ein Klick dreht eine Seite um 180°, übers Kontextmenü lässt sich eine Seite entfernen.
   Oben stehen die Vorschläge für Datum, Titel und Beschreibung. Sie sind nach wenigen Sekunden da
   und lassen sich überschreiben. Dann **Speichern**.

## Eingang (automatischer Import)

Vorhandene PDFs und Bilder werden vollautomatisch archiviert, ohne Vorschau:

- **Tab „Eingang“:** Dateien auf die Fläche ziehen oder „Dateien oder Ordner auswählen …“ (auch ein Ziehen auf
  den Scan-Tab landet hier). Die Dateien werden in den Eingangsordner **kopiert**; deine Originale bleiben.
- **Mehrere Bilder:** Legst du mehrere Bilder gleichzeitig ab, fragt ein Dialog, ob sie **zu einem Dokument
  verbunden** werden (eine Seite je Bild, Reihenfolge nach Dateiname) oder **je Bild ein eigenes Dokument**
  ergeben. Beim Verbinden werden die Bilder nicht neu kodiert; Texterkennung, Titel, Datum und Nummer
  vergibt ScanArchiv danach wie gewohnt.
- **Ordner:** Beim Ablegen eines Ordners fragt ein Dialog, ob **Unterordner** einbezogen werden sollen und welche
  **Dateitypen** (PDFs, Bilder) übernommen werden. Er zeigt vorab, wie viele Dateien gefunden wurden; die Auswahl
  wird gemerkt. Das Kopieren läuft im Hintergrund, der Fortschritt steht in der Kopfzeile des Eingangs.
- **Eingangsordner** (Standard `~/Documents/ScanArchiv-Eingang`, änderbar in ⌘,): Was du dort hineinlegst,
  wird automatisch verarbeitet, sowohl im laufenden Betrieb als auch beim nächsten Start der App.
  Eine Datei wird erst übernommen, wenn sie 2 s lang unverändert ist (laufende Kopiervorgänge).
- Die Dateien laufen **nacheinander** durch: Text (eingebettet oder per OCR) → Titel, Beschreibung, Datum →
  Nummer, Stempel → Archiv. Danach wandert die Datei aus dem Eingang **in den Papierkorb**.
- Nicht verarbeitbare Dateien (defekt, unbekanntes Format) kommen nach **`Eingang/Fehler`**.
- **Duplikate:** Die App merkt sich eine Prüfsumme (SHA-256) jeder importierten Originaldatei. Ist dieselbe
  Datei schon archiviert, wird sie nicht erneut aufgenommen, sondern nach **`Eingang/Duplikate`** verschoben
  und als „Duplikat von Nr. …“ gemeldet.
  Rechtsklick → „Erneut versuchen“ legt sie zurück in den Eingang.
- Die Liste zeigt wartende, laufende und fertige Dateien. Ein Doppelklick öffnet das Ergebnis.
  „Pause“ hält die Verarbeitung nach der aktuellen Datei an.

PDFs bleiben dabei (mit der Standardeinstellung „Original“) inhaltlich unverändert: Text, Bilder in
Originalauflösung und Farbe, Links und Lesezeichen bleiben erhalten. Seiten mit eigenem Text werden nicht erneut erkannt; Seiten, die nur ein
Bild sind, bekommen eine unsichtbare OCR-Textebene. Hinzu kommen nur der rote Stempel und die Metadaten.
Für Titel, Beschreibung und Datum werden die ersten zwei Seiten verwendet.

## Tags (gespeicherte Suchen)

Über dem Suchfeld im Archiv stehen **Tags**: benannte Suchen wie „Rente“ mit dem Ausdruck
`("Rente" AND "DRV") OR "Rentenversicherung"`. Ein Klick schaltet einen Tag als Filter an oder aus; mehrere
aktive Tags und das Suchfeld werden **UND-verknüpft**. Die Zahl hinter dem Namen zeigt, wie viele Dokumente
der Tag trifft. „+“ legt einen Tag an, Rechtsklick → „Bearbeiten …“ / „Löschen“.

| Ausdruck | findet |
|---|---|
| `Rente` oder `"Rente"` | genau dieses Wort (Groß-/Kleinschreibung und Umlaute egal) |
| `rente*` | Wortanfang: Rente, Rentenbescheid, … |
| `*rente` | Wortende: Altersrente, Witwenrente, … |
| `*rente*` | enthält: Altersrentenbescheid, … |
| `"Deutsche Rentenversicherung"` | Wortfolge |
| `A AND B`, `A OR B`, `A NOT B`, `( … )` | auch `UND`, `ODER`, `NICHT`; ohne Operator gilt AND |

- Tags stehen **nicht** im Dokument und werden in Liste und Vorschau **nicht markiert** – sie filtern nur.
  Markiert werden nur Wörter aus dem Suchfeld.
- Der Editor prüft den Ausdruck sofort und zeigt die Trefferzahl.
- Gespeichert werden die Tags im Archivordner in `.scanarchiv-tags.json`; sie wandern also mit dem Archiv.

## Dokumentdatum

Das Datum im Dateinamen und in der Liste wird in dieser Reihenfolge bestimmt:

1. **Datum im Text** – das Brief-/Rechnungsdatum (von Apple Intelligence gewählt oder direkt erkannt),
2. **Datum der Datei** (nur bei Importen): zuerst ein Datum im **Dateinamen** (`2025-12-11_…`, `20251211_…`,
   `11.12.2025 …`), sonst das **Erstelldatum im PDF**, sonst das **Datum im Dateisystem** (das frühere von
   Erstell- und Änderungsdatum). Das Kopieren in den Eingang ändert diese Daten nicht; beim Verbinden mehrerer
   Bilder übernimmt das PDF das früheste Bilddatum.
3. **heutiges Datum** – dann mit dem Vermerk „kein Datum gefunden“.

Woher das Datum stammt, steht in der Info (ⓘ) unter „Dokumentdatum“.

## Dokumente mit Problemen

Lässt sich eine Datei zwar lesen, aber nicht vollständig verarbeiten, wird sie trotzdem archiviert und
als „zu prüfen“ markiert:

- **kein Text erkannt:** Die OCR fand auf einer Bild-Seite keinen Text.
- **kein Titel/keine Beschreibung:** Apple Intelligence war nicht verfügbar oder hat abgelehnt.
- **kein Datum gefunden:** Es gilt das Tagesdatum, auch im Dateinamen.

Solche Dokumente erscheinen im Archiv **rot** mit ⚠︎, der Tooltip nennt die Gründe. Der Schalter
**„Nur mit Problemen“** filtert sie, auch kombiniert mit der Suche. Die Markierung verschwindet, sobald
du Titel bzw. Datum über „Bearbeiten …“ ergänzt, über „Titel erzeugen“ oder mit Rechtsklick →
**„Als geprüft markieren“**. Die Vermerke stehen im PDF selbst (siehe unten).

Im Archiv lassen sich Datum, Titel und Beschreibung per Rechtsklick → **Bearbeiten …** ändern. Die Datei
wird dabei umbenannt. Der Stempel auf Seite 1 behält das Datum vom Speichern.
**Vorschau im Archiv:** Ein Klick auf ein Dokument zeigt es rechts neben der Liste. Das Suchfeld
der Vorschau übernimmt den Suchbegriff aus dem Archiv und lässt sich frei ändern. Alle Treffer sind
gelb markiert, der aktuelle ist ausgewählt. Mit ⏎ oder ⌘G springst du zum nächsten Treffer, mit ⇧⌘G
zum vorherigen. Die Trefferliste unter dem Dokument zeigt Seite und Textumgebung; ein Klick springt hin.

Per Rechtsklick → **Löschen …** oder mit der Entf-Taste landen Dokumente nach einer Rückfrage im
Papierkorb und lassen sich dort wiederherstellen. Ihre Nummern werden nicht neu vergeben.
Fährst du mit der Maus über die Spalte „Dokument“, zeigt ein Tooltip die ganze Beschreibung.
Für Dokumente ohne Titel gibt es oben im Archiv den Button **Titel erzeugen**.

### Apple Intelligence

Die Vorschläge für Titel und Beschreibung brauchen macOS 26 mit eingeschalteter Apple Intelligence
(Systemeinstellungen → Apple Intelligence & Siri). Der Text verlässt den Mac nicht. Ohne Apple
Intelligence funktioniert alles andere weiter, und das Datum wird trotzdem aus dem Text erkannt.

Stehen alle Rückseiten auf dem Kopf (Stapel über die kurze Kante gewendet), in den Einstellungen (⌘,)
**Rückseiten automatisch um 180° drehen** einschalten.

## Kompression

In den Einstellungen gibt es je eine Größenvorgabe für **Scans**, **importierte PDFs** und **importierte
Bilder**: *Original (keine Kompression)* oder ca. **300 / 150 / 80 / 40 KB pro A4-Seite**. Dazu kommt ein
Farbmodus: *Farbe/Original*, *Graustufen* oder *Schwarz-Weiß (1 Bit)*.

- Umgewandelt werden nur **Bildseiten** (Scans). Seiten mit echtem Text bleiben als Vektor unverändert.
- **Die kleinere Datei gewinnt:** Ist die umgewandelte Fassung nicht kleiner als das Original, bleibt das
  Original. Bei sauberen Seiten wird auch verlustfrei gespeichert, wenn das kleiner ist als JPEG.
- Importierte JPEGs werden mit „Original“ ohne erneute Kompression übernommen.
- Die Zielgrößen sind Richtwerte. Dicht beschriebene Textseiten kommen in Graustufen auf etwa
  100–200 KB, weil die Auflösung für die Lesbarkeit nicht unter 150 dpi sinkt. Für 80 oder 40 KB
  eignet sich **Schwarz-Weiß** (typisch 25–60 KB pro Textseite), das Fotos und Logos aber grob macht.

### Importierte PDFs bleiben unverändert (inkrementelles Speichern)

ScanArchiv schreibt importierte PDFs nicht neu, sondern **hängt** Stempel, OCR-Textebene (nur für Bildseiten)
und Metadaten per inkrementellem Update an das unveränderte Original an – ein Standardverfahren von PDF.
So bleiben Bilder (z. B. CCITT-Fax-Scans), Schriften und Objekt-Streams bitgenau erhalten; der Aufschlag
liegt typisch bei 2–6 KB. Beispiel: ein 6-seitiges Versicherungs-PDF mit CCITT-Scans wuchs früher beim
Neuschreiben durch PDFKit um 533 KB, jetzt um etwa 3 KB.

- Der Stempel nutzt die PDF-Standardschrift Helvetica-Bold (ohne Einbettung), die OCR-Ebene eine von
  ScanArchiv erzeugte **Schrift ohne Zeichenformen** mit nur den benutzten Zeichen, wie bei OCRmyPDF.
- Beim Import entstehen mehrere Fassungen: angehängt, durch PDFKit neu geschrieben und – bei aktiver
  Kompression – mit neu erzeugten Bildseiten. Jede wird geprüft (Text aller Seiten, Stempel, Metadaten);
  die **kleinste gültige** wird gespeichert. Welche es ist, steht in der Info unter „Speicherung“.
- Auch spätere Änderungen (Bearbeiten, „Als geprüft“, „Titel erzeugen“) werden angehängt (unter 1 KB).
- Die Info nennt bei „Dateigröße“ nur, was tatsächlich hinzukam, z. B. „+3 KB: Stempel, Metadaten angehängt“.

## Was im PDF gespeichert wird

Das PDF ist maßgeblich; der Suchindex ist nur eine Kopie. **„Index neu aufbauen“** liest alle PDFs neu ein
und stellt alles vollständig wieder her.

- **Standardfelder** (auch für Spotlight und Vorschau.app): Titel, Beschreibung (Betreff), Nummer
  (Stichwörter), Programm, Archivierungszeitpunkt (Erstelldatum).
- **ScanArchiv-Daten** als JSON in einer unsichtbaren, nicht druckbaren Anmerkung auf Seite 1:
  - Dokumentdatum und Herkunft (Text, Apple Intelligence, Tagesdatum, von Hand),
  - Herkunft von Titel/Beschreibung (Apple Intelligence oder von Hand) mit Zeitpunkt,
  - Quelle (Scan/PDF/Bild), Originaldateiname, -größe und Prüfsumme,
  - Scanparameter (Scanner, dpi, Farbe),
  - Kompression (Vorgabe, Farbmodus, angewendet oder Original behalten, Größe vorher/nachher),
  - je Seite die Herkunft des Textes: *vorhandener Text* (schon im Original, keine OCR nötig), *per OCR erkannt*,
    *ohne Text* (OCR fand nichts) oder bei Altbestand *Herkunft unbekannt*; dazu OCR-Engine, Sprachen und Zeitpunkt,
  - Problem-Vermerke.
  - Programmversion bei der Erstellung und bei der letzten Änderung, z. B. „ScanArchiv 1.1 (Build 202609191013)“.
    Daran lässt sich später erkennen, welche Dokumente mit welcher OCR- bzw. Kompressionslogik entstanden sind.
- Im Archiv zeigen der **ⓘ-Button** über der Vorschau und der **Tooltip über der Spalte „Datei“** diese Angaben an.
- Dokumente aus älteren Versionen bekommen die Daten beim nächsten Einlesen einmalig ergänzt; die
  frühere Zusatzdatei `.scanarchiv-issues.json` wird dabei übernommen und entfernt. Als Erstellversion steht dort
  „ScanArchiv vor 1.0“.

Die aktuelle Programmversion steht in den Einstellungen unter „Über“. `build.sh` vergibt bei jedem Build eine
eindeutige Build-Nummer (Zeitstempel).

## Einstellungen (⌘,)

Archivordner, Eingangsordner, Scan-Auflösung und -Farbe, Rückseiten drehen, Kompression (siehe oben).

## Archivordner

| Datei | Inhalt |
| --- | --- |
| `JJJJ-MM-TT_NNNNNN_Titel.pdf` | die Dokumente (Titel und Beschreibung auch in den PDF-Metadaten) |
| `counter.json` | letzte vergebene Nummer |
| `.scanarchiv-tags.json` | Tags (gespeicherte Suchen) |
| `.scanarchiv-index.sqlite` | Suchindex (SQLite FTS5), jederzeit per „Index neu aufbauen“ wiederherstellbar |

Die nächste Nummer ist immer größer als der Zählerstand **und** größer als jede Nummer, die schon in
einem Dateinamen vorkommt. So entstehen keine Doppelten, selbst wenn `counter.json` verloren geht.
Andere PDFs, die du in den Ordner legst, werden ebenfalls indexiert.

## Aufbau

- `Sources/ScanArchivCore/`: scannerunabhängige Logik (Seitenreihenfolge, OCR, PDF, Archiv, Suchindex,
  Datumserkennung `DateExtractor`, Vorschläge `Summarizer`), mit Tests
- `Sources/ScanArchiv/`: SwiftUI-App und Scannersteuerung (`ScannerService`), Ablauf (`ScanSession`)

Scanner-Diagnose: `log stream --predicate 'subsystem == "de.local.scanarchiv"'`
