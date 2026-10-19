import ArcaKit
import QuickLook
import SwiftUI

struct ArchiveWindow: View {
    let url: URL
    @State private var document: ArchiveDocument
    @State private var newFolderName = "untitled folder"
    @State private var renameText = ""

    init(url: URL) {
        self.url = url
        _document = State(initialValue: ArchiveDocument(url: url))
    }

    var body: some View {
        content
            .navigationTitle(url.lastPathComponent)
            .navigationSubtitle(subtitle)
            .navigationDocument(url)
            .focusedSceneValue(\.archiveDocument, document)
            .task { await document.load() }
            .onDisappear { document.close() }
            .quickLookPreview($document.quickLookURL)
            .modifier(DocumentDialogs(document: document, newFolderName: $newFolderName, renameText: $renameText))
    }

    private var subtitle: String {
        guard let snapshot = document.snapshot else { return "" }
        return "\(snapshot.format.displayName) · \(snapshot.statistics.archiveSize.formattedSize)"
    }

    @ViewBuilder
    private var content: some View {
        if let error = document.loadError {
            ContentUnavailableView {
                Label("Can't Open “\(url.lastPathComponent)”", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .frame(minWidth: 520, minHeight: 360)
        } else if document.isLoading {
            ProgressView("Reading archive…")
                .controlSize(.large)
                .frame(minWidth: 520, minHeight: 360)
        } else {
            browser
        }
    }

    private var browser: some View {
        NavigationSplitView {
            SidebarView(document: document)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            BrowserView(document: document)
                .safeAreaInset(edge: .bottom, spacing: 0) { PathBar(document: document) }
                .overlay(alignment: .top) { WriteBackBanner(document: document) }
                .overlay(alignment: .bottom) { FloatingStatus(document: document).padding(.bottom, 44) }
        }
        .inspector(isPresented: $document.showInspector) {
            InspectorView(document: document)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .searchable(text: $document.searchText, placement: .toolbar, prompt: "Search in archive")
        .toolbar { ArchiveToolbar(document: document) }
    }
}

struct ArchiveToolbar: ToolbarContent {
    let document: ArchiveDocument

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            ControlGroup {
                Button { document.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!document.canGoBack)
                Button { document.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!document.canGoForward)
            }
            .controlGroupStyle(.navigation)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { document.presentAddPanel() } label: { Label("Add", systemImage: "plus") }
                .help("Add files and folders (⇧⌘A)")
                .disabled(!document.canEdit)
            Button { document.isCreatingFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .help("New folder (⇧⌘N)")
                .disabled(!document.canEdit)
            Button { document.extractWithDestinationChoice(Array(document.selection)) } label: {
                Label("Extract", systemImage: "arrow.down.doc")
            }
            .help(document.selection.isEmpty ? "Extract everything (⌥⌘E)" : "Extract selection (⌘E)")
            Button(role: .destructive) { document.requestDelete(document.selection) } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete selection (⌘⌫)")
            .disabled(!document.canEdit || document.selection.isEmpty)
        }

        ToolbarItem(placement: .primaryAction) {
            Button { document.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

/// Sheets, alerts and confirmations attached to an archive window.
private struct DocumentDialogs: ViewModifier {
    @Bindable var document: ArchiveDocument
    @Binding var newFolderName: String
    @Binding var renameText: String

    func body(content: Content) -> some View {
        content
            .sheet(item: $document.passwordPrompt) { prompt in
                PasswordSheet(prompt: prompt)
            }
            .sheet(item: $document.textEditor) { state in
                TextEditorSheet(state: state, onSave: document.saveText, onCancel: { document.textEditor = nil })
            }
            .alert(document.alert?.title ?? "", isPresented: Binding(
                get: { document.alert != nil }, set: { if !$0 { document.alert = nil } }
            ), presenting: document.alert) { alert in
                if alert.reload {
                    Button("Reload") { document.reload() }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { alert in
                Text(alert.message)
            }
            .alert("New Folder", isPresented: $document.isCreatingFolder) {
                TextField("Name", text: $newFolderName)
                Button("Create") { document.createFolder(named: newFolderName) }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Rename", isPresented: Binding(
                get: { document.renameTarget != nil }, set: { if !$0 { document.renameTarget = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let target = document.renameTarget { document.rename(target, to: renameText) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: document.renameTarget) { _, target in
                if let target { renameText = ArchivePath.lastComponent(target) }
            }
            .onChange(of: document.isCreatingFolder) { _, creating in
                if creating { newFolderName = "untitled folder" }
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(
                get: { !document.deleteCandidates.isEmpty }, set: { if !$0 { document.deleteCandidates = [] } }
            ), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { document.confirmDelete() }
            } message: {
                Text(document.editingMode == .inPlace
                     ? "The items are removed from the archive immediately. You can't undo this action."
                     : "The items will be removed when you apply your changes.")
            }
    }

    private var deleteTitle: String {
        let n = document.deleteCandidates.count
        if n == 1, let only = document.deleteCandidates.first {
            return "Delete “\(ArchivePath.lastComponent(only))” from the archive?"
        }
        return "Delete \(n) items from the archive?"
    }
}
