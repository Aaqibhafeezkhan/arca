import ArcaKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            CompressionSettings()
                .tabItem { Label("Compression", systemImage: "archivebox") }
        }
        .frame(width: 500)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Extraction") {
                Picker("Extract to", selection: $settings.extractionDestination) {
                    ForEach(ExtractionDestination.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Reveal extracted items in Finder", isOn: $settings.revealAfterExtract)
            }
            Section {
                Toggle("Update the archive automatically when an opened item is saved", isOn: $settings.autoWriteBack)
            } header: {
                Text("Live editing")
            } footer: {
                Text("Items opened from an archive are watched. When the editing app saves, Arca writes the new version back — instantly for ZIP, on apply for other formats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Compact automatically when more than 40% is reclaimable", isOn: $settings.autoCompact)
            } header: {
                Text("Maintenance")
            } footer: {
                Text("Live edits keep superseded data until the archive is compacted. Compacting copies items as-is, without recompressing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CompressionSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Default format", selection: $settings.defaultFormat) {
                ForEach(ArchiveFormat.creatable, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Compression level", selection: $settings.compressionLevel) {
                Text("Store (none)").tag(0)
                Text("Fastest").tag(1)
                Text("Fast").tag(3)
                Text("Balanced").tag(6)
                Text("Best").tag(9)
            }
            Toggle("Don't recompress media and archives (JPEG, MP4, ZIP…)", isOn: $settings.storeCompressedMedia)
            Toggle("Skip .DS_Store and __MACOSX when adding folders", isOn: $settings.excludeMacMetadata)
        }
        .formStyle(.grouped)
    }
}
