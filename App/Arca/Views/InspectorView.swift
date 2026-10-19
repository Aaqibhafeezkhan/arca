import ArcaKit
import Quartz
import SwiftUI

struct InspectorView: View {
    @Bindable var document: ArchiveDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let nodes = document.selectedNodes
                if nodes.count == 1, let node = nodes.first {
                    EntryInspector(document: document, node: node)
                        .id(node.path)
                } else if nodes.count > 1 {
                    MultiSelectionInspector(nodes: nodes)
                } else {
                    ArchiveInspector(document: document)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EntryInspector: View {
    let document: ArchiveDocument
    let node: ArchiveTree.Node
    @State private var previewURL: URL?
    @State private var previewFailed = false

    private var isPreviewable: Bool {
        !node.isDirectory && node.uncompressedSize <= 200 << 20 && document.statuses[node.path] != .added
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if isPreviewable { preview }
            actions
            InfoGrid(rows: info)
            if let comment = node.entry?.comment {
                GroupBox("Comment") { Text(comment).font(.callout).textSelection(.enabled) }
            }
        }
        .task(id: node.path) {
            guard isPreviewable else { return }
            do { previewURL = try await document.previewURL(for: node.path) } catch { previewFailed = true }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: FileIcons.icon(for: node.path, isDirectory: node.isDirectory))
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text(FileIcons.kind(for: node.path, isDirectory: node.isDirectory))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5))
            if let previewURL {
                QuickLookView(url: previewURL)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if previewFailed {
                Label("No preview", systemImage: "eye.slash").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 220)
        .onTapGesture(count: 2) { document.quickLookURL = previewURL }
    }

    @ViewBuilder
    private var actions: some View {
        if node.isDirectory {
            HStack {
                Button("Open Folder") { document.navigate(to: node.path) }
                Button("Extract…") { document.extractWithDestinationChoice([node.path]) }
            }
        } else {
            HStack {
                Button {
                    document.openExternally(node.path)
                } label: {
                    Label("Open", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .help(document.canEdit ? "Open in the default app. Saved changes flow back into the archive." : "Open a copy in the default app.")

                Menu {
                    ForEach(document.applications(for: node.path), id: \.self) { app in
                        Button(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")) {
                            document.openExternally(node.path, with: app)
                        }
                    }
                    if FileIcons.isText(node.path), document.canEdit {
                        Divider()
                        Button("Edit as Text…") { document.editAsText(node.path) }
                    }
                } label: {
                    Text("Open With")
                }
                .fixedSize()

                Button {
                    document.extractWithDestinationChoice([node.path])
                } label: {
                    Image(systemName: "arrow.down.doc")
                }
                .help("Extract…")
            }
        }
    }

    private var info: [(String, String)] {
        var rows: [(String, String)] = []
        if node.isDirectory {
            rows.append(("Contains", "\(node.descendantCount) item\(node.descendantCount == 1 ? "" : "s")"))
        }
        rows.append(("Size", node.uncompressedSize.formattedSize))
        if let packed = node.compressedSize, document.statuses[node.path] == nil {
            rows.append(("Compressed", packed.formattedSize))
            if node.uncompressedSize > 0 {
                let saved = max(0, 1 - Double(packed) / Double(node.uncompressedSize))
                rows.append(("Saved", saved.formatted(.percent.precision(.fractionLength(0)))))
            }
        }
        if let date = node.modificationDate { rows.append(("Modified", date.formatted(date: .long, time: .shortened))) }
        if let entry = node.entry {
            if let method = entry.method { rows.append(("Method", method)) }
            if let crc = entry.crc32 { rows.append(("CRC-32", String(format: "%08X", crc))) }
            if let perms = entry.posixPermissions { rows.append(("Permissions", perms.permissionString)) }
            if let link = entry.linkTarget { rows.append(("Links to", link)) }
            if entry.isEncrypted { rows.append(("Encryption", "Password protected")) }
        }
        if let status = document.statuses[node.path] { rows.append(("Status", "\(status.label) — not saved yet")) }
        rows.append(("Path", node.path))
        return rows
    }
}

private struct MultiSelectionInspector: View {
    let nodes: [ArchiveTree.Node]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 32))
                    .foregroundStyle(.tint)
                Text("\(nodes.count) items")
                    .font(.title3.weight(.semibold))
            }
            InfoGrid(rows: [
                ("Size", nodes.reduce(UInt64(0)) { $0 + $1.uncompressedSize }.formattedSize),
                ("Folders", "\(nodes.filter(\.isDirectory).count)"),
                ("Files", "\(nodes.filter { !$0.isDirectory }.count)"),
            ])
        }
    }
}

private struct ArchiveInspector: View {
    @Bindable var document: ArchiveDocument
    @State private var showingPasswordField = false
    @State private var newPassword = ""

    var body: some View {
        if let snapshot = document.snapshot {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: FileIcons.archiveIcon(for: document.url))
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(document.url.lastPathComponent)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Text("\(snapshot.format.displayName) archive")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                let mode = snapshot.editingMode.badge
                GroupBox {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.title).font(.callout.weight(.semibold))
                            Text(mode.help).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: {
                        Image(systemName: mode.symbol)
                            .foregroundStyle(snapshot.editingMode == .inPlace ? .green : .orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                InfoGrid(rows: stats(snapshot))

                if snapshot.statistics.reclaimableBytes > 0 {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(snapshot.statistics.reclaimableBytes.formattedSize) can be reclaimed")
                                .font(.callout.weight(.semibold))
                            Text("Earlier versions of edited or deleted items still occupy space. Compacting copies the remaining items without recompressing them.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Compact Archive") { document.compact() }
                                .disabled(!document.canEdit)
                        }
                        .padding(4)
                    }
                }

                if document.supportsEncryption, document.canEdit {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Encrypt added items (AES-256)", isOn: encryptionToggle)
                            if showingPasswordField {
                                SecureField("Password", text: $newPassword)
                                    .onSubmit(commitPassword)
                                HStack {
                                    Spacer()
                                    Button("Cancel") { showingPasswordField = false; newPassword = "" }
                                    Button("Use Password", action: commitPassword)
                                        .disabled(newPassword.isEmpty)
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                        .padding(4)
                    }
                }

                ForEach(snapshot.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var encryptionToggle: Binding<Bool> {
        Binding(get: { document.encryptionPassword != nil || showingPasswordField }, set: { on in
            if on { showingPasswordField = true } else {
                document.encryptionPassword = nil
                showingPasswordField = false
            }
        })
    }

    private func commitPassword() {
        guard !newPassword.isEmpty else { return }
        document.encryptionPassword = newPassword
        newPassword = ""
        showingPasswordField = false
    }

    private func stats(_ snapshot: ArchiveSnapshot) -> [(String, String)] {
        let s = snapshot.statistics
        var rows: [(String, String)] = [
            ("Files", "\(s.fileCount)"),
            ("Folders", "\(snapshot.tree.nodes.values.filter(\.isDirectory).count - 1)"),
            ("Archive size", s.archiveSize.formattedSize),
            ("Uncompressed", s.totalUncompressed.formattedSize),
        ]
        if s.totalUncompressed > 0, s.archiveSize > 0 {
            let saved = max(0, 1 - Double(s.archiveSize) / Double(s.totalUncompressed))
            rows.append(("Saved", saved.formatted(.percent.precision(.fractionLength(0)))))
        }
        return rows
    }
}

struct InfoGrid: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(row.1)
                        .textSelection(.enabled)
                        .monospacedDigit()
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
        }
        .font(.callout)
    }
}

/// Embedded Quick Look (QLPreviewView) for the inspector.
struct QuickLookView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
