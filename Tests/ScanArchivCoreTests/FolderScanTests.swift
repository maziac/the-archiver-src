import Foundation
import Testing
@testable import ScanArchivCore

struct FolderScanTests {
    /// Ordner mit PDF, Bild, Unterordner und Dateien, die ignoriert werden müssen
    func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderScan-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("Unterordner/Tiefer")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for (path, content) in [("a.pdf", "x"), ("b.JPG", "x"), ("c.docx", "x"), (".versteckt.pdf", "x"),
                                ("Unterordner/d.pdf", "x"), ("Unterordner/Tiefer/e.png", "x"), ("Unterordner/f.txt", "x")] {
            try Data(content.utf8).write(to: root.appendingPathComponent(path))
        }
        return root
    }

    @Test func withSubfolders() throws {
        let root = try makeTree()
        let result = FolderScan.files(in: [root], options: .init(includeSubfolders: true, pdf: true, images: true))
        #expect(result.pdfs.map(\.lastPathComponent).sorted() == ["a.pdf", "d.pdf"])
        #expect(result.images.map(\.lastPathComponent).sorted() == ["b.JPG", "e.png"])
    }

    @Test func topLevelOnlyAndTypeFilter() throws {
        let root = try makeTree()
        let onlyTop = FolderScan.files(in: [root], options: .init(includeSubfolders: false, pdf: true, images: true))
        #expect(onlyTop.all.map(\.lastPathComponent) == ["a.pdf", "b.JPG"])
        let onlyImages = FolderScan.files(in: [root], options: .init(includeSubfolders: true, pdf: false, images: true))
        #expect(onlyImages.pdfs.isEmpty)
        #expect(onlyImages.images.count == 2)
        #expect(FolderScan.files(in: [root], options: .init(pdf: false, images: false)).all.isEmpty)
    }

    @Test func detectsDirectoryWithoutTrailingSlash() throws {
        let root = try makeTree()
        #expect(FolderScan.isDirectory(URL(fileURLWithPath: root.path, isDirectory: false)))
        #expect(!FolderScan.isDirectory(root.appendingPathComponent("a.pdf")))
    }

    @Test func overlappingFoldersCountOnce() throws {
        let root = try makeTree()
        let result = FolderScan.files(in: [root, root.appendingPathComponent("Unterordner")], options: .init())
        #expect(result.all.count == 4)
    }
}
