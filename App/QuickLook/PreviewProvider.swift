import ArcaKit
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Finder spacebar preview: the archive's file listing as HTML.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        // Sandboxed and read-only: never touch the shared journal folder.
        let journal = JournalStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("journals"))
        let archive = try await Archive.open(request.fileURL, journal: journal)
        let snapshot = try await archive.snapshot()
        let html = ListingRenderer.html(for: snapshot)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 760, height: 900)) { _ in
            Data(html.utf8)
        }
    }
}

enum ListingRenderer {
    static let maxRows = 2000

    static func html(for snapshot: ArchiveSnapshot) -> String {
        let s = snapshot.statistics
        let entries = snapshot.entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var rows = ""
        for entry in entries.prefix(maxRows) {
            let depth = entry.path.filter { $0 == "/" }.count
            let icon = entry.isDirectory ? "📁" : entry.isSymlink ? "↪︎" : "📄"
            let lock = entry.isEncrypted ? " 🔒" : ""
            let size = entry.isDirectory ? "" : bytes(entry.uncompressedSize)
            let date = entry.modificationDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            rows += """
            <tr><td style="padding-left:\(8 + depth * 16)px">\(icon) \(escape(entry.name))\(lock)</td>\
            <td class="num">\(size)</td><td class="dim">\(date)</td></tr>
            """
        }
        if entries.count > maxRows {
            rows += "<tr><td colspan=3 class=dim>… and \(entries.count - maxRows) more items</td></tr>"
        }
        let ratio: String = {
            guard s.totalUncompressed > 0 else { return "" }
            let saved = max(0, 1 - Double(s.archiveSize) / Double(s.totalUncompressed))
            return " · \(Int((saved * 100).rounded()))% saved"
        }()

        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; --dim: #86868b; --line: rgba(128,128,128,.18); }
        body { font: 13px -apple-system, system-ui; margin: 0; padding: 22px 26px; }
        h1 { font-size: 20px; margin: 0 0 4px; font-weight: 600; }
        .meta { color: var(--dim); margin-bottom: 18px; }
        .pill { display: inline-block; padding: 2px 8px; border-radius: 99px; background: rgba(255,149,0,.15);
                color: #c66a00; font-size: 11px; font-weight: 600; margin-right: 6px; }
        table { width: 100%; border-collapse: collapse; }
        td { padding: 4px 8px; border-bottom: 1px solid var(--line); white-space: nowrap; overflow: hidden;
             text-overflow: ellipsis; max-width: 420px; }
        .num { text-align: right; font-variant-numeric: tabular-nums; color: var(--dim); }
        .dim { color: var(--dim); }
        </style></head><body>
        <h1>\(escape(snapshot.url.lastPathComponent))</h1>
        <div class="meta"><span class="pill">\(snapshot.format.displayName)</span>\(snapshot.isEncrypted ? "<span class=pill>Encrypted</span>" : "")\
        \(s.fileCount) files · \(bytes(s.totalUncompressed)) uncompressed · \(bytes(s.archiveSize)) on disk\(ratio)</div>
        <table>\(rows)</table>
        </body></html>
        """
    }

    private static func bytes(_ n: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
