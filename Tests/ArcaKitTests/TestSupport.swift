import Foundation
@testable import ArcaKit

enum Fixtures {
    static func url(_ name: String) -> URL {
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
    }

    /// Copies a fixture into a scratch dir so tests can modify it.
    static func copy(_ name: String, to dir: URL) throws -> URL {
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url(name), to: dest)
        return dest
    }
}

final class Scratch {
    let url: URL
    let journal: JournalStore

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("arca-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        journal = JournalStore(directory: url.appendingPathComponent(".journals"))
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String, _ contents: String) throws -> URL {
        let u = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: u)
        return u
    }

    func file(_ name: String, bytes: Int, seed: UInt64 = 1) throws -> URL {
        var rng = SplitMix(seed: seed)
        let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let u = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        return u
    }

    func path(_ name: String) -> URL { url.appendingPathComponent(name) }
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

func bytes(fromHex s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

/// Runs an external tool if installed; nil when unavailable.
@discardableResult
func runTool(_ tool: String, _ args: [String]) -> (status: Int32, output: String)? {
    let candidates = ["/usr/bin/\(tool)", "/bin/\(tool)", "/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"]
    guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Hand-assembles a stored-only ZIP so tests can include names our writer
/// refuses to produce (e.g. path traversal).
func handcraftedZip(_ files: [(name: String, data: [UInt8])]) -> [UInt8] {
    var body: [UInt8] = []
    var central: [UInt8] = []
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    for f in files {
        let name = Array(f.name.utf8)
        let crc = CRC32.checksum(f.data)
        let offset = UInt32(body.count)
        body += le32(0x0403_4b50) + le16(10) + le16(0) + le16(0) + le16(0) + le16(0x21) + le32(crc)
        body += le32(UInt32(f.data.count)) + le32(UInt32(f.data.count)) + le16(name.count) + le16(0) + name + f.data
        central += le32(0x0201_4b50) + le16(20) + le16(10) + le16(0) + le16(0) + le16(0) + le16(0x21) + le32(crc)
        central += le32(UInt32(f.data.count)) + le32(UInt32(f.data.count)) + le16(name.count) + le16(0) + le16(0)
        central += le16(0) + le16(0) + le32(0) + le32(offset) + name
    }
    let eocd = le32(0x0605_4b50) + le16(0) + le16(0) + le16(files.count) + le16(files.count)
        + le32(UInt32(central.count)) + le32(UInt32(body.count)) + le16(0)
    return body + central + eocd
}
