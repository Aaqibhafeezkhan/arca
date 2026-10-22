import Foundation

/// Uses the app bundle's preferred system language, falling back to English.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: arguments)
}

func itemCount(_ count: Int) -> String {
    LF(count == 1 ? "%lld item" : "%lld items", Int64(count))
}

import ArcaKit

func localizedError(_ error: Error) -> String {
    guard let error = error as? ArchiveError else { return error.localizedDescription }
    switch error {
    case let .io(path, code): return LF("I/O error on %@: %@", path, String(cString: strerror(code)))
    case let .notAnArchive(path): return LF("%@ is not a supported archive.", path)
    case let .corrupted(reason): return LF("The archive is damaged: %@", reason)
    case let .unsupported(reason): return LF("Unsupported: %@", reason)
    case let .passwordRequired(entry): return entry.isEmpty ? L("This archive is password protected.") : LF("“%@” is password protected.", entry)
    case let .wrongPassword(entry): return entry.isEmpty ? L("Wrong password.") : LF("Wrong password for “%@”.", entry)
    case let .checksumMismatch(entry): return LF("Checksum mismatch for “%@”. The data is corrupted.", entry)
    case let .entryNotFound(path): return LF("“%@” does not exist in the archive.", path)
    case let .entryExists(path): return LF("“%@” already exists in the archive.", path)
    case let .invalidPath(path): return LF("Invalid path: %@", path)
    case let .readOnly(format): return LF("%@ archives can't be modified.", format)
    case .modifiedExternally: return L("The archive was modified by another application. Reopen it to continue.")
    case .cancelled: return L("The operation was cancelled.")
    case let .libarchive(message), let .toolFailed(message): return message
    }
}

func localizedNote(_ note: String, format: String) -> String {
    let archive = "\(format) archives are read-only. You can browse, preview and extract individual items."
    let files = "\(format) files are read-only. You can browse, preview and extract individual items."
    let rewrite = "Changes to \(format) archives are applied by re-streaming the archive: the outer compression is redone, but nothing is extracted to disk."
    if note == rewrite { return LF("Changes to %@ archives are applied by re-streaming the archive: the outer compression is redone, but nothing is extracted to disk.", format) }
    if note == archive { return LF("%@ archives are read-only. You can browse, preview and extract individual items.", format) }
    if note == files { return LF("%@ files are read-only. You can browse, preview and extract individual items.", format) }
    return L(note)
}
