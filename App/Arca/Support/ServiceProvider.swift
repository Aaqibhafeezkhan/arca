import AppKit
import ArcaKit

/// Finder › Services: "Compress with Arca" and "Extract with Arca".
@MainActor
final class ServiceProvider: NSObject {
    @objc func compressFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(from: pboard)
        guard let first = urls.first else { return }
        let format = AppSettings.shared.defaultFormat
        let stem = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : L("Archive")
        let destination = uniqueURL(in: first.deletingLastPathComponent(), name: stem, ext: format.preferredExtension)
        let options = AppSettings.shared.writeOptions(password: nil)
        let activity = ServiceProgressWindow(title: L("Compressing…"), filename: destination.lastPathComponent)
        activity.show()
        Task {
            defer { activity.close() }
            // Publish only the finished archive; cancellation must not leave an empty one behind.
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".arca-compress-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let temporary = staging.appendingPathComponent(destination.lastPathComponent)
                _ = try await Archive.compress(urls, into: temporary, format: format, options: options,
                                               progress: activity.progress)
                guard !activity.progress.isCancelled else { return }
                try FileManager.default.moveItem(at: temporary, to: destination)
                activity.close()
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch ArchiveError.cancelled {
                // Cancellation is an expected outcome, not an error alert.
            } catch {
                activity.close()
                presentError(L("Couldn't compress the selected items"), error)
            }
        }
    }

    @objc func extractArchives(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(from: pboard).filter(ArchiveTypes.isArchive)
        guard let first = urls.first else { return }
        let activity = ServiceProgressWindow(title: L("Extracting…"), filename: first.lastPathComponent)
        activity.show()
        Task {
            defer { activity.close() }
            var results: [URL] = []
            for (index, url) in urls.enumerated() {
                guard !activity.progress.isCancelled else { break }
                activity.beginArchive(url, index: index + 1, count: urls.count)
                do {
                    results.append(try await SmartExtract.run(url, progress: activity.progress))
                } catch ArchiveError.cancelled {
                    break
                } catch ArchiveError.passwordRequired(_) {
                    guard !activity.progress.isCancelled else { break }
                    // Encrypted: hand over to the UI, which prompts for the password.
                    activity.close()
                    WindowRouter.shared.open([url])
                } catch {
                    guard !activity.progress.isCancelled else { break }
                    activity.close()
                    presentError(LF("Couldn't extract “%@”", url.lastPathComponent), error)
                }
                if index + 1 < urls.count, !activity.progress.isCancelled { activity.show() }
            }
            activity.close()
            if !results.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(results) }
        }
    }

    private func fileURLs(from pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = localizedError(error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}

enum SmartExtract {
    /// Like Archive Utility: a single top-level item lands next to the
    /// archive as-is; multiple items go into a folder named after it.
    @MainActor
    static func run(_ archiveURL: URL, progress: ArcaKit.ProgressReporter? = nil) async throws -> URL {
        let parent = archiveURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".arca-extract-\(UUID().uuidString)", isDirectory: true)
        let archive = try await Archive.open(archiveURL)
        do {
            guard progress?.isCancelled != true else { throw ArchiveError.cancelled }
            let items = try await archive.extract([], to: staging, conflict: .overwrite, progress: progress)
            guard progress?.isCancelled != true else { throw ArchiveError.cancelled }
            let fm = FileManager.default
            let result: URL
            if items.count == 1, let only = items.first {
                let ext = only.pathExtension
                let stem = ext.isEmpty ? only.lastPathComponent : only.deletingPathExtension().lastPathComponent
                result = uniqueURL(in: parent, name: stem, ext: ext)
                try fm.moveItem(at: only, to: result)
                try? fm.removeItem(at: staging)
            } else {
                let stem = ArchiveFormat.stripExtension(archiveURL.lastPathComponent)
                result = uniqueURL(in: parent, name: stem, ext: "")
                try fm.moveItem(at: staging, to: result)
            }
            return result
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}

func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
    func make(_ n: Int) -> URL {
        let base = n == 1 ? name : "\(name) \(n)"
        return folder.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
    }
    var n = 1
    while FileManager.default.fileExists(atPath: make(n).path) { n += 1 }
    return make(n)
}

extension ArchiveFormat {
    /// "photos.tar.gz" → "photos"
    static func stripExtension(_ filename: String) -> String {
        if let format = guess(fromFilename: filename) {
            for ext in [format.preferredExtension, "tgz", "tbz2", "txz", "tzst"] where filename.lowercased().hasSuffix("." + ext.lowercased()) {
                return String(filename.dropLast(ext.count + 1))
            }
        }
        return (filename as NSString).deletingPathExtension
    }
}
