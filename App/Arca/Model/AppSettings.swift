import ArcaKit
import Foundation
import Observation

enum ExtractionDestination: String, CaseIterable, Identifiable {
    case ask, nextToArchive, downloads
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Ask every time"
        case .nextToArchive: "Next to the archive"
        case .downloads: "Downloads folder"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    var compressionLevel: Int { didSet { defaults.set(compressionLevel, forKey: "compressionLevel") } }
    var storeCompressedMedia: Bool { didSet { defaults.set(storeCompressedMedia, forKey: "storeCompressedMedia") } }
    var excludeMacMetadata: Bool { didSet { defaults.set(excludeMacMetadata, forKey: "excludeMacMetadata") } }
    /// Write edits from external apps back without asking.
    var autoWriteBack: Bool { didSet { defaults.set(autoWriteBack, forKey: "autoWriteBack") } }
    var autoCompact: Bool { didSet { defaults.set(autoCompact, forKey: "autoCompact") } }
    var revealAfterExtract: Bool { didSet { defaults.set(revealAfterExtract, forKey: "revealAfterExtract") } }
    var extractionDestination: ExtractionDestination {
        didSet { defaults.set(extractionDestination.rawValue, forKey: "extractionDestination") }
    }
    var defaultFormat: ArchiveFormat { didSet { defaults.set(defaultFormat.rawValue, forKey: "defaultFormat") } }

    private init() {
        defaults.register(defaults: [
            "compressionLevel": 6, "storeCompressedMedia": true, "excludeMacMetadata": true,
            "autoWriteBack": false, "autoCompact": true, "revealAfterExtract": true,
            "extractionDestination": ExtractionDestination.ask.rawValue, "defaultFormat": ArchiveFormat.zip.rawValue,
        ])
        compressionLevel = defaults.integer(forKey: "compressionLevel")
        storeCompressedMedia = defaults.bool(forKey: "storeCompressedMedia")
        excludeMacMetadata = defaults.bool(forKey: "excludeMacMetadata")
        autoWriteBack = defaults.bool(forKey: "autoWriteBack")
        autoCompact = defaults.bool(forKey: "autoCompact")
        revealAfterExtract = defaults.bool(forKey: "revealAfterExtract")
        extractionDestination = ExtractionDestination(rawValue: defaults.string(forKey: "extractionDestination") ?? "") ?? .ask
        defaultFormat = ArchiveFormat(rawValue: defaults.string(forKey: "defaultFormat") ?? "") ?? .zip
    }

    func writeOptions(password: String?) -> WriteOptions {
        WriteOptions(compressionLevel: compressionLevel,
                     encryption: password.map { .aes256(password: $0) } ?? .none,
                     storeCompressedMedia: storeCompressedMedia,
                     excludeMacMetadata: excludeMacMetadata)
    }
}
