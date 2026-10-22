import AppKit
import UniformTypeIdentifiers

// Stand-ins for unrelated app services; the router itself is compiled from production code.
@MainActor final class ServiceProvider: NSObject {}
@MainActor enum EditSessionManager { static func purgeStaleSessions() {} }
enum ArchiveTypes { static let openable: [UTType] = [] }
func L(_ text: String) -> String { text }
enum WindowID { static let archive = "archive" }

@main struct WindowRouterRegression {
    @MainActor static func main() {
        let router = WindowRouter.shared
        let first = URL(fileURLWithPath: "/tmp/arca-first.zip")
        let second = URL(fileURLWithPath: "/tmp/arca-second.zip")
        var routed: [URL] = []
        router.addAdopter(UUID(), adopt: { url in
            routed.append(url)
            router.open([second])
            router.addAdopter(UUID(), adopt: { routed.append($0) }, dismiss: {})
        }, dismiss: {})
        router.open([first])
        precondition(routed == [first, second], "Archives must be routed once, in order")
        print("PASS: nested window routing delivers each archive once")
    }
}
