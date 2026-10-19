import Foundation
import Testing
@testable import ArcaKit

private let hasSevenZip = ExternalTools.sevenZip != nil
private let hasRAR = ExternalTools.rar != nil && ExternalTools.sevenZip != nil

@Suite struct SevenZipListingTests {
    @Test func parsesTechnicalListing() {
        let output = """
        7-Zip (z) 26.04 (x64)

        --
        Path = a.7z
        Type = 7z
        Solid = +
        Blocks = 1

        ----------
        Path = docs
        Size = 0
        Packed Size = 0
        Modified = 2026-10-19 08:53:53.2677668
        Attributes = D drwxr-xr-x
        CRC =
        Encrypted = -
        Method =
        Block =

        Path = docs/run.sh
        Size = 120
        Packed Size =
        Modified = 2026-10-19 08:53:53
        Attributes = A -rwxr-xr-x
        CRC = 6855A842
        Encrypted = +
        Method = LZMA2:16 7zAES
        Block = 0

        Path = link
        Size = 7
        Packed Size = 7
        Attributes =  lrwxrwxrwx
        Encrypted = -

        """
        let listing = SevenZipBackend.parseListing(output)
        #expect(listing.properties["Type"] == "7z")
        #expect(listing.properties["Solid"] == "+")
        #expect(listing.entries.map(\.path) == ["docs", "docs/run.sh", "link"])
        let dir = listing.entries[0], file = listing.entries[1], link = listing.entries[2]
        #expect(dir.isDirectory && dir.posixPermissions == 0o755)
        #expect(file.uncompressedSize == 120 && file.compressedSize == nil)
        #expect(file.crc32 == 0x6855_A842 && file.isEncrypted && file.method == "LZMA2:16 7zAES")
        #expect(file.posixPermissions == 0o755)
        #expect(link.isSymlink && !link.isDirectory)
    }

    @Test func formatGuesses() {
        #expect(ArchiveFormat.guess(fromFilename: "issue.cbr") == .rar)
        #expect(ArchiveFormat.guess(fromFilename: "issue.cb7") == .sevenZip)
        #expect(ArchiveFormat.guess(fromFilename: "issue.cbz") == .zip)
        #expect(ArchiveFormat.guess(fromFilename: "app.msix") == .zip)
        #expect(ArchiveFormat.guess(fromFilename: "pkg.rpm") == .rpm)
        #expect(ArchiveFormat.guess(fromFilename: "Install.dmg") == .dmg)
        #expect(ArchiveFormat.guess(fromFilename: "boot.vhdx") == .vhd)
        #expect(ArchiveFormat.documentKind(forFilename: "x.CBR") == "Comic Book (RAR)")
    }

    @Test func emptySevenZipHeaderIsValid() throws {
        let s = try Scratch()
        let path = s.path("empty.7z").path
        try SevenZipBackend.createEmpty7z(at: path)
        let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(bytes.count == 32)
        #expect(Archive.hasSignature(bytes, of: .sevenZip))
        #expect(CRC32.checksum(Array(bytes[12..<32])) == bytes.le32(at: 8))
    }
}

@Suite(.enabled(if: hasSevenZip, "7-Zip (7zz) not installed"))
struct SevenZipTests {
    @Test func readsSolid7z() async throws {
        let archive = try await Archive.open(Fixtures.url("sample.7z"))
        let snapshot = try await archive.snapshot()
        #expect(snapshot.format == .sevenZip)
        #expect(snapshot.editingMode == .streamRewrite(recompresses: true))
        #expect(Set(snapshot.entries.map(\.path)) == ["hello.txt", "docs", "docs/notes.md", "docs/data.bin"])
        #expect(String(decoding: try await archive.data(for: "hello.txt"), as: UTF8.self) == "Hello, Arca!\n")
        #expect(try await archive.data(for: "docs/data.bin").count == 50000)
    }

    @Test func encryptedHeadersNeedPassword() async throws {
        await #expect(throws: ArchiveError.passwordRequired(entry: "")) {
            _ = try await Archive.open(Fixtures.url("encrypted.7z"))
        }
        await #expect(throws: ArchiveError.wrongPassword(entry: "")) {
            _ = try await Archive.open(Fixtures.url("encrypted.7z"), passwords: ["nope"])
        }
        let archive = try await Archive.open(Fixtures.url("encrypted.7z"), passwords: ["secret"])
        #expect(try await archive.snapshot().isEncrypted)
        #expect(String(decoding: try await archive.data(for: "hello.txt"), as: UTF8.self) == "Hello, Arca!\n")
    }

    @Test func edits7z() async throws {
        let s = try Scratch()
        let url = try Fixtures.copy("sample.7z", to: s.url)
        let archive = try await Archive.open(url)
        let notes = try await archive.data(for: "docs/notes.md")
        let added = try s.file("added.txt", "added")
        let snapshot = try await archive.apply([
            .add(source: added, at: "new/added.txt"),
            .delete("docs/data.bin"),
            .rename(from: "docs", to: "documents"),
            .addData(Data("replaced".utf8), at: "hello.txt"),
            .makeDirectory("empty"),
        ])
        let paths = Set(snapshot.entries.map(\.path))
        #expect(paths == ["hello.txt", "documents", "documents/notes.md", "new", "new/added.txt", "empty"])
        #expect(try await archive.data(for: "documents/notes.md") == notes)
        #expect(String(decoding: try await archive.data(for: "hello.txt"), as: UTF8.self) == "replaced")
    }

    @Test func createsEncrypted7z() async throws {
        let s = try Scratch()
        _ = try s.file("src/a.txt", "alpha")
        let url = s.path("out.7z")
        _ = try await Archive.compress([s.path("src")], into: url, format: .sevenZip,
                                       options: WriteOptions(encryption: .aes256(password: "pw")))
        await #expect(throws: ArchiveError.passwordRequired(entry: "")) { _ = try await Archive.open(url) }
        let reopened = try await Archive.open(url, passwords: ["pw"])
        #expect(String(decoding: try await reopened.data(for: "src/a.txt"), as: UTF8.self) == "alpha")
    }

    @Test func failedEditLeavesArchiveUntouched() async throws {
        let s = try Scratch()
        let url = try Fixtures.copy("sample.7z", to: s.url)
        let before = try Data(contentsOf: url)
        let archive = try await Archive.open(url)
        await #expect(throws: (any Error).self) {
            _ = try await archive.apply([.delete("hello.txt"), .add(source: s.path("missing.txt"), at: "x.txt")])
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func readsWIMAndExtracts() async throws {
        let s = try Scratch()
        let archive = try await Archive.open(Fixtures.url("sample.wim"))
        let snapshot = try await archive.snapshot()
        #expect(snapshot.format == .wim)
        #expect(snapshot.editingMode == .readOnly)
        let urls = try await archive.extract(["docs"], to: s.path("out"))
        #expect(urls.map(\.lastPathComponent) == ["docs"])
        #expect(try Data(contentsOf: s.path("out/docs/data.bin")).count == 50000)
    }

    @Test func zipWithPPMdEntriesUsesSevenZipForThoseOnly() async throws {
        let s = try Scratch()
        let url = try Fixtures.copy("ppmd.zip", to: s.url)
        let archive = try await Archive.open(url, journal: s.journal)
        #expect(try await archive.snapshot().editingMode == .inPlace)
        let notes = try await archive.data(for: "docs/notes.md")
        #expect(notes.count == 13508)
        _ = try await archive.apply([.addData(Data("new".utf8), at: "new.txt")])
        #expect(try await archive.data(for: "docs/notes.md") == notes)
    }

    @Test func detectsByContentNotExtension() async throws {
        let s = try Scratch()
        let disguised = s.path("comic.cbz")   // actually a 7z
        try FileManager.default.copyItem(at: Fixtures.url("sample.7z"), to: disguised)
        let snapshot = try await Archive.open(disguised).snapshot()
        #expect(snapshot.format == .sevenZip)
    }
}

@Suite(.enabled(if: hasRAR, "rar and 7zz not installed"))
struct RARTests {
    @Test func readsAndEditsRAR() async throws {
        let s = try Scratch()
        let url = try Fixtures.copy("sample.rar", to: s.url)
        let archive = try await Archive.open(url)
        let snapshot = try await archive.snapshot()
        #expect(snapshot.format == .rar5)
        #expect(snapshot.editingMode.isEditable)
        let updated = try await archive.apply([
            .rename(from: "docs", to: "d2"),
            .delete("hello.txt"),
            .addData(Data("x".utf8), at: "x/n.txt"),
        ])
        #expect(Set(updated.entries.filter { !$0.isDirectory }.map(\.path)) == ["d2/notes.md", "d2/data.bin", "x/n.txt"])
        #expect(!updated.entries.contains { $0.isEncrypted })
        #expect(try await archive.data(for: "d2/data.bin").count == 50000)
    }

    @Test func encryptedRAR() async throws {
        await #expect(throws: ArchiveError.passwordRequired(entry: "")) {
            _ = try await Archive.open(Fixtures.url("encrypted.rar"))
        }
        let archive = try await Archive.open(Fixtures.url("encrypted.rar"), passwords: ["secret"])
        #expect(String(decoding: try await archive.data(for: "hello.txt"), as: UTF8.self) == "Hello, Arca!\n")
    }

    @Test func createsRAR() async throws {
        let s = try Scratch()
        _ = try s.file("src/a.txt", "alpha")
        let url = s.path("new.rar")
        let archive = try await Archive.compress([s.path("src")], into: url, format: .rar)
        #expect(Set(try await archive.snapshot().entries.map(\.path)) == ["src", "src/a.txt"])
    }
}
