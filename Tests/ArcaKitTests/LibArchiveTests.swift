import Foundation
import Testing
@testable import ArcaKit

@Suite struct LibArchiveTests {
    @Test func readsTarGz() async throws {
        let archive = try await Archive.open(Fixtures.url("sample.tar.gz"))
        let snapshot = try await archive.snapshot()
        #expect(snapshot.format == .tarGzip)
        #expect(snapshot.editingMode == .streamRewrite(recompresses: true))
        #expect(Set(snapshot.entries.map(\.path)).isSuperset(of: ["hello.txt", "docs/notes.md", "docs/data.bin"]))
        #expect(String(decoding: try await archive.data(for: "hello.txt"), as: UTF8.self) == "Hello, Arca!\n")
    }

    @Test func plainCompressedFileIsSingleEntry() async throws {
        let archive = try await Archive.open(Fixtures.url("hello.txt.gz"))
        let snapshot = try await archive.snapshot()
        #expect(snapshot.format == .gzip)
        #expect(snapshot.editingMode == .readOnly)
        #expect(snapshot.entries.map(\.path) == ["hello.txt"])
        #expect(String(decoding: try await archive.data(for: "hello.txt"), as: UTF8.self) == "Hello, Arca!\n")
    }

    @Test func streamRewriteTarXz() async throws {
        let s = try Scratch()
        let url = try Fixtures.copy("sample.tar.xz", to: s.url)
        let archive = try await Archive.open(url, journal: s.journal)
        let notes = try await archive.data(for: "docs/notes.md")
        let added = try s.file("added.txt", "added")
        let snapshot = try await archive.apply([
            .add(source: added, at: "new/added.txt"),
            .delete("docs/data.bin"),
            .rename(from: "docs", to: "documents"),
            .addData(Data("replaced".utf8), at: "hello.txt"),
        ])
        #expect(snapshot.format == .tarXz)
        let paths = Set(snapshot.entries.map(\.path))
        #expect(paths.contains("documents/notes.md"))
        #expect(!paths.contains("docs/data.bin") && !paths.contains("documents/data.bin"))
        #expect(paths.contains("new/added.txt"))
        #expect(try await archive.data(for: "documents/notes.md") == notes)
        #expect(String(decoding: try await archive.data(for: "hello.txt"), as: UTF8.self) == "replaced")
        if let result = runTool("tar", ["-tJf", url.path]) {
            #expect(result.status == 0)
            #expect(result.output.contains("documents/notes.md"))
        }
    }

    @Test(arguments: [ArchiveFormat.tar, .tarGzip, .tarXz, .tarBzip2])
    func createTarFamily(format: ArchiveFormat) async throws {
        let s = try Scratch()
        let url = s.path("new.\(format.preferredExtension)")
        let archive = try await Archive.create(url, format: format, journal: s.journal)
        #expect(try await archive.snapshot().entries.isEmpty)
        let snapshot = try await archive.apply([.addData(Data("hi".utf8), at: "a/b.txt"), .makeDirectory("empty")])
        #expect(snapshot.format == format)
        #expect(Set(snapshot.entries.map(\.path)) == ["a/b.txt", "empty"])
    }

    @Test func extractTarPreservesStructure() async throws {
        let s = try Scratch()
        let archive = try await Archive.open(Fixtures.url("sample.tar.gz"))
        let urls = try await archive.extract(["docs"], to: s.path("out"))
        #expect(urls.map(\.lastPathComponent) == ["docs"])
        let data = try Data(contentsOf: s.path("out/docs/data.bin"))
        #expect(data.count == 50000)
    }

    @Test func zipEncryptionRejectedForTar() async throws {
        let s = try Scratch()
        let url = try Fixtures.copy("sample.tar.gz", to: s.url)
        let archive = try await Archive.open(url, journal: s.journal)
        await #expect(throws: ArchiveError.self) {
            try await archive.apply([.addData(Data(), at: "x")], options: WriteOptions(encryption: .aes256(password: "p")))
        }
    }
}

@Suite struct ModelTests {
    @Test func treeSynthesisesImplicitFolders() {
        let tree = ArchiveTree(entries: [
            ArchiveEntry(path: "a/b/c.txt", isDirectory: false, uncompressedSize: 10, compressedSize: 5),
            ArchiveEntry(path: "a/d.txt", isDirectory: false, uncompressedSize: 20, compressedSize: 8),
            ArchiveEntry(path: "z", isDirectory: true, uncompressedSize: 0, compressedSize: 0),
        ])
        #expect(tree.children(of: "").map(\.name) == ["a", "z"])
        #expect(tree.node("a")?.uncompressedSize == 30)
        #expect(tree.node("a")?.compressedSize == 13)
        #expect(tree.node("a/b")?.entry == nil)
        #expect(tree.entryPaths(under: "a").sorted() == ["a/b/c.txt", "a/d.txt"])
    }

    @Test func planRejectsTraversalAndConflicts() throws {
        var plan = EditPlan(existing: [("a.txt", false), ("b.txt", false), ("dir", true), ("dir/x", false)],
                            options: .default)
        #expect(throws: ArchiveError.invalidPath("../x")) { try plan.apply(.addData(Data(), at: "../x")) }
        #expect(throws: ArchiveError.entryExists("b.txt")) { try plan.apply(.rename(from: "a.txt", to: "b.txt")) }
        #expect(throws: ArchiveError.invalidPath("dir/sub")) { try plan.apply(.rename(from: "dir", to: "dir/sub")) }
        try plan.apply(.addData(Data(), at: "dir"))
        #expect(plan.survivors.map(\.path).sorted() == ["a.txt", "b.txt", "dir"])
    }

    @Test func normalisation() throws {
        #expect(try ArchivePath.normalize("/a//b/./c/") == "a/b/c")
        #expect(try ArchivePath.normalize("a\\b") == "a/b")
        #expect(throws: ArchiveError.self) { try ArchivePath.normalize("a/../../b") }
    }
}
