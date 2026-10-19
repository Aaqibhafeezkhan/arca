import ArcaKit
import SwiftUI

struct BrowserView: View {
    @Bindable var document: ArchiveDocument
    @State private var isDropTargeted = false

    var body: some View {
        let rows = document.rows
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                table(rows)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard document.canEdit else { return false }
            document.add(urls)
            return true
        } isTargeted: { isDropTargeted = $0 && document.canEdit }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !document.searchText.isEmpty {
            ContentUnavailableView.search(text: document.searchText)
        } else {
            ContentUnavailableView {
                Label("Empty Folder", systemImage: "folder")
            } description: {
                Text(document.canEdit ? "Drop files here to add them to the archive." : "This folder has no items.")
            } actions: {
                if document.canEdit {
                    Button("Add Files…") { document.presentAddPanel() }
                }
            }
        }
    }

    private func table(_ rows: [BrowserRow]) -> some View {
        Table(of: BrowserRow.self, selection: $document.selection, sortOrder: $document.sortOrder) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                NameCell(row: row, showPath: !document.searchText.isEmpty)
            }
            .width(min: 180, ideal: 320)

            TableColumn("Date Modified", value: \.modified) { row in
                Text(row.hasDate ? row.modified.formatted(date: .abbreviated, time: .shortened) : "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Size", value: \.size) { row in
                Text(row.isDirectory ? "\(row.itemCount) item\(row.itemCount == 1 ? "" : "s")" : row.size.formattedSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Compressed", value: \.packed) { row in
                CompressionCell(row: row)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Kind", value: \.kind) { row in
                Text(row.kind).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 130)
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .itemProvider { document.itemProvider(for: row.path) }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { selection in
            BrowserContextMenu(document: document, selection: selection)
        } primaryAction: { selection in
            document.activate(selection)
        }
        .onKeyPress(.space) {
            document.quickLookSelection()
            return .handled
        }
        .onKeyPress(.return) {
            // Finder convention: Return renames, ⌘↓ / double-click opens.
            guard document.canEdit, document.selection.count == 1 else { return .ignored }
            document.renameTarget = document.selection.first
            return .handled
        }
        .onDeleteCommand {
            if document.canEdit { document.requestDelete(document.selection) }
        }
    }
}

private struct NameCell: View {
    let row: BrowserRow
    let showPath: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: FileIcons.icon(for: row.path, isDirectory: row.isDirectory))
                .resizable()
                .frame(width: 18, height: 18)
                .overlay(alignment: .bottomTrailing) {
                    if row.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(1.5)
                            .background(.blue, in: Circle())
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .italic(row.isSymlink)
                if showPath, !ArchivePath.parent(row.path).isEmpty {
                    Text(ArchivePath.parent(row.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if let status = row.status {
                Spacer(minLength: 4)
                Text(status.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(status == .added ? .green : .orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background((status == .added ? Color.green : Color.orange).opacity(0.14), in: Capsule())
            }
        }
    }
}

private struct CompressionCell: View {
    let row: BrowserRow

    var body: some View {
        if let ratio = row.ratio, !row.isDirectory {
            HStack(spacing: 6) {
                Text(row.packed.formattedSize)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Gauge(value: ratio) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.accentColor)
                    .frame(width: 32)
                    .help("\(Int((ratio * 100).rounded()))% smaller")
            }
        } else {
            Text(row.hasPacked && !row.isDirectory ? row.packed.formattedSize : "—")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}

struct BrowserContextMenu: View {
    let document: ArchiveDocument
    let selection: Set<String>

    var body: some View {
        let nodes = selection.compactMap { document.tree.node($0) }
        let single = nodes.count == 1 ? nodes.first : nil

        if nodes.isEmpty {
            Button("Add Files…") { document.presentAddPanel() }.disabled(!document.canEdit)
            Button("New Folder") { document.isCreatingFolder = true }.disabled(!document.canEdit)
            Divider()
            Button("Extract All…") { document.extractWithDestinationChoice([]) }
        } else {
            if let single, single.isDirectory {
                Button("Open") { document.navigate(to: single.path) }
            } else {
                Button("Open") { document.activate(selection) }
                if let single {
                    Menu("Open With") {
                        ForEach(document.applications(for: single.path), id: \.self) { app in
                            Button {
                                document.openExternally(single.path, with: app)
                            } label: {
                                Label {
                                    Text(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
                                } icon: {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                }
                            }
                        }
                    }
                    Button("Quick Look") {
                        document.selection = [single.path]
                        document.quickLookSelection()
                    }
                    if FileIcons.isText(single.path), document.canEdit {
                        Button("Edit as Text…") { document.editAsText(single.path) }
                    }
                }
            }
            Divider()
            Button(nodes.count == 1 ? "Extract…" : "Extract \(nodes.count) Items…") {
                document.extractWithDestinationChoice(Array(selection))
            }
            if document.canEdit {
                Divider()
                if let single {
                    Button("Rename…") { document.renameTarget = single.path }
                }
                Button("Delete", role: .destructive) { document.requestDelete(selection) }
            }
        }
    }
}
