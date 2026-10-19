import ArcaKit
import Foundation

enum ChangeStatus: Equatable {
    case added, modified, renamed

    var label: String {
        switch self {
        case .added: "Added"
        case .modified: "Modified"
        case .renamed: "Renamed"
        }
    }
}

struct BrowserRow: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    let size: UInt64
    let packed: UInt64
    let hasPacked: Bool
    let modified: Date
    let hasDate: Bool
    let kind: String
    let isEncrypted: Bool
    let isSymlink: Bool
    let itemCount: Int
    let status: ChangeStatus?

    var path: String { id }

    var ratio: Double? {
        guard hasPacked, size > 0 else { return nil }
        return max(0, 1 - Double(packed) / Double(size))
    }

    @MainActor
    init(node: ArchiveTree.Node, status: ChangeStatus?) {
        id = node.path
        name = node.name
        isDirectory = node.isDirectory
        size = node.uncompressedSize
        packed = node.compressedSize ?? 0
        hasPacked = node.compressedSize != nil && status == nil
        modified = node.modificationDate ?? .distantPast
        hasDate = node.modificationDate != nil
        kind = FileIcons.kind(for: node.path, isDirectory: node.isDirectory)
        isEncrypted = node.isEncrypted
        isSymlink = node.entry?.isSymlink ?? false
        itemCount = node.childPaths.count
        self.status = status
    }
}

struct FolderNode: Identifiable, Hashable {
    let id: String
    let name: String
    let children: [FolderNode]

    static func build(_ tree: ArchiveTree, at path: String = "") -> [FolderNode] {
        tree.folders(in: path).map { FolderNode(id: $0.path, name: $0.name, children: build(tree, at: $0.path)) }
    }
}

/// Previews staged (not yet applied) changes for formats that rewrite on save,
/// so the browser shows the archive as it will be.
enum PendingOverlay {
    static func apply(_ changes: [ArchiveChange], to entries: [ArchiveEntry]) -> (entries: [ArchiveEntry], status: [String: ChangeStatus]) {
        var list = entries
        var status: [String: ChangeStatus] = [:]

        func upsert(_ entry: ArchiveEntry) {
            if let i = list.firstIndex(where: { $0.path == entry.path }) {
                list[i] = entry
                if status[entry.path] != .added { status[entry.path] = .modified }
            } else {
                list.append(entry)
                status[entry.path] = .added
            }
        }

        for change in changes {
            switch change {
            case let .delete(path):
                list.removeAll { $0.path == path || ArchivePath.isDescendant($0.path, of: path) }
                status = status.filter { $0.key != path && !ArchivePath.isDescendant($0.key, of: path) }
            case let .rename(from, to):
                list = list.map { e in
                    guard let p = rebase(e.path, from: from, to: to) else { return e }
                    status[p] = status.removeValue(forKey: e.path) == .added ? .added : .renamed
                    return copy(e, path: p)
                }
            case let .makeDirectory(path):
                if !list.contains(where: { $0.path == path }) { upsert(ArchiveEntry(path: path, isDirectory: true, uncompressedSize: 0)) }
            case let .addData(data, path):
                upsert(ArchiveEntry(path: path, isDirectory: false, uncompressedSize: UInt64(data.count), modificationDate: Date()))
            case let .add(url, path):
                for (relative, isDir, size, date) in expand(url) {
                    upsert(ArchiveEntry(path: relative.isEmpty ? path : path + "/" + relative, isDirectory: isDir,
                                        uncompressedSize: size, modificationDate: date))
                }
            }
        }
        return (list, status)
    }

    private static func rebase(_ path: String, from: String, to: String) -> String? {
        if path == from { return to }
        if ArchivePath.isDescendant(path, of: from) { return to + path.dropFirst(from.count) }
        return nil
    }

    private static func copy(_ e: ArchiveEntry, path: String) -> ArchiveEntry {
        ArchiveEntry(path: path, isDirectory: e.isDirectory, isSymlink: e.isSymlink, uncompressedSize: e.uncompressedSize,
                     compressedSize: e.compressedSize, modificationDate: e.modificationDate,
                     posixPermissions: e.posixPermissions, isEncrypted: e.isEncrypted, method: e.method, crc32: e.crc32,
                     linkTarget: e.linkTarget, hardLinkTarget: e.hardLinkTarget, comment: e.comment)
    }

    private static func expand(_ url: URL) -> [(String, Bool, UInt64, Date?)] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        func info(_ u: URL) -> (Bool, UInt64, Date?) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return (v?.isDirectory ?? false, UInt64(v?.fileSize ?? 0), v?.contentModificationDate)
        }
        let (isDir, size, date) = info(url)
        var result = [("", isDir, size, date)]
        guard isDir, let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return result }
        let base = url.standardizedFileURL.pathComponents.count
        for case let item as URL in e {
            let rel = item.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
            let (d, s, m) = info(item)
            result.append((rel, d, s, m))
        }
        return result
    }
}
