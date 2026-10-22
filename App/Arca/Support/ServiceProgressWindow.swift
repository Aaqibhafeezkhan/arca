import AppKit
import ArcaKit
import SwiftUI

/// The caller owns this window until the operation (including cancellation) finishes.
@MainActor
final class ServiceProgressWindow: NSWindowController {
    @Observable
    final class Activity {
        let title: String
        var filename: String
        var detail: String?
        var progress = ArcaKit.ProgressReporter()

        init(title: String, filename: String) {
            self.title = title
            self.filename = filename
        }
    }

    private let activity: Activity
    var progress: ArcaKit.ProgressReporter { activity.progress }

    init(title: String, filename: String) {
        activity = Activity(title: title, filename: filename)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Arca"
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: ServiceProgressView(activity: activity))
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func beginArchive(_ url: URL, index: Int, count: Int) {
        activity.filename = url.lastPathComponent
        activity.detail = count > 1 ? LF("Archive %lld of %lld", Int64(index), Int64(count)) : nil
        activity.progress = ArcaKit.ProgressReporter()
    }

    func show() {
        guard window?.isVisible != true else { return }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ServiceProgressView: View {
    let activity: ServiceProgressWindow.Activity

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let progress = activity.progress
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activity.title).font(.headline)
                        Text(activity.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(activity.filename)
                            .foregroundStyle(.secondary)
                    }
                }
                Group {
                    if progress.total > 0 {
                        ProgressView(value: progress.fraction)
                    } else {
                        ProgressView()
                    }
                }
                .progressViewStyle(.linear)
                .accessibilityLabel(activity.title)
                HStack {
                    Text(progress.isCancelled ? L("Cancelling…") : status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { progress.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(progress.isCancelled)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    private var status: String {
        let progress = activity.progress
        let phase = progress.total == 0 ? L("Preparing…")
            : progress.fraction >= 1 ? L("Finishing…")
            : progress.fraction.formatted(.percent.precision(.fractionLength(0)))
        return activity.detail.map { "\($0) · \(phase)" } ?? phase
    }
}
