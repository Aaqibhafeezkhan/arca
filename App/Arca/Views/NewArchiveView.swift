import ArcaKit
import SwiftUI
import UniformTypeIdentifiers

/// Files handed over by drops on the Welcome window / Dock.
@MainActor
@Observable
final class NewArchiveModel {
    static let shared = NewArchiveModel()
    var sources: [URL] = []
}

struct NewArchiveView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var model = NewArchiveModel.shared
    @State private var format: ArchiveFormat = .zip
    @State private var level: Double = 6
    @State private var encrypt = false
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var activity: ServiceProgressWindow?

    private var isWorking: Bool { activity != nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ArchiveFormat.creatable, id: \.self) { f in
                            Text(label(for: f)).tag(f)
                        }
                    }
                    LabeledContent("Compression") {
                        VStack(alignment: .leading, spacing: 2) {
                            Slider(value: $level, in: 0...9, step: 1)
                            HStack {
                                Text("Store").font(.caption2)
                                Spacer()
                                Text(levelDescription).font(.caption2.weight(.semibold))
                                Spacer()
                                Text("Smallest").font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(format == .tar)
                }

                Section {
                    Toggle("Encrypt with AES-256", isOn: $encrypt)
                        .disabled(!format.supportsEncryption)
                    if encrypt, format.supportsEncryption {
                        SecureField("Password", text: $password)
                        SecureField("Verify", text: $confirmation)
                        if !confirmation.isEmpty, password != confirmation {
                            Text("The passwords don't match.").font(.caption).foregroundStyle(.red)
                        }
                    }
                } footer: {
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Contents") {
                    if model.sources.isEmpty {
                        Text("Starts empty — drop files onto the window afterwards.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.sources, id: \.self) { url in
                            HStack {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text(url.lastPathComponent).lineLimit(1)
                                Spacer()
                                Button {
                                    model.sources.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button("Add Files…", action: chooseSources)
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)

            Divider()
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") {
                    if let activity { activity.progress.cancel() } else { close() }
                }
                    .keyboardShortcut(.cancelAction)
                Button("Create…", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate || isWorking)
            }
            .padding(14)
        }
        .frame(width: 460)
        .onAppear {
            format = settings.defaultFormat
            level = Double(settings.compressionLevel)
        }
        .onChange(of: format) { _, f in if !f.supportsEncryption { encrypt = false } }
        .onDisappear { activity?.progress.cancel() }
    }

    private func label(for format: ArchiveFormat) -> String {
        switch format {
        case .zip: L("ZIP — universal, live editing")
        case .sevenZip: L("7Z — best compression")
        case .rar: L("RAR — via your installed rar")
        case .tarGzip: L("TAR.GZ — Unix standard")
        case .tarXz: L("TAR.XZ — smallest")
        case .tarZstd: L("TAR.ZST — fast & small")
        case .tarBzip2: "TAR.BZ2"
        case .tar: L("TAR — uncompressed")
        default: format.displayName
        }
    }

    private var footer: String {
        switch format {
        case .zip:
            L("ZIP archives can be edited live: adding, replacing or removing items never recompresses the rest.")
        case .sevenZip:
            L("7z gives the smallest archives. With encryption, file names are hidden too. Edits recompress only the blocks they touch.")
        case .rar:
            L("Created with RARLAB's rar. With encryption, file names are hidden too. RAR can't be empty: add some files.")
        default:
            LF("%@ archives are rewritten in a single streaming pass when you apply changes.", format.displayName)
        }
    }

    private var levelDescription: String {
        switch Int(level) {
        case 0: L("Store")
        case 1...3: L("Fast")
        case 4...6: L("Balanced")
        default: L("Best")
        }
    }

    private var canCreate: Bool {
        (!encrypt || (!password.isEmpty && password == confirmation)) && !(format == .rar && model.sources.isEmpty)
    }

    private func chooseSources() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = L("Add")
        if panel.runModal() == .OK { model.sources += panel.urls.filter { !model.sources.contains($0) } }
    }

    private func create() {
        guard !isWorking else { return }
        let panel = NSSavePanel()
        let stem = model.sources.count == 1 ? model.sources[0].deletingPathExtension().lastPathComponent : L("Archive")
        panel.nameFieldStringValue = "\(stem).\(format.preferredExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let first = model.sources.first { panel.directoryURL = first.deletingLastPathComponent() }
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // NSSavePanel only knows single extensions; make sure "tar.xz" survives.
        if !url.lastPathComponent.lowercased().hasSuffix("." + format.preferredExtension.lowercased()) {
            url = url.deletingPathExtension().appendingPathExtension(format.preferredExtension)
        }

        var options = settings.writeOptions(password: encrypt ? password : nil)
        options.compressionLevel = Int(level)
        let sources = model.sources
        let selectedFormat = format
        let activity = ServiceProgressWindow(title: L("Creating…"), filename: url.lastPathComponent)
        self.activity = activity
        error = nil
        activity.show()
        Task {
            // Keep the destination intact until creation has succeeded, including on cancellation.
            let staging = url.deletingLastPathComponent()
                .appendingPathComponent(".arca-create-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: staging)
                activity.close()
                self.activity = nil
            }
            do {
                guard !activity.progress.isCancelled else { return }
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let temporary = staging.appendingPathComponent(url.lastPathComponent)
                if sources.isEmpty {
                    _ = try await Archive.create(temporary, format: selectedFormat)
                } else {
                    _ = try await Archive.compress(sources, into: temporary, format: selectedFormat, options: options,
                                                   progress: activity.progress)
                }
                guard !activity.progress.isCancelled else { return }
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                try FileManager.default.moveItem(at: temporary, to: url)
                activity.close()
                close()
                WindowRouter.shared.open([url])
            } catch ArchiveError.cancelled {
                // Keep the form and its inputs available for another attempt.
            } catch {
                self.error = localizedError(error)
            }
        }
    }

    private func close() {
        model.sources = []
        password = ""
        confirmation = ""
        dismissWindow(id: WindowID.newArchive)
    }
}
