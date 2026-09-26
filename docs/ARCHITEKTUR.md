# ScanArchiv – Architektur

Dieses Dokument beschreibt den Aufbau des Programms: die Module, wie sie zusammenhängen und wie die
wichtigsten Abläufe funktionieren. Die Diagramme sind in [Mermaid](https://mermaid.js.org) geschrieben
(GitHub, Xcode-Vorschau, VS Code und viele Markdown-Editoren zeigen sie direkt an). Jedes Diagramm legt
seine Farben selbst fest (helle Kästen, mittelblaue Linien), damit es auf hellem und dunklem Hintergrund
lesbar ist.

## Grundprinzipien

- **Das PDF ist der Master.** Nummer, Datum, Titel, Beschreibung, Herkunft, Probleme und Seiten-Infos
  stehen *im* PDF (versteckte Anmerkung `/ScanArchiv` auf Seite 1 plus Dokumentinfos). Der Suchindex
  ist nur ein Cache und lässt sich jederzeit aus den PDFs neu aufbauen.
- **Originale bleiben, wo möglich, bitgenau erhalten.** Bei importierten PDFs werden Stempel, OCR-Text,
  Metadaten, Umsortierungen und Drehungen per **inkrementellem Update** angehängt (`PDFAppender`).
- **Zwei Schichten:** `ScanArchivCore` (Bibliothek, ohne UI, vollständig getestet) und `ScanArchiv`
  (SwiftUI-App: Oberfläche, Scanner, Eingangsordner).
- **Nummern werden nie wiederverwendet:** maßgeblich ist das Maximum aus `counter.json` und der höchsten
  Nummer im Archivordner.

---

## 1. Schichten und Außenwelt

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart TB
    subgraph APP["ScanArchiv – App (SwiftUI)"]
        direction TB
        Views["Views<br/>ScanView · InboxView · SearchView<br/>PDFPreviewPane · PageEditorSheet · SettingsView …"]
        Controller["Steuerung<br/>AppModel · ScanSession<br/>InboxService · ScannerService"]
        Views --> Controller
    end

    subgraph CORE["ScanArchivCore – Bibliothek"]
        direction TB
        Pipeline["Verarbeitung<br/>ImportProcessor · OCRService · Summarizer<br/>DateExtractor · FileDate · PageNumbering · BlankPage"]
        PDF["PDF-Erzeugung & -Änderung<br/>PDFBuilder · PDFStamper · PDFAppender<br/>PDFRaw · GlyphlessFont · PageCompressor"]
        Store["Ablage & Suche<br/>Archive · SearchIndex · TagStore · TagQuery<br/>DocumentMetadata · DocumentIssue · DocumentInfo"]
        Pipeline --> PDF
        Pipeline --> Store
        Store --> PDF
    end

    subgraph APPLE["macOS-Frameworks"]
        ICC["ImageCaptureCore<br/>(Scanner)"]
        Vision["Vision<br/>(OCR)"]
        FM["FoundationModels<br/>(Apple Intelligence)"]
        PDFKit["PDFKit / CoreGraphics"]
        SQLite["SQLite FTS5"]
    end

    subgraph FILES["Dateisystem"]
        ArchiveDir[("Archivordner<br/>JJJJ-MM-TT_NNNNNN_Titel.pdf<br/>counter.json<br/>.scanarchiv-index.sqlite<br/>.scanarchiv-tags.json")]
        InboxDir[("Eingangsordner<br/>+ Fehler/ + Duplikate/")]
    end

    Controller --> CORE
    Controller --> ICC
    Pipeline --> Vision
    Pipeline --> FM
    PDF --> PDFKit
    Store --> SQLite
    Store --> ArchiveDir
    Controller --> InboxDir
```

---

## 2. Module und ihre Beziehungen

### 2.1 App-Schicht

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart LR
    App["ScanArchivApp<br/>Tabs: Scannen · Eingang · Archiv"]

    subgraph Views
        ScanView
        PagePreviewView
        InboxView
        FolderImportSheet
        MultipleImagesSheet
        SearchView
        TagEditorSheet
        EditDocumentSheet["EditDocumentSheet<br/>(in SearchView)"]
        PageEditorSheet
        PDFPreviewPane
        SettingsView
    end

    AppModel["AppModel<br/>Archiv, Index, Tags,<br/>Einstellungen, revision"]
    ScanSession["ScanSession<br/>Scan-Ablauf, Vorschau,<br/>OCR-Cache, Vorschlag"]
    ScannerService["ScannerService<br/>ICDeviceBrowser,<br/>Einzug / Vorlagenglas"]
    InboxService["InboxService<br/>Ordnerüberwachung,<br/>Warteschlange"]

    App --> ScanView & InboxView & SearchView & SettingsView
    ScanView --> PagePreviewView
    ScanView --> ScanSession
    PagePreviewView --> ScanSession
    ScanSession --> ScannerService
    ScanSession --> AppModel
    InboxView --> InboxService
    InboxView --> FolderImportSheet & MultipleImagesSheet
    ScanView -. "Dateien ablegen" .-> InboxService
    InboxService --> AppModel
    SearchView --> AppModel
    SearchView --> PDFPreviewPane & TagEditorSheet & EditDocumentSheet & PageEditorSheet
    PageEditorSheet --> AppModel
    TagEditorSheet --> AppModel
    SettingsView --> AppModel & InboxService
```

| Modul | Aufgabe |
|---|---|
| `AppModel` | Öffnet Archiv, Suchindex und Tags; Einstellungen (`SettingsKey`); Bearbeiten, Seiten bearbeiten, „Als geprüft markieren“, „Titel erzeugen“; einmalige Migrationen beim Start; `revision` löst Neuladen der Listen aus |
| `ScanSession` | Zustandsautomat des Scans (Stapel zweiteilig oder Seite für Seite), Seitenmodell mit Drehung, automatische Ausrichtung, OCR im Hintergrund, Vorschlag von Titel/Beschreibung/Datum, Reihenfolge-Hinweis, Speichern |
| `ScannerService` | Findet Scanner (Bonjour/USB), öffnet die Sitzung, wechselt Einzug ↔ Vorlagenglas, liefert PNG-Seiten |
| `InboxService` | Überwacht den Eingangsordner, kopiert abgelegte Dateien hinein, verarbeitet die Warteschlange nacheinander, sortiert Fehler und Duplikate aus |
| `SearchView` / `PDFPreviewPane` | Trefferliste mit Tags und Problemfilter, Vorschau mit Suche, Info, Drucken, Teilen |
| `PageEditorSheet` | Seiten eines archivierten Dokuments umsortieren und drehen |

### 2.2 Core-Bibliothek

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart TB
    subgraph Verarbeitung
        ImportProcessor
        OCRService["OCRService<br/>Texterkennung + Ausrichtung"]
        Summarizer["Summarizer<br/>Titel · Beschreibung · Datum"]
        DateExtractor
        FileDate["FileDate<br/>Name · PDF · Dateisystem"]
        PageNumbering["PageNumbering<br/>Seitenreihenfolge"]
        BlankPage["BlankPage<br/>leere Seiten"]
        PageOrder["PageOrder<br/>Duplex verzahnen"]
        ImagesToPDF
        FolderScan
    end

    subgraph PDF_Schicht["PDF"]
        PDFBuilder["PDFBuilder<br/>neues PDF aus Bildern<br/>+ ImageTools"]
        PDFStamper["PDFStamper<br/>Neuschreiben mit PDFKit"]
        PDFAppender["PDFAppender<br/>inkrementelles Update"]
        PDFRaw["PDFRaw<br/>Parser + Writer"]
        GlyphlessFont["GlyphlessFont<br/>unsichtbare Textebene"]
        PageCompressor["PageCompressor<br/>JPEG / verlustfrei / 1-Bit"]
    end

    subgraph Ablage
        Archive["Archive<br/>Nummern, Dateinamen,<br/>Metadaten ändern, Seiten umsortieren"]
        SearchIndex["SearchIndex<br/>SQLite FTS5 + Wörterbuch"]
        TagStore
        TagQuery["TagQuery<br/>AND/OR/NOT, Platzhalter"]
        DocumentMetadata["DocumentMetadata<br/>+ PDFMetadata"]
        DocumentIssue["DocumentIssue<br/>Fehler / Hinweis"]
        DocumentInfo["DocumentInfo<br/>Info-Texte"]
    end

    ImportProcessor --> OCRService & Summarizer & DateExtractor & FileDate & PageNumbering & BlankPage
    ImportProcessor --> PDFAppender & PDFStamper & PDFBuilder & PageCompressor
    ImportProcessor --> Archive & SearchIndex
    Summarizer --> DateExtractor
    PDFAppender --> PDFRaw & GlyphlessFont & PDFBuilder
    PDFBuilder --> GlyphlessFont
    PDFStamper --> PDFBuilder
    Archive --> PDFAppender & DocumentMetadata & BlankPage
    SearchIndex --> TagQuery & DocumentMetadata & DocumentIssue
    DocumentMetadata --> DocumentIssue
    DocumentInfo --> DocumentMetadata & PageNumbering
```

| Modul | Aufgabe |
|---|---|
| `ImportProcessor` | Ein PDF oder Bild archivieren: Text übernehmen oder OCR, leere Seiten, Reihenfolge, Vorschlag, Datum, bis zu drei Fassungen erzeugen, prüfen, kleinste speichern, indexieren |
| `OCRService` | Vision-Texterkennung (de/en) auf eigener serieller Queue; Ausrichtung per schneller OCR in vier Richtungen |
| `Summarizer` | Apple Intelligence (lokal): Titel, Beschreibung, Datum, Absender und Kategorien aus den ersten zwei Seiten |
| `Categories` | Kategorien als Pfade („Absender/DAK“): Startliste, Normalisieren an vorhandene, Oberkategorien, Umbenennen |
| `PDFBuilder` | Neues PDF aus Seitenbildern mit unsichtbarer Textebene und rotem Stempel (Scans, Bilder, komprimierte Fassung) |
| `PDFStamper` | Vorhandenes PDF über PDFKit neu schreiben (Alternative, falls kleiner) |
| `PDFAppender` | Stempel, Textebene, Metadaten, neue Reihenfolge und Drehung **anhängen**; Original bleibt bitgenau |
| `PDFRaw` | Eigener PDF-Parser (Querverweistabellen und -Streams, Objekt-Streams) und Writer für inkrementelle Updates |
| `Archive` | Ordner mit fortlaufender Nummer; Speichern, Umbenennen, Metadaten ändern, Seiten umsortieren, Altbestand migrieren |
| `SearchIndex` | Volltextsuche (Wortanfänge, alle Wörter UND), Tag-Filter, Kategorienfilter und -zahlen, Problemfilter, Duplikaterkennung per SHA-256, Neuaufbau aus den PDFs |

---

## 3. Datenhaltung

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart LR
    subgraph PDFDatei["Archiv-PDF (Master)"]
        Inhalt["Seiteninhalt<br/>+ unsichtbare OCR-Textebene"]
        Stempel["roter Stempel<br/>Nr. 000123 · TT.MM.JJJJ"]
        Anm["versteckte Anmerkung /ScanArchiv<br/>JSON: DocumentMetadata"]
        Info["Dokumentinfos<br/>Titel · Betreff · Stichwörter"]
    end

    Index[(".scanarchiv-index.sqlite<br/>FTS5: Nummer, Datum, Pfad, Titel,<br/>Beschreibung, Text, Probleme, Metadaten")]
    Tags[(".scanarchiv-tags.json<br/>gespeicherte Suchen")]
    Counter[("counter.json<br/>letzte Nummer")]

    Anm -- "sync / Neuaufbau" --> Index
    Inhalt -- "Text je Seite" --> Index
    Tags -- "Filter (UND)" --> Index
    Counter -. "max(Zähler, höchste Datei-Nr.) + 1" .-> Stempel
```

`DocumentMetadata` enthält u. a.: Nummer, Dokumentdatum und dessen Herkunft, Titel-Herkunft, Archivierungszeit,
Quelle (Scan/PDF/Bild), Originalname/-größe/-SHA-256, Scan-Einstellungen, Kompression, Textherkunft je Seite
(`embedded`, `ocr`, `none`, `blank`), OCR-Infos, Probleme, Speicherart (`appended`, `rewritten`, `rebuilt`,
`created`), ggf. `pageOrder` und die Programmversionen.

---

## 4. Abläufe

### 4.1 Stapel scannen (zweiteilig, Vorder- und Rückseiten)

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart TD
    A([Tab „Scannen“]) --> B["Stapel scannen"]
    B --> C["ScannerService.scan(Einzug)<br/>Vorderseiten → PNG"]
    C --> D{Seiten gescannt?}
    D -- nein --> X1[/"Fehler: Papier im Einzug?"/]
    D -- ja --> E["Hinweis: Stapel wenden"]
    E --> F{Beidseitig?}
    F -- "Nur einseitig" --> P
    F -- "Rückseiten scannen" --> G["ScannerService.scan(Einzug)<br/>Rückseiten (umgekehrt)"]
    G --> H{Anzahl gleich?}
    H -- nein --> H2{"Trotzdem zusammenführen /<br/>erneut scannen / abbrechen"}
    H2 -- erneut --> G
    H2 -- zusammenführen --> I
    H -- ja --> I["PageOrder.interleave<br/>V1 R1 V2 R2 …"]
    I --> P["Vorschau (PagePreviewView)"]
    P --> Q
    subgraph Hintergrund["Analyse im Hintergrund"]
        Q["je Seite: Ausrichtung erkennen<br/>(OCRService.detectOrientation)"] --> R["OCR in aktueller Drehung<br/>(Cache)"]
        R --> S["erste 2 Seiten: Datum (DateExtractor)<br/>+ Titel/Beschreibung/Datum (Summarizer)"]
        R --> T["alle Seiten fertig:<br/>PageNumbering → Reihenfolge-Hinweis"]
    end
    P --> U{"Benutzer"}
    U -- "drehen / ziehen / entfernen<br/>Seite nachscannen" --> P
    U -- "Speichern" --> V["siehe 4.3 Scan speichern"]
    U -- "Verwerfen" --> A
```

### 4.2 Seite für Seite scannen

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart TD
    A([Tab „Scannen“]) --> B["„Seite für Seite …“<br/>Quelle: Vorlagenglas oder Einzug"]
    B --> C["ScannerService.scan(Quelle)<br/>ggf. Wechsel Einzug ↔ Glas"]
    C --> D{Erfolg?}
    D -- nein --> E[/"Fehlermeldung<br/>bisherige Seiten bleiben"/]
    D -- ja --> F["Seite anhängen<br/>Analyse startet im Hintergrund"]
    E --> G
    F --> G{"Noch eine Seite?"}
    G -- "Nächste Seite scannen" --> C
    G -- "Letzte Seite wiederholen" --> H["letzte Seite entfernen"] --> C
    G -- "Fertig" --> I["Vorschau (wie 4.1)"]
    G -- "Alles verwerfen" --> A
```

### 4.3 Scan speichern

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
sequenceDiagram
    actor U as Benutzer
    participant S as ScanSession
    participant O as OCRService
    participant C as PageCompressor
    participant B as PDFBuilder
    participant A as Archive
    participant I as SearchIndex

    U->>S: Speichern
    loop jede Seite
        S->>O: Ausrichtung + OCR (falls noch nicht im Cache)
    end
    S->>S: PageNumbering – Hinweis noch nicht gezeigt?
    alt Reihenfolge verdächtig und Hinweis neu
        S-->>U: zurück zur Vorschau mit gelber Leiste
    else in Ordnung / Benutzer hat entschieden
        loop jede Seite
            S->>S: kein Text? → BlankPage: leer (ok) oder „kein Text“ (Problem)
            S->>C: komprimieren (Größe/Farbe aus Einstellungen)
        end
        S->>A: save(date, title) { Nummer → PDF }
        A->>B: build(Seiten, Nummer, Datum) + Stempel + Textebene
        B-->>A: PDF-Daten
        A->>A: PDFMetadata.finalize (Metadaten ins PDF)
        A-->>S: Nummer, Datei-URL
        S->>I: add(Text, Titel, Beschreibung, Metadaten)
        S-->>U: „Gespeichert als …“
    end
```

### 4.4 Import über den Eingang

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart TD
    A1(["Dateien/Ordner auf „Eingang“ oder „Scannen“ ziehen"]) --> A2{Was wurde abgelegt?}
    A2 -- Ordner --> A3["FolderImportSheet<br/>Unterordner? PDFs? Bilder?"] --> A5
    A2 -- "mehrere Bilder" --> A4{"MultipleImagesSheet<br/>zu einem PDF verbinden?"}
    A4 -- ja --> A4b["ImagesToPDF.combine<br/>Datei-Datum = frühestes Bild"] --> A6
    A4 -- nein --> A5
    A2 -- "einzelne Dateien" --> A5["in den Eingangsordner kopieren"]
    A5 --> A6[("Eingangsordner")]
    W(["Ordnerüberwachung<br/>DispatchSource + 30-s-Timer"]) --> A6
    A6 --> Q["Warteschlange<br/>(Datei stabil seit 2 s)"]
    Q --> P["ImportProcessor.process<br/>(eine Datei nach der anderen)"]
    P --> R{Ergebnis}
    R -- "archiviert" --> T1["Original in den Papierkorb"]
    R -- "Duplikat (SHA-256 bekannt)" --> T2["→ Duplikate/"]
    R -- "nicht lesbar / nicht unterstützt" --> T3["→ Fehler/"]
    T1 --> L["Liste im Tab „Eingang“<br/>grün / gelb / rot"]
    T2 --> L
    T3 --> L
```

### 4.5 ImportProcessor im Detail

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart TD
    S([Datei]) --> H["SHA-256 → schon im Index?"]
    H -- ja --> DUP[/Duplikat/]
    H -- nein --> K{PDF oder Bild?}

    K -- PDF --> P1["Text je Seite (PDFKit)"]
    P1 --> P2{"Seite hat Text?"}
    P2 -- ja --> P3["übernehmen (embedded)"]
    P2 -- nein --> P4["rendern (300 dpi) → OCR"]
    P4 --> P5{"Text erkannt?"}
    P5 -- ja --> P6["ocr"]
    P5 -- nein --> P7{"BlankPage leer?"}
    P7 -- ja --> P8["blank – kein Problem"]
    P7 -- nein --> P9["none – Problem „kein Text“ (rot)"]
    P3 & P6 & P8 & P9 --> N["PageNumbering.analyze"]
    N -- eindeutig falsch --> N1["umsortieren +<br/>Hinweis „korrigiert“ (gelb)"]
    N -- unklar --> N2["Hinweis „prüfen“ (gelb)"]
    N -- ok --> V
    N1 --> V
    N2 --> V

    K -- Bild --> B1["OCR → ocr / blank / none"] --> V

    V["Vorschlag: Summarizer (erste 2 Seiten)"] --> D{"Datum"}
    D -- "im Text (KI / DateExtractor)" --> F
    D -- "sonst Datei: Name → PDF-Erstelldatum → Dateisystem" --> F
    D -- "sonst heute + Problem „kein Datum“" --> F
    F["Archive.save: nächste Nummer"] --> C["Fassungen erzeugen"]
    C --> C1["angehängt (PDFAppender)<br/>Original bitgenau"]
    C --> C2["neu geschrieben (PDFStamper)"]
    C --> C3["neu erzeugt + komprimiert (PDFBuilder)<br/>nur wenn Bildseiten und Kompression an"]
    C1 & C2 & C3 --> VAL["prüfen: Seitenzahl, Text, Stempel,<br/>Metadaten, Reihenfolge"]
    VAL --> MIN["kleinste gültige Fassung speichern<br/>(Speicherart in den Metadaten)"]
    MIN --> IDX["SearchIndex.add"]
```

### 4.6 Suchen, Kategorien, Tags und Vorschau

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart TD
    A([Tab „Archiv“]) --> B["Suchfeld<br/>alle Wörter UND, Wortanfänge"]
    A --> T["Tags (gespeicherte Suchen)<br/>z. B. (Rente AND DRV) OR Rentenversicherung"]
    A --> K["Kategorien (im PDF)<br/>z. B. Absender › DAK, Rechnung"]
    A --> F["„Nur mit Problemen“"]
    B & T & K & F --> Q["SearchIndex.search<br/>Suchfeld AND Tags AND Kategorien"]
    T --> TQ["TagQuery → FTS5-Ausdruck<br/>*rente über Wörterbuch (fts5vocab)"] --> Q
    Q --> L["Trefferliste<br/>rot = Fehler, gelb = Hinweis"]
    L -- Auswahl --> V["PDFPreviewPane<br/>Suchbegriff vorbelegt, Treffer markiert<br/>(Tag-Wörter werden nie markiert)"]
    L -- Doppelklick --> O["in Vorschau.app öffnen"]
    V --> V1["ⓘ Info (DocumentInfo)"]
    V --> V2["Drucken (⌘P)"]
    V --> V3["Teilen (Mail, AirDrop …)"]
    L -- Rechtsklick --> M{"Kontextmenü"}
    M --> M1["Bearbeiten … → 4.7"]
    M --> M2["Seiten bearbeiten … / Reihenfolge prüfen … → 4.8"]
    M --> M3["Als geprüft markieren"]
    M --> M4["Drucken … / Im Finder zeigen"]
    M --> M5["Löschen … → Papierkorb<br/>(Nummer wird nicht neu vergeben)"]
```

### 4.7 Datum, Titel, Beschreibung bearbeiten

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart LR
    A["Bearbeiten …"] --> B["AppModel.updateDocument"]
    B --> C["Archive.updateMetadata"]
    C --> D{"PDFAppender.updateMetadata<br/>(anhängen) klappt?"}
    D -- ja --> E["Metadaten + Dokumentinfos angehängt"]
    D -- nein --> E2["Fallback: PDFKit schreibt neu"]
    E & E2 --> F["Datei umbenennen<br/>JJJJ-MM-TT_NNNNNN_Titel.pdf"]
    F --> G["SearchIndex.update"]
    G --> H["erledigte Probleme entfernt<br/>(Titel gesetzt, Datum bestätigt)"]
```

### 4.8 Seiten bearbeiten (Reihenfolge / Drehung)

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart TD
    A["Seiten bearbeiten … /<br/>Reihenfolge prüfen …"] --> B["PageEditorSheet<br/>Miniaturen, Größenregler"]
    B --> C{"Benutzer"}
    C -- "ziehen / drehen /<br/>„Wie im Original“" --> B
    C -- "Sichern ohne Änderung" --> D["Reihenfolge bestätigt:<br/>nur Hinweis entfernen"]
    C -- "Sichern mit Änderung" --> E["Archive.rearrange"]
    E --> F["PDFAppender.rearrange (anhängen)<br/>• neuer flacher Seitenbaum<br/>• Rotate je Seite<br/>• alter Stempel weiß überdeckt<br/>• Stempel + Metadaten auf neuer Seite 1"]
    F --> G{"Prüfung: Seitenzahl, Stempel,<br/>Metadaten, Text je Seite"}
    G -- fehlgeschlagen --> H[/"Fehlermeldung, Datei unverändert"/]
    G -- ok --> I["Datei ersetzen · Index-Text erneuern<br/>Vorschau neu laden"]
```

### 4.9 Programmstart und Index-Abgleich

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart TD
    A([Start]) --> B["AppModel.openArchive<br/>Archive · SearchIndex · TagStore"]
    B --> C["InboxService.start<br/>Ordner überwachen, liegende Dateien einreihen"]
    B --> D["reindex (Hintergrund)"]
    D --> D1["einmalig: Altbestand reparieren<br/>(legacyRepairV1)"]
    D1 --> D2["SearchIndex.sync<br/>neue/geänderte PDFs einlesen,<br/>gelöschte entfernen"]
    D2 --> D3["einmalig je Archiv: leere Seiten<br/>nachprüfen (blankPagesV2)"]
    D3 --> D4["revision + 1 → Listen neu laden"]
```

### 4.10 Titel erzeugen (Stapel)

```mermaid
%%{init: {"theme": "base", "themeVariables": {"lineColor": "#7f9cd6", "primaryColor": "#eef2fa", "primaryTextColor": "#1d2433", "primaryBorderColor": "#7f9cd6", "secondaryColor": "#f3f0fa", "tertiaryColor": "#f6f8fc", "clusterBkg": "#f6f8fc", "clusterBorder": "#7f9cd6", "titleColor": "#1d2433", "edgeLabelBackground": "#ffffff", "textColor": "#1d2433", "signalColor": "#7f9cd6", "signalTextColor": "#7f9cd6", "actorBkg": "#eef2fa", "actorBorder": "#7f9cd6", "actorTextColor": "#1d2433", "actorLineColor": "#7f9cd6", "labelBoxBkgColor": "#eef2fa", "labelTextColor": "#1d2433", "loopTextColor": "#7f9cd6", "noteBkgColor": "#fff7d6", "noteTextColor": "#1d2433"}, "themeCSS": ".flowchart-link, .messageLine0, .messageLine1, .actor-line { stroke-width: 2px !important; }"}}%%
flowchart LR
    A["„Titel erzeugen“ im Archiv"] --> B["SearchIndex: Dokumente ohne Titel"]
    B --> C["je Dokument: Text der ersten Seiten<br/>→ Summarizer (Titel, Beschreibung, Datum)"]
    C --> D["AppModel.updateDocument<br/>Titel-Herkunft: KI, Datum nur falls erkannt"]
    D --> E["Datei umbenannt, Index aktualisiert,<br/>Problem „kein Titel“ entfernt"]
```
