import Foundation

/// Folder hierarchy derived from a flat entry list. Archives often omit explicit
/// directory entries, so missing parents are synthesised.
public struct ArchiveTree: Sendable {
    public struct Node: Identifiable, Hashable, Sendable {
        public let path: String
        public let isDirectory: Bool
        /// nil for synthesised folders.
        public let entry: ArchiveEntry?
        public internal(set) var childPaths: [String] = []
        /// Recursive totals for folders, entry sizes for files.
        public internal(set) var uncompressedSize: UInt64 = 0
        public internal(set) var compressedSize: UInt64? = 0
        public internal(set) var descendantCount = 0

        public var id: String { path }
        public var name: String { ArchivePath.lastComponent(path) }
        public var modificationDate: Date? { entry?.modificationDate }
        public var isEncrypted: Bool { entry?.isEncrypted ?? false }
    }

    public private(set) var nodes: [String: Node]

    public init(entries: [ArchiveEntry]) {
        var nodes: [String: Node] = ["": Node(path: "", isDirectory: true, entry: nil)]
        var children: [String: Set<String>] = [:]

        func ensureFolder(_ path: String) {
            guard nodes[path] == nil else { return }
            nodes[path] = Node(path: path, isDirectory: true, entry: nil)
            let parent = ArchivePath.parent(path)
            ensureFolder(parent)
            children[parent, default: []].insert(path)
        }

        for entry in entries where !entry.path.isEmpty {
            let parent = ArchivePath.parent(entry.path)
            ensureFolder(parent)
            if entry.isDirectory, let existing = nodes[entry.path], existing.entry == nil {
                nodes[entry.path] = Node(path: entry.path, isDirectory: true, entry: entry, childPaths: existing.childPaths)
            } else if nodes[entry.path]?.isDirectory == true, !entry.isDirectory {
                // A file shadowed by a folder of the same name: keep the folder.
                continue
            } else {
                nodes[entry.path] = Node(path: entry.path, isDirectory: entry.isDirectory, entry: entry)
            }
            children[parent, default: []].insert(entry.path)
        }

        for (path, set) in children {
            nodes[path]?.childPaths = set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        self.nodes = nodes
        accumulate("")
    }

    @discardableResult
    private mutating func accumulate(_ path: String) -> (UInt64, UInt64?, Int) {
        guard var node = nodes[path] else { return (0, 0, 0) }
        if !node.isDirectory {
            let e = node.entry!
            node.uncompressedSize = e.uncompressedSize
            node.compressedSize = e.compressedSize
            nodes[path] = node
            return (e.uncompressedSize, e.compressedSize, 0)
        }
        var size: UInt64 = 0
        var packed: UInt64? = 0
        var count = 0
        for child in node.childPaths {
            let (s, p, c) = accumulate(child)
            size += s
            if let p, let current = packed { packed = current + p } else { packed = nil }
            count += c + 1
        }
        node.uncompressedSize = size
        node.compressedSize = packed
        node.descendantCount = count
        nodes[path] = node
        return (size, packed, count)
    }

    public var root: Node { nodes[""]! }

    public func node(_ path: String) -> Node? { nodes[path] }

    public func children(of path: String) -> [Node] {
        (nodes[path]?.childPaths ?? []).compactMap { nodes[$0] }
    }

    public func folders(in path: String) -> [Node] {
        children(of: path).filter(\.isDirectory)
    }

    /// Entry paths (files and explicit folders) at or below `path`.
    public func entryPaths(under path: String) -> [String] {
        guard let node = nodes[path] else { return [] }
        var result: [String] = node.entry.map { [$0.path] } ?? []
        for child in node.childPaths { result += entryPaths(under: child) }
        return result
    }

    public func search(_ query: String, in path: String = "") -> [Node] {
        let q = query.lowercased()
        return nodes.values
            .filter { !$0.path.isEmpty && ArchivePath.isDescendant($0.path, of: path) && $0.name.lowercased().contains(q) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
