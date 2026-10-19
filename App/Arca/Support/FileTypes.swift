import AppKit
import ArcaKit
import UniformTypeIdentifiers

enum ArchiveTypes {
    static let openable: [UTType] = {
        var types: [UTType] = [.archive, .zip, .gzip, .bz2]
        let identifiers = ["public.tar-archive", "org.gnu.gnu-zip-tar-archive", "org.7-zip.7-zip-archive",
                           "com.rarlab.rar-archive", "org.tukaani.xz-archive", "com.facebook.zstd-archive",
                           "public.iso-image", "com.apple.xar-archive", "public.cpio-archive", "com.microsoft.cab"]
        types += identifiers.compactMap { UTType($0) }
        types += ["7z", "rar", "xz", "txz", "zst", "tzst", "lz4", "lzh", "cab", "iso", "jar", "apk", "ipa", "epub",
                  "cbz", "cbr", "cb7", "cbt", "rpm", "deb", "pkg", "xip", "dmg", "wim", "swm", "esd", "vhd", "vhdx",
                  "msi", "squashfs", "sqsh", "chm", "arj", "appx", "msix", "aab", "vsix"]
            .compactMap { UTType(filenameExtension: $0) }
        return types
    }()

    static func isArchive(_ url: URL) -> Bool {
        if ArchiveFormat.guess(fromFilename: url.lastPathComponent) != nil { return true }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .archive)
    }
}

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String, isDirectory: Bool) -> NSImage {
        let ext = isDirectory ? "/" : (path as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let type: UTType = isDirectory ? .folder : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[ext] = image
        return image
    }

    static func archiveIcon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    static func kind(for path: String, isDirectory: Bool) -> String {
        if isDirectory { return "Folder" }
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "Document" }
        return type.localizedDescription ?? ext.uppercased()
    }

    static func isText(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if ["makefile", "dockerfile", "license", "readme", ".gitignore", ".env"].contains(name) { return true }
        let ext = (path as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .propertyList) || type.conforms(to: .yaml)
    }
}

extension UInt64 {
    var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(clamping: self), countStyle: .file) }
}

extension UInt16 {
    /// "rwxr-xr-x"
    var permissionString: String {
        let symbols: [Character] = ["r", "w", "x"]
        return String((0..<9).map { i -> Character in self & (1 << (8 - i)) != 0 ? symbols[i % 3] : "-" })
    }
}

extension EditingMode {
    var badge: (title: String, symbol: String, help: String) {
        switch self {
        case .inPlace:
            ("Live editing", "bolt.fill",
             "Changes are written straight into the archive. Untouched items are never recompressed.")
        case .streamRewrite(true):
            ("Saves on apply", "arrow.triangle.2.circlepath",
             "Changes are collected and applied in one pass. The outer compression is redone; nothing is extracted to disk.")
        case .streamRewrite(false):
            ("Saves on apply", "arrow.triangle.2.circlepath",
             "Changes are collected and applied in one pass, copying untouched items as-is.")
        case .readOnly:
            ("Read-only", "lock.fill", "This format can be browsed and extracted, but not modified.")
        }
    }
}
