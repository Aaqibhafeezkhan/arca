import Foundation

/// Watches entries opened in external apps and reports when they're saved.
///
/// Each entry lives in its own private temp folder. We watch the *folder*
/// rather than the file because most editors save atomically (write a new
/// file, then rename/exchange it over the old one), which replaces the inode.
@MainActor
final class EditSessionManager {
    struct Session {
        let entryPath: String
        let fileURL: URL
        var baseline: Fingerprint
        let source: DispatchSourceFileSystemObject
    }

    struct Fingerprint: Equatable {
        let size: UInt64
        let modified: Date

        init?(_ url: URL) {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let modified = values.contentModificationDate else { return nil }
            size = UInt64(values.fileSize ?? 0)
            self.modified = modified
        }
    }

    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("Arca-Edit", isDirectory: true)

    let directory: URL
    private var sessions: [String: Session] = [:]
    private var pendingChecks: Set<String> = []
    var onChange: ((String, URL) -> Void)?

    init() {
        directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Removes temp folders left behind by a previous run.
    static func purgeStaleSessions() {
        try? FileManager.default.removeItem(at: root)
    }

    func session(for entryPath: String) -> Session? { sessions[entryPath] }

    func begin(entryPath: String, fileURL: URL) {
        end(entryPath)
        let folder = fileURL.deletingLastPathComponent()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0, let baseline = Fingerprint(fileURL) else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleCheck(entryPath) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sessions[entryPath] = Session(entryPath: entryPath, fileURL: fileURL, baseline: baseline, source: source)
    }

    /// Accepts the current on-disk state as the new baseline (after writing back).
    func acknowledge(_ entryPath: String) {
        guard var s = sessions[entryPath], let fp = Fingerprint(s.fileURL) else { return }
        s.baseline = fp
        sessions[entryPath] = s
    }

    func end(_ entryPath: String) {
        guard let s = sessions.removeValue(forKey: entryPath) else { return }
        s.source.cancel()
    }

    /// Stops tracking `path` and anything below it (entry deleted or renamed).
    func end(under path: String) {
        for key in sessions.keys where key == path || key.hasPrefix(path + "/") { end(key) }
    }

    func endAll() {
        sessions.values.forEach { $0.source.cancel() }
        sessions.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func scheduleCheck(_ entryPath: String) {
        // Editors emit bursts of events per save; coalesce them.
        guard pendingChecks.insert(entryPath).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingChecks.remove(entryPath)
                self.check(entryPath)
            }
        }
    }

    private func check(_ entryPath: String) {
        guard let s = sessions[entryPath], let now = Fingerprint(s.fileURL), now != s.baseline else { return }
        onChange?(entryPath, s.fileURL)
    }
}
