#if os(macOS)
import Foundation
import Testing
@testable import ArcaKit

@Suite struct DiskImageTests {
    private func makeDMG(_ s: Scratch, encryptedWith password: String? = nil) throws -> URL {
        _ = try s.file("src/hello.txt", "Hello, DMG!")
        _ = try s.file("src/sub/data.txt", String(repeating: "x", count: 4096))
        let dmg = s.path(password == nil ? "test.dmg" : "secret.dmg")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        var args = ["create", "-quiet", "-srcfolder", s.path("src").path, "-volname", "Test", "-format", "UDZO"]
        if password != nil { args += ["-encryption", "AES-256", "-stdinpass"] }
        p.arguments = args + [dmg.path]
        let input = Pipe()
        p.standardInput = input
        try p.run()
        if let password { input.fileHandleForWriting.write(Data(password.utf8) + Data([0])) }
        try input.fileHandleForWriting.close()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return dmg
    }

    @Test func mountsBrowsesAndExtracts() async throws {
        let s = try Scratch()
        let dmg = try makeDMG(s)
        let archive = try await Archive.open(dmg)
        let snapshot = try await archive.snapshot()
        #expect(snapshot.format == .dmg)
        #expect(snapshot.editingMode == .readOnly)
        #expect(Set(snapshot.entries.map(\.path)).isSuperset(of: ["hello.txt", "sub", "sub/data.txt"]))
        #expect(String(decoding: try await archive.data(for: "hello.txt"), as: UTF8.self) == "Hello, DMG!")
        let urls = try await archive.extract(["sub"], to: s.path("out"))
        #expect(urls.map(\.lastPathComponent) == ["sub"])
    }

    @Test func encryptedImageNeedsPassword() async throws {
        let s = try Scratch()
        let dmg = try makeDMG(s, encryptedWith: "pw")
        await #expect(throws: ArchiveError.passwordRequired(entry: "")) { _ = try await Archive.open(dmg) }
        await #expect(throws: ArchiveError.wrongPassword(entry: "")) { _ = try await Archive.open(dmg, passwords: ["no"]) }
        let archive = try await Archive.open(dmg, passwords: ["pw"])
        #expect(String(decoding: try await archive.data(for: "hello.txt"), as: UTF8.self) == "Hello, DMG!")
    }
}
#endif
