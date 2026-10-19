import AppKit
import ArcaKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct Activity: Identifiable {
    let id = UUID()
    let title: String
    let progress: ArcaKit.ProgressReporter
    let started = Date()
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var reload = false
}

struct PasswordPrompt: Identifiable {
    let id = UUID()
    let message: String
    var onCancel: (() -> Void)?
    let retry: (String) -> Void

    init(message: String, onCancel: (() -> Void)? = nil, retry: @escaping (String) -> Void) {
        self.message = message
        self.onCancel = onCancel
        self.retry = retry
    }
}

struct TextEditorState: Identifiable {
    var id: String { path }
    let path: String
    var text: String
}

struct Breadcrumb: Identifiable {
    let id: String
    let name: String
    let isRoot: Bool
    let isLast: Bool
}

struct WriteBack: Identifiable, Equatable {
    var id: String { entryPath }
    let entryPath: String
    let fileURL: URL
}

/// One open archive window: navigation, selection and every user action.
@MainActor
@Observable
final class ArchiveDocument {
    let url: URL
    private let settings = AppSettings.shared

    private(set) var archive: Archive?
    private(set) var snapshot: ArchiveSnapshot? { didSet { refreshDisplay() } }
    private(set) var loadError: String?
    var isLoading: Bool { archive == nil && loadError == nil }

    // Display model (snapshot + staged changes)
    private(set) var tree = ArchiveTree(entries: [])
    private(set) var folders: [FolderNode] = []
    private(set) var statuses: [String: ChangeStatus] = [:]

    // Navigation & selection
    var currentFolder = "" {
        didSet {
            guard oldValue != currentFolder else { return }
            selection = []
            expandAncestors(of: currentFolder)
        }
    }
    var selection = Set<String>()
    var searchText = ""
    var sortOrder = [KeyPathComparator(\BrowserRow.name, comparator: String.StandardComparator.localizedStandard)]
    var expandedFolders = Set<String>()
    private var backStack: [String] = []
    private var forwardStack: [String] = []

    // Editing
    private(set) var pending: [ArchiveChange] = [] { didSet { refreshDisplay() } }
    private(set) var writeBacks: [WriteBack] = []
    /// Password used to AES-encrypt items added from now on (ZIP only).
    var encryptionPassword: String?

    // Presentation
    private(set) var activity: Activity?
    var alert: AlertMessage?
    var passwordPrompt: PasswordPrompt?
    var textEditor: TextEditorState?
    var quickLookURL: URL?
    var showInspector = true
    var renameTarget: String?
    var isCreatingFolder = false
    var deleteCandidates: [String] = []

    private let sessions = EditSessionManager()
    private var previewCache: [String: URL] = [:]

    init(url: URL) {
        self.url = url
        sessions.onChange = { [weak self] path, file in self?.externalChange(path, file) }
    }

    func close() {
        sessions.endAll()
    }

    // MARK: - Loading

    func load(passwords: [String] = []) async {
        do {
            let archive = try await Archive.open(url, passwords: passwords)
            self.archive = archive
            snapshot = try await archive.snapshot()
            if supportsEncryption, snapshot?.isEncrypted == true { encryptionPassword = passwords.last }
        } catch let error as ArchiveError where error.isPasswordError {
            // Encrypted headers (e.g. 7z): the listing itself needs the password.
            passwordPrompt = PasswordPrompt(message: error.localizedDescription, onCancel: { [weak self] in
                self?.loadError = error.localizedDescription
            }) { [weak self] password in
                Task { await self?.load(passwords: passwords + [password]) }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func reload() {
        perform("Reloading", cancellable: false) { [self] _ in
            guard let archive else { return }
            snapshot = try await archive.reload()
            pending = []
            previewCache.removeAll()
        }
    }

    private func refreshDisplay() {
        guard let snapshot else { return }
        if pending.isEmpty {
            tree = snapshot.tree
            statuses = [:]
        } else {
            let overlay = PendingOverlay.apply(pending, to: snapshot.entries)
            tree = ArchiveTree(entries: overlay.entries)
            statuses = overlay.status
        }
        folders = FolderNode.build(tree)
        if tree.node(currentFolder) == nil { currentFolder = "" }
        selection = selection.filter { tree.node($0) != nil }
    }

    var editingMode: EditingMode { snapshot?.editingMode ?? .readOnly }
    var canEdit: Bool { editingMode.isEditable && activity == nil }
    var supportsEncryption: Bool { snapshot?.format == .zip }

    // MARK: - Browser data

    var rows: [BrowserRow] {
        let nodes = searchText.isEmpty ? tree.children(of: currentFolder) : tree.search(searchText, in: currentFolder)
        let rows = nodes.map { BrowserRow(node: $0, status: statuses[$0.path]) }.sorted(using: sortOrder)
        // Finder-style: folders first, each group in the chosen order.
        return rows.filter(\.isDirectory) + rows.filter { !$0.isDirectory }
    }

    var selectedNodes: [ArchiveTree.Node] { selection.compactMap { tree.node($0) } }

    var breadcrumbs: [Breadcrumb] {
        var result = [Breadcrumb(id: "", name: url.lastPathComponent, isRoot: true, isLast: currentFolder.isEmpty)]
        var path = ""
        let parts = currentFolder.split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            path = ArchivePath.join(path, part)
            result.append(Breadcrumb(id: path, name: part, isRoot: false, isLast: i == parts.count - 1))
        }
        return result
    }

    // MARK: - Navigation

    func navigate(to folder: String) {
        guard folder != currentFolder, tree.node(folder)?.isDirectory == true else { return }
        backStack.append(currentFolder)
        forwardStack.removeAll()
        searchText = ""
        currentFolder = folder
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(currentFolder)
        currentFolder = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentFolder)
        currentFolder = next
    }

    func goUp() {
        guard !currentFolder.isEmpty else { return }
        navigate(to: ArchivePath.parent(currentFolder))
    }

    private func expandAncestors(of path: String) {
        var p = path
        while !p.isEmpty {
            expandedFolders.insert(p)
            p = ArchivePath.parent(p)
        }
    }

    /// Double-click / Return: enter folders, open files.
    func activate(_ paths: Set<String>) {
        guard let first = paths.first, let node = tree.node(first) else { return }
        if paths.count == 1, node.isDirectory {
            navigate(to: first)
        } else {
            paths.compactMap { tree.node($0) }.filter { !$0.isDirectory }.forEach { openExternally($0.path) }
        }
    }

    // MARK: - Operations

    /// Runs async work with progress, cancellation and password retry.
    func perform(_ title: String, cancellable: Bool = true, _ work: @escaping (ArcaKit.ProgressReporter) async throws -> Void) {
        let reporter = ArcaKit.ProgressReporter()
        let activity = Activity(title: title, progress: reporter)
        self.activity = activity
        Task { [self] in
            defer { if self.activity?.id == activity.id { self.activity = nil } }
            do {
                try await work(reporter)
            } catch let error as ArchiveError where error.isPasswordError {
                passwordPrompt = PasswordPrompt(message: error.localizedDescription) { [weak self] password in
                    guard let self else { return }
                    Task {
                        try? await self.archive?.addPassword(password)
                        if self.supportsEncryption, self.encryptionPassword == nil, self.snapshot?.isEncrypted == true {
                            self.encryptionPassword = password
                        }
                        self.perform(title, cancellable: cancellable, work)
                    }
                }
            } catch ArchiveError.cancelled {
                // User cancelled; the engine already rolled back.
            } catch ArchiveError.modifiedExternally {
                alert = AlertMessage(title: "The archive changed on disk",
                                     message: "Another app modified “\(url.lastPathComponent)”. Reload to see the current contents.",
                                     reload: true)
            } catch {
                alert = AlertMessage(title: "\(title) failed", message: error.localizedDescription)
            }
        }
    }

    func cancelActivity() { activity?.progress.cancel() }

    /// Applies immediately for in-place formats, stages otherwise.
    func submit(_ changes: [ArchiveChange], title: String) {
        guard editingMode.isEditable else {
            alert = AlertMessage(title: "Read-only archive",
                                 message: "\(snapshot?.format.displayName ?? "This") archives can't be modified. Extract the items you need instead.")
            return
        }
        if case .streamRewrite = editingMode {
            pending.append(contentsOf: changes)
            return
        }
        perform(title) { [self] progress in try await commit(changes, progress: progress) }
    }

    private func commit(_ changes: [ArchiveChange], progress: ArcaKit.ProgressReporter) async throws {
        guard let archive else { return }
        let options = settings.writeOptions(password: supportsEncryption ? encryptionPassword : nil)
        var updated = try await archive.apply(changes, options: options, progress: progress)
        let stats = updated.statistics
        if settings.autoCompact, stats.reclaimableBytes > 1 << 20,
           Double(stats.reclaimableBytes) > Double(stats.archiveSize) * 0.4 {
            updated = try await archive.compact(progress: progress)
        }
        previewCache.removeAll()
        snapshot = updated
    }

    var hasPendingChanges: Bool { !pending.isEmpty }

    func applyPending() {
        guard !pending.isEmpty else { return }
        let changes = pending
        perform("Saving changes") { [self] progress in
            try await commit(changes, progress: progress)
            pending.removeAll()
        }
    }

    func discardPending() { pending.removeAll() }

    func compact() {
        perform("Compacting") { [self] progress in
            guard let archive else { return }
            snapshot = try await archive.compact(progress: progress)
        }
    }

    // MARK: Adding

    func add(_ urls: [URL], into folder: String? = nil) {
        let target = folder ?? currentFolder
        let sources = urls.filter { !$0.path.hasPrefix(EditSessionManager.root.path) }
        guard !sources.isEmpty else { return }
        submit(sources.map { .add(source: $0, at: ArchivePath.join(target, $0.lastPathComponent)) },
               title: "Adding \(sources.count == 1 ? "“\(sources[0].lastPathComponent)”" : "\(sources.count) items")")
    }

    func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        panel.message = "Choose files and folders to add to “\(currentFolder.isEmpty ? url.lastPathComponent : ArchivePath.lastComponent(currentFolder))”"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func createFolder(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: ":")
        guard !clean.isEmpty else { return }
        let path = ArchivePath.join(currentFolder, clean)
        guard tree.node(path) == nil else {
            alert = AlertMessage(title: "Name already in use", message: "“\(clean)” already exists in this folder.")
            return
        }
        submit([.makeDirectory(path)], title: "Creating folder")
    }

    // MARK: Deleting & renaming

    func requestDelete(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        deleteCandidates = Array(paths).sorted()
    }

    func confirmDelete() {
        let paths = deleteCandidates
        deleteCandidates = []
        paths.forEach { sessions.end(under: $0) }
        selection.subtract(paths)
        submit(paths.map { .delete($0) }, title: "Deleting")
    }

    func rename(_ path: String, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: ":")
        guard !clean.isEmpty, clean != ArchivePath.lastComponent(path) else { return }
        let destination = ArchivePath.join(ArchivePath.parent(path), clean)
        guard tree.node(destination) == nil else {
            alert = AlertMessage(title: "Name already in use", message: "“\(clean)” already exists in this folder.")
            return
        }
        sessions.end(under: path)
        submit([.rename(from: path, to: destination)], title: "Renaming")
        selection = [destination]
    }

    // MARK: Extracting

    func extract(_ paths: [String], to destination: URL) {
        let nodes = paths.compactMap { tree.node($0) }
        // Items from search results may live at different depths: extract
        // each group relative to its own parent.
        let groups = Dictionary(grouping: nodes.map(\.path), by: ArchivePath.parent)
        perform("Extracting") { [self] progress in
            guard let archive else { return }
            var results: [URL] = []
            for (base, group) in groups.sorted(by: { $0.key < $1.key }) {
                results += try await archive.extract(group, relativeTo: base, to: destination, conflict: .keepBoth,
                                                     progress: progress)
            }
            if paths.isEmpty {
                results = try await archive.extract([], to: destination, conflict: .keepBoth, progress: progress)
            }
            if settings.revealAfterExtract, !results.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(results)
            }
        }
    }

    /// `paths` empty = whole archive.
    func extractWithDestinationChoice(_ paths: [String]) {
        if hasPendingChanges {
            alert = AlertMessage(title: "Apply changes first",
                                 message: "This archive has unsaved changes. Apply or discard them before extracting.")
            return
        }
        switch settings.extractionDestination {
        case .nextToArchive:
            extract(paths, to: url.deletingLastPathComponent())
        case .downloads:
            extract(paths, to: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        case .ask:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Extract"
            panel.directoryURL = url.deletingLastPathComponent()
            panel.message = paths.isEmpty ? "Extract all items to:" : "Extract \(paths.count) item\(paths.count == 1 ? "" : "s") to:"
            if panel.runModal() == .OK, let dest = panel.url { extract(paths, to: dest) }
        }
    }

    // MARK: Opening & live editing

    func openExternally(_ path: String, with app: URL? = nil) {
        guard statuses[path] != .added else {
            alert = AlertMessage(title: "Not saved yet", message: "Apply pending changes before opening newly added items.")
            return
        }
        perform("Opening", cancellable: false) { [self] _ in
            guard let archive else { return }
            let file = try await archive.extractForEditing(path, in: sessions.directory)
            if editingMode.isEditable, tree.node(path)?.isDirectory == false {
                sessions.begin(entryPath: path, fileURL: file)
            }
            if let app {
                _ = try await NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(file)
            }
        }
    }

    func applications(for path: String) -> [URL] {
        let ext = (path as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
    }

    private func externalChange(_ path: String, _ file: URL) {
        guard tree.node(path) != nil else { return }
        if settings.autoWriteBack {
            writeBack(WriteBack(entryPath: path, fileURL: file))
        } else if !writeBacks.contains(where: { $0.entryPath == path }) {
            writeBacks.append(WriteBack(entryPath: path, fileURL: file))
        }
    }

    func writeBack(_ item: WriteBack) {
        writeBacks.removeAll { $0 == item }
        sessions.acknowledge(item.entryPath)
        // Copy the edited file aside so further edits don't race the write.
        let snapshotURL = sessions.directory.appendingPathComponent("writeback-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(item.fileURL.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: item.fileURL, to: snapshotURL)
        } catch {
            alert = AlertMessage(title: "Couldn't read the edited file", message: error.localizedDescription)
            return
        }
        submit([.add(source: snapshotURL, at: item.entryPath)], title: "Updating “\(ArchivePath.lastComponent(item.entryPath))”")
    }

    func ignoreWriteBack(_ item: WriteBack) {
        writeBacks.removeAll { $0 == item }
        sessions.acknowledge(item.entryPath)
    }

    // MARK: Preview & text editing

    func previewURL(for path: String) async throws -> URL {
        if let cached = previewCache[path], FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard let archive else { throw ArchiveError.entryNotFound(path) }
        let url = try await archive.extractForEditing(path, in: sessions.directory.appendingPathComponent("previews"))
        previewCache[path] = url
        return url
    }

    func quickLookSelection() {
        if quickLookURL != nil {
            quickLookURL = nil
            return
        }
        guard let path = selection.sorted().first, tree.node(path)?.isDirectory == false, statuses[path] != .added else { return }
        perform("Preparing preview", cancellable: false) { [self] _ in
            quickLookURL = try await previewURL(for: path)
        }
    }

    func editAsText(_ path: String) {
        perform("Loading", cancellable: false) { [self] _ in
            guard let archive else { return }
            let data = try await archive.data(for: path, limit: 16 << 20)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw ArchiveError.unsupported("this file isn't text")
            }
            textEditor = TextEditorState(path: path, text: text)
        }
    }

    func saveText(_ state: TextEditorState) {
        textEditor = nil
        submit([.addData(Data(state.text.utf8), at: state.path)], title: "Saving “\(ArchivePath.lastComponent(state.path))”")
    }

    // MARK: Drag out

    func itemProvider(for path: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let isDir = tree.node(path)?.isDirectory ?? false
        let name = ArchivePath.lastComponent(path)
        provider.suggestedName = name
        let type: UTType = isDir ? .folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
        let directory = sessions.directory.appendingPathComponent("drag", isDirectory: true)
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak self] completion in
            Task { @MainActor in
                guard let archive = self?.archive else {
                    completion(nil, false, ArchiveError.entryNotFound(path))
                    return
                }
                do {
                    let url = try await archive.extractForEditing(path, in: directory)
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }
}

struct ArchiveDocumentKey: FocusedValueKey {
    typealias Value = ArchiveDocument
}

extension FocusedValues {
    var archiveDocument: ArchiveDocument? {
        get { self[ArchiveDocumentKey.self] }
        set { self[ArchiveDocumentKey.self] = newValue }
    }
}
