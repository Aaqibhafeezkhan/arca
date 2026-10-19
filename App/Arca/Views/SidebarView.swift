import ArcaKit
import SwiftUI

struct SidebarView: View {
    @Bindable var document: ArchiveDocument

    var body: some View {
        List(selection: folderSelection) {
            Section {
                ArchiveCard(document: document)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
            }

            Section("Contents") {
                Label {
                    Text(document.url.deletingPathExtension().lastPathComponent)
                } icon: {
                    Image(systemName: "archivebox")
                }
                .tag("")

                ForEach(document.folders) { node in
                    FolderRow(node: node, document: document)
                }
            }
        }
        .listStyle(.sidebar)
        .dropDestination(for: URL.self) { urls, _ in
            guard document.canEdit else { return false }
            document.add(urls)
            return true
        }
    }

    private var folderSelection: Binding<String?> {
        Binding(get: { document.currentFolder }, set: { if let path = $0 { document.navigate(to: path) } })
    }
}

private struct FolderRow: View {
    let node: FolderNode
    @Bindable var document: ArchiveDocument

    var body: some View {
        if node.children.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: expanded) {
                ForEach(node.children) { FolderRow(node: $0, document: document) }
            } label: {
                label
            }
        }
    }

    private var label: some View {
        Label(node.name, systemImage: "folder")
            .badge(document.statuses[node.id] == nil ? nil : Text("•").foregroundStyle(.tint))
            .tag(node.id)
            .dropDestination(for: URL.self) { urls, _ in
                guard document.canEdit else { return false }
                document.add(urls, into: node.id)
                return true
            }
    }

    private var expanded: Binding<Bool> {
        Binding(get: { document.expandedFolders.contains(node.id) },
                set: { if $0 { document.expandedFolders.insert(node.id) } else { document.expandedFolders.remove(node.id) } })
    }
}

/// Archive identity at the top of the sidebar.
private struct ArchiveCard: View {
    let document: ArchiveDocument

    var body: some View {
        if let snapshot = document.snapshot {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(nsImage: FileIcons.archiveIcon(for: document.url))
                        .resizable()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.url.lastPathComponent)
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(snapshot.statistics.fileCount) items · \(snapshot.statistics.totalUncompressed.formattedSize)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                HStack(spacing: 6) {
                    Badge(text: snapshot.format.displayName, symbol: "doc.zipper", tint: .secondary)
                    let mode = snapshot.editingMode.badge
                    Badge(text: mode.title, symbol: mode.symbol, tint: snapshot.editingMode == .inPlace ? .green
                        : snapshot.editingMode == .readOnly ? .secondary : .orange)
                        .help(mode.help)
                    if snapshot.isEncrypted {
                        Badge(text: "Encrypted", symbol: "lock.fill", tint: .blue)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

struct Badge: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }
}
