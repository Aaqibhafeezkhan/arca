import ArcaKit
import Foundation

let usage = """
usage: arca <command> <archive> [args]

  list     <archive>                       list entries
  info     <archive>                       format, editing mode, statistics
  cat      <archive> <path>                write an entry to stdout
  extract  <archive> <dest> [path...]      extract everything or selected paths
  add      <archive> <file> [as-path]      add or replace a file/folder
  rm       <archive> <path>...             delete entries (folders recursively)
  mv       <archive> <from> <to>           rename / move
  mkdir    <archive> <path>                create a folder
  compact  <archive>                       reclaim space left by in-place edits
  create   <archive> <file>...             create a new archive (format from extension)

options: -p <password>   (repeatable; for encrypted entries / AES-256 when adding)
         -0 ... -9       compression level
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func formatSize(_ n: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
}

var args = Array(CommandLine.arguments.dropFirst())
var passwords: [String] = []
var level = 6
var positional: [String] = []
while !args.isEmpty {
    let a = args.removeFirst()
    if a == "-p" {
        guard !args.isEmpty else { fail("-p needs a value") }
        passwords.append(args.removeFirst())
    } else if a.count == 2, a.hasPrefix("-"), let n = Int(a.dropFirst()), (0...9).contains(n) {
        level = n
    } else {
        positional.append(a)
    }
}
guard positional.count >= 2 else { fail(usage) }
let command = positional[0]
let archiveURL = URL(fileURLWithPath: positional[1])
let rest = Array(positional.dropFirst(2))
var options = WriteOptions(compressionLevel: level)
if let pw = passwords.first, ["add", "create"].contains(command) { options.encryption = .aes256(password: pw) }

do {
    if command == "create" {
        guard let format = ArchiveFormat.guess(fromFilename: archiveURL.lastPathComponent),
              ArchiveFormat.creatable.contains(format) else { fail("can't create archives with this extension") }
        let sources = rest.map { URL(fileURLWithPath: $0) }
        _ = try await Archive.compress(sources, into: archiveURL, format: format, options: options)
        exit(0)
    }

    let archive = try await Archive.open(archiveURL, passwords: passwords)
    let snapshot = try await archive.snapshot()

    switch command {
    case "list":
        for e in snapshot.entries {
            let packed = e.compressedSize.map(formatSize) ?? "-"
            let flags = (e.isDirectory ? "d" : e.isSymlink ? "l" : "-") + (e.isEncrypted ? "E" : "-")
            print("\(flags) \(formatSize(e.uncompressedSize).padding(toLength: 10, withPad: " ", startingAt: 0)) \(packed.padding(toLength: 10, withPad: " ", startingAt: 0)) \(e.path)\(e.isDirectory ? "/" : "")")
        }

    case "info":
        let s = snapshot.statistics
        print("Format:        \(snapshot.format.displayName)")
        print("Editing:       \(snapshot.editingMode)")
        print("Files:         \(s.fileCount)   Folders: \(s.folderCount)")
        print("Size:          \(formatSize(s.archiveSize)) (\(formatSize(s.totalUncompressed)) uncompressed)")
        if s.reclaimableBytes > 0 { print("Reclaimable:   \(formatSize(s.reclaimableBytes))") }
        snapshot.notes.forEach { print("Note:          \($0)") }

    case "cat":
        guard let path = rest.first else { fail(usage) }
        FileHandle.standardOutput.write(try await archive.data(for: path, limit: .max))

    case "extract":
        guard let dest = rest.first else { fail(usage) }
        let urls = try await archive.extract(Array(rest.dropFirst()), to: URL(fileURLWithPath: dest), conflict: .overwrite)
        urls.forEach { print($0.path) }

    case "add":
        guard let file = rest.first else { fail(usage) }
        let source = URL(fileURLWithPath: file)
        let target = rest.count > 1 ? rest[1] : source.lastPathComponent
        _ = try await archive.apply([.add(source: source, at: target)], options: options)

    case "rm":
        guard !rest.isEmpty else { fail(usage) }
        _ = try await archive.apply(rest.map { .delete($0) }, options: options)

    case "mv":
        guard rest.count == 2 else { fail(usage) }
        _ = try await archive.apply([.rename(from: rest[0], to: rest[1])], options: options)

    case "mkdir":
        guard let path = rest.first else { fail(usage) }
        _ = try await archive.apply([.makeDirectory(path)], options: options)

    case "compact":
        let before = snapshot.statistics.archiveSize
        let after = try await archive.compact().statistics.archiveSize
        print("\(formatSize(before)) → \(formatSize(after))")

    default:
        fail(usage)
    }
} catch {
    fail("arca: \(error.localizedDescription)")
}
