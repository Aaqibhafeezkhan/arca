import ArcaKit
import SwiftUI

/// Finder-style path bar with item count.
struct PathBar: View {
    let document: ArchiveDocument

    var body: some View {
        HStack(spacing: 4) {
            ForEach(document.breadcrumbs) { crumb in
                if !crumb.isRoot {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button {
                    document.navigate(to: crumb.id)
                } label: {
                    Label {
                        Text(crumb.name).lineLimit(1)
                    } icon: {
                        Image(systemName: crumb.isRoot ? "archivebox" : "folder")
                    }
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(crumb.isLast ? .primary : .secondary)
            }
            Spacer(minLength: 12)
            Text(summary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var summary: String {
        let rows = document.rows
        if !document.selection.isEmpty {
            let size = document.selectedNodes.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
            return "\(document.selection.count) of \(rows.count) selected · \(size.formattedSize)"
        }
        return "\(rows.count) item\(rows.count == 1 ? "" : "s")"
    }
}

/// "file.txt was edited in another app" prompts.
struct WriteBackBanner: View {
    let document: ArchiveDocument

    var body: some View {
        VStack(spacing: 8) {
            ForEach(document.writeBacks) { item in
                HStack(spacing: 12) {
                    Image(systemName: "pencil.and.outline")
                        .font(.title3)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("“\(ArchivePath.lastComponent(item.entryPath))” was edited")
                            .font(.callout.weight(.semibold))
                        Text(document.editingMode == .inPlace
                             ? "Update the archive with the saved version?"
                             : "Stage the saved version for the next apply?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 16)
                    Button("Ignore") { document.ignoreWriteBack(item) }
                    Button("Update Archive") { document.writeBack(item) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 560)
                .floatingSurface(cornerRadius: 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 10)
        .animation(.snappy, value: document.writeBacks)
    }
}

/// Progress for long operations, or the staged-changes bar for rewrite formats.
struct FloatingStatus: View {
    let document: ArchiveDocument

    var body: some View {
        Group {
            if let activity = document.activity {
                ActivityPill(activity: activity, cancel: document.cancelActivity)
            } else if document.hasPendingChanges {
                PendingChangesPill(document: document)
            }
        }
        .animation(.snappy, value: document.activity?.id)
        .animation(.snappy, value: document.hasPendingChanges)
    }
}

private struct ActivityPill: View {
    let activity: Activity
    let cancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: activity.started, by: 0.1)) { context in
            // Short operations finish before the pill would just flash.
            if context.date.timeIntervalSince(activity.started) > 0.35 {
                HStack(spacing: 12) {
                    if activity.progress.total > 0 {
                        ProgressView(value: activity.progress.fraction)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activity.title).font(.callout.weight(.semibold))
                        if activity.progress.total > 0 {
                            Text("\(UInt64(activity.progress.completed).formattedSize) of \(UInt64(activity.progress.total).formattedSize)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    Button(action: cancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel — the archive is left exactly as it was")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .floatingSurface(cornerRadius: 22)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

private struct PendingChangesPill: View {
    let document: ArchiveDocument

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "circle.dotted.circle")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Unsaved changes").font(.callout.weight(.semibold))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Discard") { document.discardPending() }
            Button("Apply") { document.applyPending() }
                .buttonStyle(.borderedProminent)
                .help("Apply changes (⌘S)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .floatingSurface(cornerRadius: 22)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var caption: String {
        let format = document.snapshot?.format.displayName ?? "The archive"
        if case .streamRewrite(true) = document.editingMode {
            return "\(format) will be re-streamed in one pass"
        }
        return "\(format) will be rewritten in one pass"
    }
}

extension View {
    /// Liquid Glass on macOS 26, a material capsule before.
    func floatingSurface(cornerRadius: CGFloat) -> some View {
        modifier(FloatingSurface(cornerRadius: cornerRadius))
    }
}

private struct FloatingSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator.opacity(0.6)))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}
