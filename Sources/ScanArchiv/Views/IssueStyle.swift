import ScanArchivCore
import SwiftUI

/// Darstellung der Probleme: Fehler rot, Hinweise gelb (als Orange – reines Gelb ist auf Weiß kaum lesbar).
extension DocumentIssue.Severity {
    var color: Color { self == .error ? .red : .orange }
    var symbol: String { self == .error ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill" }
}

extension DocumentIssue {
    var color: Color { severity.color }
    var symbol: String { severity.symbol }
}

extension Array where Element == DocumentIssue {
    /// Farbe nach dem schwersten Problem; ohne Probleme die normale Textfarbe.
    var color: Color { maxSeverity?.color ?? .primary }
    var symbol: String { maxSeverity?.symbol ?? "checkmark.circle.fill" }
}
