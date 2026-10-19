import Foundation

/// Locates the command-line engines Arca delegates to.
///
/// - `7zz` (7-Zip, LGPL): bundled inside Arca.app; 7z/RAR/WIM/MSI/… reading and 7z writing.
/// - `rar` (RARLAB, shareware): never bundled — RAR creation is licensed. Used
///   for RAR editing when the user has installed it (`brew install --cask rar`).
public enum ExternalTools {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrides: [String: URL] = [:]

    /// Lets the app point at its bundled copy (or tests at a specific binary).
    public static func setOverride(_ url: URL?, for tool: String) {
        lock.withLock { overrides[tool] = url }
    }

    public static var sevenZip: URL? { locate("7zz", alternatives: ["7zz", "7z", "7za"], environment: "ARCA_7ZZ") }
    public static var rar: URL? { locate("rar", alternatives: ["rar"], environment: "ARCA_RAR") }

    private static func locate(_ tool: String, alternatives: [String], environment: String) -> URL? {
        let fm = FileManager.default
        if let url = lock.withLock({ overrides[tool] }), fm.isExecutableFile(atPath: url.path) { return url }
        if let path = ProcessInfo.processInfo.environment[environment], fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: tool), fm.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in directories {
            for name in alternatives {
                let path = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }
}

/// Runs a tool to completion, collecting output, honouring cancellation and
/// turning "NN%" progress lines into `ProgressReporter` updates.
enum ToolRunner {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.withLock { data.append(d) } }
        var value: Data { lock.withLock { data } }
    }

    static func run(_ tool: URL, _ arguments: [String], in directory: URL? = nil,
                    progress: ProgressReporter? = nil) throws -> Result {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        // Never let a tool block on an interactive prompt.
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdout = Buffer(), stderr = Buffer()
        out.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            stderr.append(chunk)
            if let progress, let percent = lastPercent(in: chunk) { progress.set(completed: Int64(percent)) }
        }

        try process.run()
        while process.isRunning {
            if progress?.isCancelled == true {
                process.terminate()
                process.waitUntilExit()
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                throw ArchiveError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        stdout.append(out.fileHandleForReading.readDataToEndOfFile())
        stderr.append(err.fileHandleForReading.readDataToEndOfFile())
        if ProcessInfo.processInfo.environment["ARCA_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[\(tool.lastPathComponent)] \(arguments) cwd=\(directory?.path ?? "-") → \(process.terminationStatus) \(process.terminationReason == .uncaughtSignal ? "signal" : "")\n\(String(decoding: stderr.value, as: UTF8.self).suffix(400))\n".utf8))
        }
        return Result(status: process.terminationStatus, stdout: stdout.value,
                      stderr: String(decoding: stderr.value, as: UTF8.self))
    }

    private static func lastPercent(in chunk: Data) -> Int? {
        let text = String(decoding: chunk, as: UTF8.self)
        var result: Int?
        var digits = ""
        for ch in text {
            if ch.isNumber { digits.append(ch) } else {
                if ch == "%", let n = Int(digits), n <= 100 { result = n }
                digits = ""
            }
        }
        return result
    }
}
