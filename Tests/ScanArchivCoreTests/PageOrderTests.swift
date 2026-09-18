import Testing
@testable import ScanArchivCore

struct PageOrderTests {
    @Test func interleavesReversedBacks() {
        // Vorderseiten V1..V3, Rückseiten kommen umgekehrt: R3, R2, R1
        let result = PageOrder.interleave(fronts: ["V1", "V2", "V3"], backsScannedReversed: ["R3", "R2", "R1"])
        #expect(result == ["V1", "R1", "V2", "R2", "V3", "R3"])
    }

    @Test func singleSheet() {
        #expect(PageOrder.interleave(fronts: ["V1"], backsScannedReversed: ["R1"]) == ["V1", "R1"])
    }

    @Test func simplexWithoutBacks() {
        #expect(PageOrder.interleave(fronts: ["V1", "V2"], backsScannedReversed: [String]()) == ["V1", "V2"])
    }

    @Test func mismatchKeepsAllPages() {
        let result = PageOrder.interleave(fronts: ["V1", "V2", "V3"], backsScannedReversed: ["R2", "R1"])
        #expect(result == ["V1", "R1", "V2", "R2", "V3"])
    }
}
