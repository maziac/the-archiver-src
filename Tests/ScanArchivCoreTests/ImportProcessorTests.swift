import AppKit
import Foundation
import PDFKit
import Testing
@testable import ScanArchivCore

struct ImportProcessorTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ImportTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    let helpers = PDFStamperTests()

    func makeEnv() throws -> (Archive, SearchIndex, IssueStore) {
        let archiveFolder = folder.appendingPathComponent("archiv")
        let archive = try Archive(folder: archiveFolder)
        return (archive, try SearchIndex(url: archiveFolder.appendingPathComponent(SearchIndex.fileName)), IssueStore(folder: archiveFolder))
    }

    func process(_ file: URL, _ env: (Archive, SearchIndex, IssueStore), ai: Bool = false) async throws -> ImportResult {
        try await ImportProcessor.process(file: file, archive: env.0, index: env.1, issueStore: env.2, useSummarizer: ai)
    }

    /// Weißes Bild ohne Text als PDF
    func makeBlankImagePDF() -> URL {
        let url = folder.appendingPathComponent("leer.pdf")
        let ctx = CGContext(data: nil, width: 620, height: 877, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 620, height: 877))
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let pdf = CGContext(url as CFURL, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        pdf.draw(ctx.makeImage()!, in: box)
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }

    @Test func textPDFIsArchivedUnchanged() async throws {
        let env = try makeEnv()
        let result = try await process(helpers.makeTextPDF(), env)
        #expect(result.number == 1)
        let pdf = try #require(PDFDocument(url: result.url))
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 0)?.string?.contains("Online-Rechnung Telekom") == true)
        #expect(pdf.page(at: 0)?.string?.contains("Nr. 000001") == true)
        #expect(try env.1.search("telekom").map(\.number) == [1])
    }

    @Test func imagePDFGetsOCR() async throws {
        let env = try makeEnv()
        let result = try await process(helpers.makeImagePDF(), env)
        #expect(PDFDocument(url: result.url)?.string?.contains("Mahnung Finanzamt") == true)
        #expect(!result.issues.contains { if case .noText = $0 { return true }; return false })
    }

    @Test func pngBecomesPDF() async throws {
        let env = try makeEnv()
        let png = folder.appendingPathComponent("scan.png")
        try ImageTools.writePNG(PDFBuilderTests.renderPage("Kaufvertrag vom 03.05.2025"), to: png)
        let result = try await process(png, env)
        let pdf = try #require(PDFDocument(url: result.url))
        #expect(pdf.pageCount == 1)
        #expect(pdf.string?.contains("Kaufvertrag") == true)
        #expect(Archive.formatDate(result.date) == "2025-05-03")
        #expect(!result.issues.contains(.noDate))
    }

    @Test func brokenAndUnsupportedFilesThrow() async throws {
        let env = try makeEnv()
        let broken = folder.appendingPathComponent("kaputt.pdf")
        try Data("kein pdf".utf8).write(to: broken)
        await #expect(throws: ImportError.self) { try await process(broken, env) }
        let docx = folder.appendingPathComponent("brief.docx")
        try Data("x".utf8).write(to: docx)
        await #expect(throws: ImportError.self) { try await process(docx, env) }
        #expect(env.0.peekNextNumber() == 1)  // keine Nummer verbraucht
    }

    @Test func issuesAreRecorded() async throws {
        let env = try makeEnv()
        let result = try await process(makeBlankImagePDF(), env)
        #expect(result.issues.contains(.noText(pages: [1])))
        #expect(result.issues.contains(.noDate))
        #expect(result.issues.contains { if case .noSuggestion = $0 { return true }; return false })
        // dauerhaft gespeichert und im Index filterbar
        #expect(IssueStore(folder: env.0.folder).issues(for: result.number) == result.issues)
        #expect(try env.1.search("", onlyIssues: true).map(\.number) == [result.number])
        #expect(try env.1.countWithIssues() == 1)
    }

    @Test(.enabled(if: Summarizer.isAvailable, "Apple Intelligence nicht verfügbar"))
    func withAppleIntelligence() async throws {
        let env = try makeEnv()
        let png = folder.appendingPathComponent("rechnung.png")
        try ImageTools.writePNG(PDFBuilderTests.renderPage("Rechnung Stadtwerke 18.09.2026"), to: png)
        let result = try await process(png, env, ai: true)
        #expect(!result.title.isEmpty)
        #expect(result.url.lastPathComponent.hasPrefix("2026-09-18_000001_"))
    }
}

struct IssueStoreTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Issues-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test func persistAndRemove() throws {
        let store = IssueStore(folder: folder)
        try store.set([.noDate, .noText(pages: [2, 3])], for: 7)
        #expect(IssueStore(folder: folder).issues(for: 7) == [.noDate, .noText(pages: [2, 3])])
        let remaining = try store.remove(for: 7) { $0 == .noDate }
        #expect(remaining == [.noText(pages: [2, 3])])
        try store.set([], for: 7)
        #expect(IssueStore(folder: folder).all.isEmpty)
    }

    @Test func messages() {
        #expect(DocumentIssue.noText(pages: [2]).message == "Seite 2: kein Text erkannt")
        #expect(DocumentIssue.noText(pages: [2, 3]).message == "Seiten 2, 3: kein Text erkannt")
    }

    @Test func indexUpdateAndSync() throws {
        let index = try SearchIndex(url: folder.appendingPathComponent("idx.sqlite"))
        try index.add(number: 5, date: Date(), url: folder.appendingPathComponent("x.pdf"), pages: 1, text: "Text", issues: [.noDate])
        #expect(try index.search("", onlyIssues: true).first?.issues == [.noDate])
        try index.setIssues([], number: 5)
        #expect(try index.search("", onlyIssues: true).isEmpty)
        #expect(try index.search("text").count == 1)
    }
}
