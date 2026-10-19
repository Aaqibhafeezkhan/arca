import ArcaKit
import SwiftUI

@main
struct ArcaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("Arca", id: WindowID.archive, for: URL.self) { $url in
            RootView(url: $url)
                .environment(settings)
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unified)
        .commands { ArcaCommands() }

        Window("New Archive", id: WindowID.newArchive) {
            NewArchiveView()
                .environment(settings)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}

enum WindowID {
    static let archive = "archive"
    static let newArchive = "new-archive"
}

struct RootView: View {
    @Binding var url: URL?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let url {
                ArchiveWindow(url: url)
                    .id(url)
            } else {
                WelcomeView(adopt: { url = $0 })
            }
        }
        .onAppear { WindowRouter.shared.register(openWindow) }
    }
}
