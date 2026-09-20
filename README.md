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

1. Stapel mit den Vorderseiten nach oben einlegen und **Stapel scannen** klicken.
2. Stapel aus der Ablage nehmen, **als Ganzes umdrehen** (Reihenfolge nicht ändern) und wieder einlegen,
   dann **Rückseiten scannen** klicken. Bei einseitigen Dokumenten: **Nur einseitig – fertig**.
3. Vorschau prüfen: Ein Klick dreht eine Seite um 180°, das Kontextmenü dreht um 90° oder entfernt
   die Seite. **Ziehen** verschiebt eine Seite an eine andere Stelle. **Seite scannen** hängt eine
   weitere Seite an. Oben stehen die Vorschläge für Datum, Titel und Beschreibung. Sie sind nach
   wenigen Sekunden da und lassen sich überschreiben. Dann **Speichern**.

**Seite für Seite:** Für gebundene, empfindliche oder sehr unterschiedliche Blätter. Nach jeder Seite
fragt das Programm, ob noch eine kommt (**Nächste Seite scannen**, **Letzte Seite wiederholen**,
**Fertig**). Gescannt wird wahlweise über das **Vorlagenglas** oder den **Einzug**; die Wahl wird
gemerkt. Die Texterkennung läuft schon, während die nächste Seite aufgelegt wird.

**Automatische Ausrichtung:** Steht der Text einer Seite quer oder auf dem Kopf, wird sie in der
Vorschau aufrecht gedreht (Symbol ↻ an der Miniatur). Dazu liest eine schnelle Texterkennung die
Seite in allen vier Richtungen und wählt die, in der echte Wörter herauskommen. Seiten ohne
erkennbaren Text bleiben unverändert. Abschaltbar in den Einstellungen.

## Eingang (automatischer Import)

Dateien, Bilder und Ordner lassen sich **in jedem Tab** ablegen – auch direkt im Archiv. Läuft eine
Verarbeitung, zeigt das Archiv oben eine Leiste mit Fortschritt; danach steht dort „3 Dokumente
archiviert“ mit **Anzeigen** (hebt Suche und Tags auf, sortiert nach Nummer und markiert die neuen
Zeilen mit „neu“), **Eingang zeigen** bei Fehlern oder Duplikaten und **Ausblenden**. Der Tab „Eingang“
trägt währenddessen ein Abzeichen.

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

- **kein Text erkannt:** Die OCR fand auf einer Bild-Seite mit Inhalt (Foto, Handschrift) keinen Text.
  **Leere Seiten**, etwa unbedruckte Rückseiten, sind kein Problem. Die Info zeigt sie als „leer“.
  Erkannt wird das am Anteil dunkler Pixel; Staub, Scannerränder, Lochung, Maschinencodes am Rand (z. B. DataMatrix) und durchscheinender Text der
  Rückseite zählen nicht. Ältere Dokumente werden beim ersten Start einmal nachgeprüft.
- **kein Titel/keine Beschreibung:** Apple Intelligence war nicht verfügbar oder hat abgelehnt.
- **kein Datum gefunden:** Es gilt das Tagesdatum, auch im Dateinamen.
- **Seitenreihenfolge korrigiert / prüfen** (nur Import, siehe „Seitenreihenfolge“).

Es gibt zwei Stufen: **Fehler** (rot, ⚠︎) und **Hinweise** (gelb, ⓘ). Hinweise sind die Seitenreihenfolge
und ein bewusst abgeschaltetes Apple Intelligence. Die Farbe richtet sich nach dem schwersten Problem;
der Tooltip nennt die Gründe. Der Schalter
**„Nur mit Problemen“** filtert sie (rote und gelbe), auch kombiniert mit der Suche. Die Markierung verschwindet, sobald
du Titel bzw. Datum über „Bearbeiten …“ ergänzt, über „Titel erzeugen“ oder mit Rechtsklick →
**„Als geprüft markieren“**. Die Vermerke stehen im PDF selbst (siehe unten).

Im Archiv lassen sich Datum, Titel und Beschreibung per Rechtsklick → **Bearbeiten …** ändern. Die Datei
wird dabei umbenannt. Der Stempel auf Seite 1 behält das Datum vom Speichern.
**Vorschau im Archiv:** Ein Klick auf ein Dokument zeigt es rechts neben der Liste. Oben rechts
gibt es **Drucken** (⌘P, auch per Rechtsklick in der Liste) und **Teilen** (Mail als Anhang,
Nachrichten, AirDrop …). Das Suchfeld
der Vorschau übernimmt den Suchbegriff aus dem Archiv und lässt sich frei ändern. Alle Treffer sind
gelb markiert, der aktuelle ist ausgewählt. Mit ⏎ oder ⌘G springst du zum nächsten Treffer, mit ⇧⌘G
zum vorherigen. Die Trefferliste unter dem Dokument zeigt Seite und Textumgebung; ein Klick springt hin.

**Seiten bearbeiten:** Rechtsklick → **Seiten bearbeiten …** zeigt alle Seiten eines archivierten
Dokuments. Ziehen ändert die Reihenfolge, ein Klick dreht um 180°, ein Rechtsklick um 90°. Bei
Dokumenten, die beim Import umsortiert wurden, steht **Reihenfolge prüfen …** ganz oben im Menü (auch
in der Info ⓘ), und **Wie im Original** stellt die Reihenfolge der importierten Datei wieder her.
Gespeichert wird inkrementell; der bisherige Dateiinhalt bleibt erhalten. Der Stempel gehört immer auf
Seite 1: Wird eine andere Seite zur ersten, wird der alte Stempel weiß überdeckt, und die neue erste
Seite bekommt denselben Stempel (Nummer und Datum bleiben). Danach ist der Reihenfolge-Vermerk erledigt.

Per Rechtsklick → **Löschen …** oder mit der Entf-Taste landen Dokumente nach einer Rückfrage im
Papierkorb und lassen sich dort wiederherstellen. Ihre Nummern werden nicht neu vergeben.
Fährst du mit der Maus über die Spalte „Dokument“, zeigt ein Tooltip die ganze Beschreibung.
Für Dokumente ohne Titel gibt es oben im Archiv den Button **Titel erzeugen**.

### Apple Intelligence

Die Vorschläge für Titel und Beschreibung brauchen macOS 26 mit eingeschalteter Apple Intelligence
(Systemeinstellungen → Apple Intelligence & Siri). Der Text verlässt den Mac nicht. Ohne Apple
Intelligence funktioniert alles andere weiter, und das Datum wird trotzdem aus dem Text erkannt.

Stehen alle Rückseiten auf dem Kopf (Stapel über die kurze Kante gewendet), in den Einstellungen (⌘,)
**Rückseiten automatisch um 180° drehen** einschalten. Mit der automatischen Ausrichtung ist das nur
noch für Rückseiten ohne erkennbaren Text nötig.

## Seitenreihenfolge

Stehen auf den Seiten gedruckte Seitenzahlen, prüft ScanArchiv, ob die Reihenfolge stimmt. Erkannt
werden nur eindeutige Angaben in Kopf- oder Fußzeile: „Seite 2 von 4“, „Seite 2/4“, „Seite 2“, „S. 2“,
„Blatt 2“, „Page 2 of 4“, „2/4“ und „- 2 -“. Nackte Zahlen zählen nicht, damit Beträge oder
Positionsnummern keinen Fehlalarm auslösen.

- **Import (Eingang):** Ist die richtige Reihenfolge eindeutig, werden die Seiten vor dem Stempeln
  umsortiert. Der Stempel landet so auf der richtigen ersten Seite. Das Dokument wird **gelb** markiert
  („Seitenreihenfolge laut Seitenzahlen korrigiert (vorher 1, 3, 2) – bitte prüfen“), und die Info
  zeigt die Originalreihenfolge. Das Original bleibt dabei unverändert; nur der Seitenbaum wird
  inkrementell neu angehängt. Eine unnummerierte erste Seite (Anschreiben) bleibt vorn. Unklare Fälle,
  etwa zwei Briefe mit je „Seite 1 von 2“, werden nicht umsortiert, sondern nur gelb vermerkt.
- **Scan-Vorschau:** Eine gelbe Leiste über den Seiten meldet eine vermutlich falsche Reihenfolge, mit
  **Umsortieren** und **Ignorieren**. Die Prüfung braucht die Texterkennung aller Seiten. Klickst du
  vorher auf **Speichern**, wird erst fertig erkannt; passt die Reihenfolge nicht, erscheint die Leiste,
  und gespeichert wird erst beim nächsten Klick. Beim Scan wird nichts vermerkt, weil du die Seiten
  ja gesehen hast.

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
