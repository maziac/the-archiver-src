import Foundation

public enum PageOrder {
    /// Führt zwei einseitige Scan-Durchgänge zur Originalreihenfolge zusammen.
    ///
    /// Durchgang 1 liefert die Vorderseiten V1…Vn. Danach wird der Stapel als Ganzes
    /// umgedreht, daher liefert Durchgang 2 die Rückseiten in umgekehrter Folge Rn…R1.
    /// Ergebnis: V1, R1, V2, R2, …, Vn, Rn.
    ///
    /// Bei ungleicher Anzahl werden überzählige Seiten hinten angehängt.
    public static func interleave<T>(fronts: [T], backsScannedReversed backs: [T]) -> [T] {
        let backsInOrder = Array(backs.reversed())
        var result: [T] = []
        result.reserveCapacity(fronts.count + backs.count)
        for (front, back) in zip(fronts, backsInOrder) {
            result.append(front)
            result.append(back)
        }
        let paired = min(fronts.count, backsInOrder.count)
        result.append(contentsOf: fronts.dropFirst(paired))
        result.append(contentsOf: backsInOrder.dropFirst(paired))
        return result
    }
}
