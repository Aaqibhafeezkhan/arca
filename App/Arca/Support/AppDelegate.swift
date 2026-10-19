import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        EditSessionManager.purgeStaleSessions()
        // Launch argument used by App/Scripts/screenshots.sh: `-ArcaAppearance dark|light`.
        switch UserDefaults.standard.string(forKey: "ArcaAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        WindowRouter.shared.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Bridges AppKit entry points (Finder, Dock, Services, Open panel) to
/// SwiftUI's value-based windows. Welcome windows "adopt" the first archive so
/// opening a file at launch doesn't leave an empty window behind.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()

    private var openWindow: OpenWindowAction?
    private var adopters: [(id: UUID, adopt: (URL) -> Void, dismiss: () -> Void)] = []
    private var queue: [URL] = []
    private let launched = Date()
    private var routedAtLaunch = false

    /// A file opened at a cold launch can reach SwiftUI after it has created the
    /// default window, and it then adds a second, blank one. Blank windows around
    /// launch are closed once an archive has been routed.
    private var isLaunching: Bool { Date().timeIntervalSince(launched) < 3 }

    func register(_ action: OpenWindowAction) {
        openWindow = action
        flush()
    }

    func addAdopter(_ id: UUID, adopt: @escaping (URL) -> Void, dismiss: @escaping () -> Void) {
        if routedAtLaunch && isLaunching {
            dismiss()
            return
        }
        adopters.append((id, adopt, dismiss))
        flush()
    }

    func removeAdopter(_ id: UUID) {
        adopters.removeAll { $0.id == id }
    }

    func open(_ urls: [URL]) {
        queue.append(contentsOf: urls)
        flush()
    }

    private func flush() {
        var routed = false
        while let url = queue.first {
            if !adopters.isEmpty {
                adopters.removeFirst().adopt(url)
            } else if let openWindow {
                openWindow(id: WindowID.archive, value: url)
            } else {
                return // No scene yet; retried once a window registers.
            }
            queue.removeFirst()
            routed = true
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        if routed && isLaunching {
            routedAtLaunch = true
            let blank = adopters
            adopters.removeAll()
            blank.forEach { $0.dismiss() }
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ArchiveTypes.openable
        panel.prompt = "Open"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    var recentArchives: [URL] {
        NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
