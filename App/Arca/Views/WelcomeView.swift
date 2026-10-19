import ArcaKit
import SwiftUI

/// Shown in a window with no archive. Opening an archive "adopts" this window.
struct WelcomeView: View {
    let adopt: (URL) -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var isTargeted = false
    @State private var recents: [URL] = []

    var body: some View {
        HStack(spacing: 0) {
            hero
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !recents.isEmpty {
                Divider()
                recentList
                    .frame(width: 280)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(.background)
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .onAppear {
            recents = WindowRouter.shared.recentArchives
        }
        .navigationTitle("Arca")
    }

    private var hero: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.24), Color(red: 0.89, green: 0.33, blue: 0.20)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 112, height: 112)
                    .shadow(color: .orange.opacity(0.35), radius: 18, y: 8)
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
            VStack(spacing: 6) {
                Text("Arca").font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Browse, edit and extract archives — without unpacking them.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    WindowRouter.shared.presentOpenPanel()
                } label: {
                    Label("Open Archive…", systemImage: "folder")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    openWindow(id: WindowID.newArchive)
                } label: {
                    Label("New Archive…", systemImage: "plus.rectangle.on.folder")
                        .frame(minWidth: 150)
                }
            }
            .controlSize(.large)

            dropHint
        }
        .padding(40)
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                          style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .background(isTargeted ? Color.accentColor.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                Label("Drop an archive to open it, or files to compress them", systemImage: "arrow.down.to.line")
                    .font(.callout)
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            }
            .frame(maxWidth: 420, minHeight: 64, maxHeight: 64)
            .animation(.snappy, value: isTargeted)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 8)
            List(recents, id: \.self) { url in
                Button {
                    adopt(url)
                } label: {
                    HStack(spacing: 10) {
                        Image(nsImage: FileIcons.archiveIcon(for: url))
                            .resizable()
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.regularMaterial)
    }

    private func handleDrop(_ urls: [URL]) {
        let archives = urls.filter(ArchiveTypes.isArchive)
        if archives.count == urls.count, let first = archives.first {
            adopt(first)
            WindowRouter.shared.open(Array(archives.dropFirst()))
        } else {
            NewArchiveModel.shared.sources = urls
            openWindow(id: WindowID.newArchive)
        }
    }
}
