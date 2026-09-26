import Foundation

/// Kategorien eines Dokuments: Pfade mit „/“, z. B. „Absender/DAK“ oder „Rechnung“.
/// Anders als Tags stehen sie im Dokument (`DocumentMetadata.categories`).
public enum Categories {
    /// Wurzel für Absender („Absender/DAK“)
    public static let senderRoot = "Absender"
    public static let separator: Character = "/"

    /// Startliste: Arten und Themen, die Apple Intelligence bevorzugt
    public static let defaults = [
        "Rechnung", "Bescheid", "Vertrag", "Kündigung", "Mahnung", "Kontoauszug", "Lohnabrechnung",
        "Krankenkasse", "Rente", "Versicherung", "Steuer", "Bank", "Wohnen", "Arzt", "Auto",
    ]

    /// Bedeutung der Startkategorien – steht im Prompt, damit das Modell sie nicht zu weit auslegt.
    public static let descriptions: [String: String] = [
        "Rechnung": "Zahlungsaufforderung für eine Ware oder Leistung mit Betrag",
        "Bescheid": "amtliche Entscheidung einer Behörde oder Kasse (z. B. Steuer-, Renten-, Beitragsbescheid)",
        "Vertrag": "Vertrag, Vertragsänderung oder Vertragsbestätigung",
        "Kündigung": "Kündigung oder Kündigungsbestätigung",
        "Mahnung": "Zahlungserinnerung oder Mahnung",
        "Kontoauszug": "Kontoauszug, Depotauszug oder Umsatzübersicht",
        "Lohnabrechnung": "Lohn-, Gehalts- oder Bezügeabrechnung",
        "Krankenkasse": "Schreiben einer gesetzlichen oder privaten Krankenkasse bzw. Pflegekasse",
        "Rente": "gesetzliche, betriebliche oder private Altersvorsorge und Rente",
        "Versicherung": "Versicherungen außer Krankenkasse (Haftpflicht, Hausrat, Kfz, Leben …)",
        "Steuer": "Finanzamt, Steuererklärung, steuerlich relevante Bescheinigungen",
        "Bank": "Girokonto, Kredit, Karte, Geldanlage",
        "Wohnen": "nur die eigene Wohnung oder das Haus selbst: Miete, Mietvertrag, Nebenkostenabrechnung, Hausverwaltung, "
            + "Eigentümergemeinschaft, Kauf, Grundsteuer; nicht Strom, Gas, Internet, Telefon, Rundfunkbeitrag oder Versicherungen",
        "Arzt": "Arztbrief, Befund, Rezept, Arzt- oder Zahnarztrechnung",
        "Auto": "Fahrzeug: Kauf, Werkstatt, Zulassung, TÜV, Kfz-Steuer",
    ]

    /// Bekanntes Vokabular: Startliste und die im Archiv vergebenen Kategorien, sortiert.
    public static func vocabulary(existing: [String]) -> [String] {
        Set(defaults).union(existing).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Themen der Startliste, die nur bleiben, wenn der Text eines dieser Wortstücke enthält
    /// (klein, ohne Umlaute). Das Modell ordnet sonst z. B. den Rundfunkbeitrag „Wohnen“ zu.
    static let evidence: [String: [String]] = [
        "Wohnen": ["miet", "nebenkosten", "betriebskosten", "hausverwaltung", "hausgeld", "eigentumer", "wohnungseigentum",
                   "grundsteuer", "kaution", "wohnungsgeber", "vermiet", "immobilie", "grundbuch", "notar"],
        "Krankenkasse": ["krankenkasse", "krankenversicherung", "pflegekasse", "pflegeversicherung", "aok", "dak", "barmer",
                         "ikk", "bkk", "techniker", "gesundheitskarte", "versichertennummer", "krankenversichertennummer"],
        "Rente": ["rente", "renten", "altersvorsorge", "versorgungswerk", "pension", "ruhestand"],
        "Versicherung": ["versicherung", "versicherer", "versicherungsschein", "police"],
        "Steuer": ["steuer", "finanzamt"],
        "Bank": ["bank", "sparkasse", "konto", "kredit", "darlehen", "depot", "volksbank"],
        "Arzt": ["arzt", "arztin", "praxis", "befund", "diagnose", "klinik", "krankenhaus", "rezept", "zahn", "therapie"],
        "Auto": ["fahrzeug", "kfz", "kennzeichen", "auto", "werkstatt", "zulassung", "tuv", "hauptuntersuchung", "pkw"],
    ]

    /// Entfernt Themen, für die der Text keinen Anhaltspunkt enthält (siehe `evidence`).
    public static func verified(_ categories: [String], text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
        return categories.filter { category in
            guard let words = evidence[category] else { return true }
            return words.contains { folded.contains($0) }
        }
    }

    /// Säubert einen einzelnen Namen (ohne „/“, Leerraum zusammengefasst, ohne Anführungszeichen).
    static func cleanName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'„“”.,;:")))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Säubert einen Pfad („ Absender / DAK “ → „Absender/DAK“); leer, wenn nichts übrig bleibt.
    public static func cleanPath(_ path: String) -> String {
        path.split(separator: separator).map { cleanName(String($0)) }.filter { !$0.isEmpty }
            .joined(separator: String(separator))
    }

    /// Vergleichsschlüssel: klein, ohne Akzente, einfache deutsche Pluralendungen entfernt.
    static func key(_ name: String) -> String {
        var folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
            .lowercased()
        for suffix in ["en", "n", "s", "e"] where folded.count > suffix.count + 3 && folded.hasSuffix(suffix) {
            folded.removeLast(suffix.count)
            break
        }
        return folded
    }

    /// Erstes Wort (für den Absender-Abgleich „DAK-Gesundheit“ ↔ „DAK“)
    static func firstWord(_ name: String) -> String {
        let word = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).first.map(String.init) ?? name
        return word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// Bekannte Absender (Namen unter „Absender/“)
    public static func senders(in known: [String]) -> [String] {
        let prefix = senderRoot + String(separator)
        return known.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// Macht aus dem Vorschlag des Modells eine saubere Liste und gleicht die Schreibweise an vorhandene
    /// Kategorien an. Der Absender wird zu „Absender/<Name>“.
    /// - Zusammengesetzte Wörter gehen in der bekannten Kategorie auf („Stromrechnung“ → „Rechnung“).
    /// - Begriffe, die nur den Absender wiederholen („Stadtwerke“), fallen weg.
    /// - Höchstens eine neue (unbekannte) Kategorie, damit das Vokabular nicht ausufert.
    public static func normalize(_ raw: [String], sender: String?, known: [String]) -> [String] {
        let knownByKey = Dictionary(known.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        // Endungen für Komposita: nur einteilige Kategorien mit mindestens 4 Buchstaben, längste zuerst
        let compoundTargets = known.filter { !$0.contains(separator) && $0.count >= 4 }
            .sorted { $0.count > $1.count }
        let senderWords = Set((sender ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map { key(String($0)) })
        var result: [String] = []
        var newCount = 0
        for entry in raw {
            let path = cleanPath(entry)
            guard !path.isEmpty else { continue }
            if path.split(separator: separator).first.map({ key(String($0)) }) == key(senderRoot) { continue }  // Absender kommt extra
            if let known = knownByKey[key(path)] {
                result.append(known)
                continue
            }
            let pathKey = key(path)
            if !path.contains(separator),
               let target = compoundTargets.first(where: { pathKey.count > key($0).count && pathKey.hasSuffix(key($0)) }) {
                result.append(target)
                continue
            }
            // wiederholt nur den Absender („Stadtwerke“, „Stadtwerke München“)
            let pathWords = path.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map { key(String($0)) }
            if !senderWords.isEmpty, pathWords.allSatisfy(senderWords.contains) { continue }
            if newCount < 1 {
                result.append(path)
                newCount += 1
            }
        }
        if let sender {
            let name = cleanName(sender)
            if !name.isEmpty {
                let knownSenders = senders(in: known)
                let match = knownSenders.first { key($0) == key(name) }
                    ?? knownSenders.first { firstWord($0) == firstWord(name) && firstWord(name).count >= 3 }
                result.append(senderRoot + String(separator) + (match ?? name))
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert(key($0)).inserted }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Jede Kategorie samt Oberkategorien: „Absender/DAK“ → „Absender“, „Absender/DAK“.
    public static func expanded(_ categories: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for category in categories {
            let parts = category.split(separator: separator)
            for n in parts.indices {
                let path = parts[...n].joined(separator: String(separator))
                if seen.insert(path).inserted { result.append(path) }
            }
        }
        return result
    }

    /// Inhalt der Indexspalte: "\nA\nA/B\n" (nil = noch nicht kategorisiert)
    static func indexField(_ categories: [String]?) -> String? {
        guard let categories else { return nil }
        let all = expanded(categories)
        return all.isEmpty ? "" : "\n" + all.joined(separator: "\n") + "\n"
    }

    /// Letzter Teil eines Pfades („Absender/DAK“ → „DAK“)
    public static func leaf(_ path: String) -> String {
        path.split(separator: separator).last.map(String.init) ?? path
    }

    /// Oberkategorie („Absender/DAK“ → „Absender“, „Rechnung“ → nil)
    public static func parent(_ path: String) -> String? {
        guard let i = path.lastIndex(of: separator) else { return nil }
        return String(path[..<i])
    }

    /// Anzeige „Absender › DAK“
    public static func display(_ path: String) -> String {
        path.split(separator: separator).joined(separator: " › ")
    }

    /// Umbenennen inkl. Unterpfaden; nil = Kategorie nicht betroffen.
    public static func renamed(_ categories: [String], from old: String, to new: String?) -> [String]? {
        var changed = false
        var result: [String] = []
        for category in categories {
            if category == old || category.hasPrefix(old + String(separator)) {
                changed = true
                if let new, !new.isEmpty { result.append(new + category.dropFirst(old.count)) }
            } else {
                result.append(category)
            }
        }
        guard changed else { return nil }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
