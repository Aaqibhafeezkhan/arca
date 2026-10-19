import ArcaKit
import SwiftUI

struct ArcaCommands: Commands {
    @FocusedValue(\.archiveDocument) private var document
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Archive…") { openWindow(id: WindowID.newArchive) }
                .keyboardShortcut("n")
            Button("Open…") { WindowRouter.shared.presentOpenPanel() }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(WindowRouter.shared.recentArchives, id: \.self) { url in
                    Button(url.lastPathComponent) { WindowRouter.shared.open([url]) }
                }
                Divider()
                Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Apply Changes") { document?.applyPending() }
                .keyboardShortcut("s")
                .disabled(!(document?.hasPendingChanges ?? false))
            Button("Discard Changes") { document?.discardPending() }
                .disabled(!(document?.hasPendingChanges ?? false))
        }

        CommandMenu("Archive") {
            Button("Add Files…") { document?.presentAddPanel() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!(document?.canEdit ?? false))
            Button("New Folder") { document?.isCreatingFolder = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!(document?.canEdit ?? false))
            Divider()
            Button("Open") { if let d = document { d.activate(d.selection) } }
                .keyboardShortcut(.downArrow)
                .disabled(document?.selection.isEmpty ?? true)
            Button("Quick Look") { document?.quickLookSelection() }
                .keyboardShortcut("y")
                .disabled(document?.selection.isEmpty ?? true)
            Button("Enclosing Folder") { document?.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(document?.currentFolder.isEmpty ?? true)
            Divider()
            Button("Extract…") { if let d = document { d.extractWithDestinationChoice(Array(d.selection)) } }
                .keyboardShortcut("e")
                .disabled(document?.selection.isEmpty ?? true)
            Button("Extract All…") { document?.extractWithDestinationChoice([]) }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(document == nil)
            Divider()
            Button("Rename…") { if let d = document, d.selection.count == 1 { d.renameTarget = d.selection.first } }
                .disabled(!(document?.canEdit ?? false) || document?.selection.count != 1)
            Button("Delete") { if let d = document { d.requestDelete(d.selection) } }
                .keyboardShortcut(.delete)
                .disabled(!(document?.canEdit ?? false) || (document?.selection.isEmpty ?? true))
            Divider()
            Button("Compact Archive") { document?.compact() }
                .disabled(!(document?.canEdit ?? false) || document?.editingMode != .inPlace)
            Button("Reload from Disk") { document?.reload() }
                .keyboardShortcut("r")
                .disabled(document == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Show Inspector") { document?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(document == nil)
        }
    }
}
