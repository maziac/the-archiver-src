# ScanArchiv

Mac-App für beidseitige Dokumente mit einem Scanner, der über den Einzug nur einseitig scannt
(entwickelt für den Brother MFC-L2710DN im Netzwerk).

- steuert den Scanner direkt (ImageCaptureCore / AirScan), ganz ohne Brother-Software
- führt dich durch zwei Durchgänge: Vorderseiten → Stapel wenden → Rückseiten
- sortiert die Seiten in die Originalreihenfolge (V1, R1, V2, R2, …)
- Texterkennung mit Apple Vision (Deutsch/Englisch), erzeugt ein durchsuchbares PDF
- schlägt **Datum, Titel und Kurzbeschreibung** vor. Das Datum kommt aus dem Text, Titel und Beschreibung erzeugt Apple Intelligence lokal. Ohne gefundenes Datum gilt das heutige.
- Dateiname `JJJJ-MM-TT_NNNNNN_Titel.pdf` mit fortlaufender, eindeutiger Nummer
- Nummer als Stempel oben rechts auf Seite 1 und in den PDF-Metadaten (Stichwörter). Titel und Beschreibung stehen als PDF-Titel und PDF-Betreff im Dokument.
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

Im Archiv lassen sich Datum, Titel und Beschreibung per Rechtsklick → **Bearbeiten …** ändern. Die Datei
wird dabei umbenannt. Der Stempel auf Seite 1 behält das Datum vom Speichern.
Für Dokumente ohne Titel gibt es oben im Archiv den Button **Titel erzeugen**.

### Apple Intelligence

Die Vorschläge für Titel und Beschreibung brauchen macOS 26 mit eingeschalteter Apple Intelligence
(Systemeinstellungen → Apple Intelligence & Siri). Der Text verlässt den Mac nicht. Ohne Apple
Intelligence funktioniert alles andere weiter, und das Datum wird trotzdem aus dem Text erkannt.

Stehen alle Rückseiten auf dem Kopf (Stapel über die kurze Kante gewendet), in den Einstellungen (⌘,)
**Rückseiten automatisch um 180° drehen** einschalten.

## Einstellungen (⌘,)

Archivordner (Standard `~/Documents/ScanArchiv`), Auflösung, Farbe/Graustufen, Rückseiten drehen, JPEG-Qualität.

## Archivordner

| Datei | Inhalt |
| --- | --- |
| `JJJJ-MM-TT_NNNNNN_Titel.pdf` | die Dokumente (Titel und Beschreibung auch in den PDF-Metadaten) |
| `counter.json` | letzte vergebene Nummer |
| `.scanarchiv-index.sqlite` | Suchindex (SQLite FTS5), jederzeit per „Index neu aufbauen“ wiederherstellbar |

Die nächste Nummer ist immer größer als der Zählerstand **und** größer als jede Nummer, die schon in
einem Dateinamen vorkommt. So entstehen keine Doppelten, selbst wenn `counter.json` verloren geht.
Andere PDFs, die du in den Ordner legst, werden ebenfalls indexiert.

## Aufbau

- `Sources/ScanArchivCore/`: scannerunabhängige Logik (Seitenreihenfolge, OCR, PDF, Archiv, Suchindex,
  Datumserkennung `DateExtractor`, Vorschläge `Summarizer`), mit Tests
- `Sources/ScanArchiv/`: SwiftUI-App und Scannersteuerung (`ScannerService`), Ablauf (`ScanSession`)

Scanner-Diagnose: `log stream --predicate 'subsystem == "de.local.scanarchiv"'`
