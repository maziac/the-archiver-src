import Foundation
import UniformTypeIdentifiers

/// Sucht importierbare Dateien in Ordnern (für „Ordner in den Eingang ziehen“).
public enum FolderScan {
    public struct Options: Equatable, Sendable {
        public var includeSubfolders: Bool
        public var pdf: Bool
        public var images: Bool

        public init(includeSubfolders: Bool = true, pdf: Bool = true, images: Bool = true) {
            self.includeSubfolders = includeSubfolders
            self.pdf = pdf
            self.images = images
        }
    }

    public struct Result: Equatable, Sendable {
        public var pdfs: [URL] = []
        public var images: [URL] = []
        public var all: [URL] { (pdfs + images).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending } }
    }

    /// Ordner (auch ohne „/“ am Ende, wie bei Finder-Drops) erkennen.
    public static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    public static func files(in folders: [URL], options: Options) -> Result {
        var result = Result()
        var seen = Set<String>()
        for folder in folders {
            var enumOptions: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
            if !options.includeSubfolders { enumOptions.insert(.skipsSubdirectoryDescendants) }
            guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: enumOptions) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      seen.insert(url.standardizedFileURL.path).inserted,
                      let type = UTType(filenameExtension: url.pathExtension) else { continue }
                if type.conforms(to: .pdf) {
                    if options.pdf { result.pdfs.append(url) }
                } else if ImportProcessor.imageTypes.contains(where: { type.conforms(to: $0) }) {
                    if options.images { result.images.append(url) }
                }
            }
        }
        return result
    }
}
