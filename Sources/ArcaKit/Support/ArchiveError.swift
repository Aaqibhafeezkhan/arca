import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ArchiveError: Error, Sendable, Equatable, LocalizedError {
    case io(path: String, code: Int32)
    case notAnArchive(String)
    case corrupted(String)
    case unsupported(String)
    case passwordRequired(entry: String)
    case wrongPassword(entry: String)
    case checksumMismatch(entry: String)
    case entryNotFound(String)
    case entryExists(String)
    case invalidPath(String)
    case readOnly(format: String)
    case modifiedExternally
    case cancelled
    case libarchive(String)
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .io(path, code):
            return "I/O error on \(path): \(String(cString: strerror(code)))"
        case let .notAnArchive(path):
            return "\(path) is not a supported archive."
        case let .corrupted(reason):
            return "The archive is damaged: \(reason)"
        case let .unsupported(what):
            return "Unsupported: \(what)"
        case let .passwordRequired(entry):
            return entry.isEmpty ? "This archive is password protected." : "“\(entry)” is password protected."
        case let .wrongPassword(entry):
            return entry.isEmpty ? "Wrong password." : "Wrong password for “\(entry)”."
        case let .checksumMismatch(entry):
            return "Checksum mismatch for “\(entry)”. The data is corrupted."
        case let .entryNotFound(path):
            return "“\(path)” does not exist in the archive."
        case let .entryExists(path):
            return "“\(path)” already exists in the archive."
        case let .invalidPath(path):
            return "Invalid path: \(path)"
        case let .readOnly(format):
            return "\(format) archives can't be modified."
        case .modifiedExternally:
            return "The archive was modified by another application. Reopen it to continue."
        case .cancelled:
            return "The operation was cancelled."
        case let .libarchive(message), let .toolFailed(message):
            return message
        }
    }

    public var isPasswordError: Bool {
        switch self {
        case .passwordRequired, .wrongPassword: return true
        default: return false
        }
    }
}
