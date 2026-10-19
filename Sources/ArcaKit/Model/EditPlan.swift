import Foundation

enum AdditionSource {
    case file(URL, size: UInt64)
    case data(Data)
    case directory
    case symlink(String)

    var size: UInt64 {
        switch self {
        case let .file(_, size): size
        case let .data(d): UInt64(d.count)
        case let .symlink(t): UInt64(t.utf8.count)
        case .directory: 0
        }
    }
}

struct PendingAddition {
    var path: String
    var source: AdditionSource
    var modified: Date
    var mode: UInt16

    var isDirectory: Bool { if case .directory = source { true } else { false } }
    var isSymlink: Bool { if case .symlink = source { true } else { false } }
}

/// Resolves a batch of `ArchiveChange`s against the existing entries into the
/// final list of surviving entries (by original index) plus new data to write.
/// Backends then only decide *how* to materialise it.
struct EditPlan {
    struct Item {
        var original: Int?
        var path: String
        var isDirectory: Bool
        var renamed = false
        var addition: PendingAddition?
    }

    private(set) var items: [Item?]
    private var lookup: [String: Set<Int>] = [:]
    private let options: WriteOptions

    init(existing: [(path: String, isDirectory: Bool)], options: WriteOptions) {
        self.options = options
        items = existing.enumerated().map { Item(original: $0.offset, path: $0.element.path, isDirectory: $0.element.isDirectory) }
        for (i, item) in items.enumerated() { lookup[item!.path, default: []].insert(i) }
    }

    var survivors: [Item] { items.compactMap { $0 } }
    var hasChanges: Bool { items.contains { $0 == nil || $0!.renamed || $0!.addition != nil } }

    func survivor(forOriginal index: Int) -> Item? {
        // Originals keep their slot index, so this is O(1).
        guard index < items.count, let item = items[index], item.original == index else { return nil }
        return item
    }

    private func slots(at path: String) -> [Int] { Array(lookup[path] ?? []) }

    private func slots(under path: String) -> [Int] {
        items.indices.filter { i in
            guard let item = items[i] else { return false }
            return item.path == path || ArchivePath.isDescendant(item.path, of: path)
        }
    }

    private func exists(_ path: String) -> Bool { !(lookup[path]?.isEmpty ?? true) }

    private func hasDescendants(_ path: String) -> Bool {
        items.contains { $0.map { ArchivePath.isDescendant($0.path, of: path) } ?? false }
    }

    private mutating func remove(_ i: Int) {
        guard let item = items[i] else { return }
        lookup[item.path]?.remove(i)
        items[i] = nil
    }

    private mutating func insert(_ item: Item) {
        items.append(item)
        lookup[item.path, default: []].insert(items.count - 1)
    }

    mutating func apply(_ change: ArchiveChange) throws {
        switch change {
        case let .delete(raw):
            let path = try ArchivePath.normalize(raw)
            let targets = path.isEmpty ? Array(items.indices) : slots(under: path)
            guard !targets.isEmpty else { throw ArchiveError.entryNotFound(path) }
            targets.forEach { remove($0) }

        case let .rename(rawFrom, rawTo):
            let from = try ArchivePath.normalize(rawFrom)
            let to = try ArchivePath.normalize(rawTo)
            guard !from.isEmpty, !to.isEmpty else { throw ArchiveError.invalidPath(rawTo) }
            guard from != to else { return }
            guard !ArchivePath.isDescendant(to, of: from) else { throw ArchiveError.invalidPath(rawTo) }
            let moving = slots(under: from)
            guard !moving.isEmpty else { throw ArchiveError.entryNotFound(from) }
            let movingSet = Set(moving)
            for i in moving {
                let newPath = ArchivePath.rebase(items[i]!.path, from: from, to: to)!
                if let clash = lookup[newPath], !clash.isSubset(of: movingSet) {
                    let isFolderMerge = items[i]!.isDirectory && clash.allSatisfy { items[$0]?.isDirectory == true }
                    if !isFolderMerge { throw ArchiveError.entryExists(newPath) }
                }
            }
            for i in moving {
                var item = items[i]!
                lookup[item.path]?.remove(i)
                item.path = ArchivePath.rebase(item.path, from: from, to: to)!
                if item.original != nil { item.renamed = true } else { item.addition?.path = item.path }
                items[i] = item
                lookup[item.path, default: []].insert(i)
            }

        case let .makeDirectory(raw):
            let path = try ArchivePath.normalize(raw)
            guard !path.isEmpty, !exists(path) else { return }
            addEntry(PendingAddition(path: path, source: .directory, modified: Date(), mode: 0o755))

        case let .addData(data, raw):
            let path = try ArchivePath.normalize(raw)
            guard !path.isEmpty else { throw ArchiveError.invalidPath(raw) }
            addEntry(PendingAddition(path: path, source: .data(data), modified: Date(), mode: 0o644))

        case let .add(url, raw):
            let path = try ArchivePath.normalize(raw)
            guard !path.isEmpty else { throw ArchiveError.invalidPath(raw) }
            for addition in try Self.expand(url, as: path, options: options) { addEntry(addition) }
        }
    }

    private mutating func addEntry(_ addition: PendingAddition) {
        // Replacing an existing entry; folders are merged rather than replaced.
        for i in slots(at: addition.path) {
            if addition.isDirectory, items[i]!.isDirectory { return }
            remove(i)
        }
        if !addition.isDirectory {
            // A file replacing a folder takes everything below it too.
            if hasDescendants(addition.path) { slots(under: addition.path).forEach { remove($0) } }
        }
        insert(Item(original: nil, path: addition.path, isDirectory: addition.isDirectory, addition: addition))
    }

    static func expand(_ url: URL, as path: String, options: WriteOptions) throws -> [PendingAddition] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]

        func addition(for item: URL, at path: String) throws -> PendingAddition? {
            let values = try item.resourceValues(forKeys: keys)
            let attributes = try fm.attributesOfItem(atPath: item.path)
            let mode = UInt16(truncatingIfNeeded: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644) & 0o7777
            let modified = values.contentModificationDate ?? Date()
            if values.isSymbolicLink == true {
                return PendingAddition(path: path, source: .symlink(try fm.destinationOfSymbolicLink(atPath: item.path)),
                                       modified: modified, mode: 0o755)
            }
            if values.isDirectory == true {
                return PendingAddition(path: path, source: .directory, modified: modified, mode: mode == 0 ? 0o755 : mode)
            }
            let size = UInt64((attributes[.size] as? NSNumber)?.uint64Value ?? 0)
            return PendingAddition(path: path, source: .file(item, size: size), modified: modified, mode: mode == 0 ? 0o644 : mode)
        }

        func excluded(_ name: String) -> Bool {
            options.excludeMacMetadata && (name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._"))
        }

        guard let root = try addition(for: url, at: path) else { return [] }
        var result = [root]
        guard root.isDirectory else { return result }

        let base = url.standardizedFileURL.pathComponents
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) else { return result }
        for case let item as URL in enumerator {
            if excluded(item.lastPathComponent) {
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            let relative = item.standardizedFileURL.pathComponents.dropFirst(base.count).joined(separator: "/")
            guard !relative.isEmpty else { continue }
            if let a = try addition(for: item, at: ArchivePath.join(path, relative)) { result.append(a) }
        }
        return result
    }
}
