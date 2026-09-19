import Foundation

/// Ein Tag: benannte, gespeicherte Suche. Tags stehen nicht im Dokument, sie filtern nur.
public struct Tag: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var query: String

    public init(id: UUID = UUID(), name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }
}

/// Tags des Archivs in `.scanarchiv-tags.json` im Archivordner (wandern mit dem Archiv mit).
public final class TagStore: @unchecked Sendable {
    public static let fileName = ".scanarchiv-tags.json"
    private let url: URL
    private let lock = NSLock()
    private var tags: [Tag]

    public init(folder: URL) {
        url = folder.appendingPathComponent(TagStore.fileName)
        tags = (try? JSONDecoder().decode([Tag].self, from: Data(contentsOf: url))) ?? []
    }

    public var all: [Tag] {
        lock.lock(); defer { lock.unlock() }
        return tags
    }

    public func add(_ tag: Tag) throws {
        lock.lock(); defer { lock.unlock() }
        tags.append(tag)
        try persist()
    }

    public func update(_ tag: Tag) throws {
        lock.lock(); defer { lock.unlock() }
        guard let i = tags.firstIndex(where: { $0.id == tag.id }) else { return }
        tags[i] = tag
        try persist()
    }

    public func remove(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        tags.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(tags).write(to: url, options: .atomic)
    }
}
