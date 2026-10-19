# Changelog

All notable changes to Arca are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-19

First public preview.

### Highlights

- **Edit archives without unpacking them.** Add, replace, rename and delete entries in ZIP files in place: only the new bytes are written, untouched entries are never read or recompressed.
- **Crash-safe by design.** Every ZIP commit is journaled; a crash, power loss or cancellation rolls the archive back byte for byte.
- **Live editing in any app.** Double-click an entry, edit it in its app, save: the change is written back into the archive.
- **7z and RAR** through their authors' engines. 7-Zip is bundled; RAR editing uses RARLAB's `rar` when installed.

### Added

- ZIP family (ZIP, JAR, APK, IPA, DOCX/XLSX/PPTX, EPUB, CBZ, APPX/MSIX…): in-place editing, ZIP64, WinZip AES-256 read/write, ZipCrypto read, compaction of dead space (manual or automatic past 40%).
- 7z and CB7: browse, edit, create, AES-256 with encrypted file names; only touched solid blocks are recompressed.
- RAR 4/5 and CBR: read (encrypted and multi-volume included); edit and create with `rar` installed.
- TAR, CBT and TAR.GZ/BZ2/XZ/ZST/LZ4: streaming rewrite with staged changes applied in one pass (⌘S).
- Read-only: DMG (mounted invisibly via `hdiutil`, encrypted images too), ISO, UDF, WIM, VHD/VHDX, MSI, SquashFS, CHM, ARJ, CAB, XAR/PKG/XIP, CPIO, RPM, DEB/AR, LHA, single-file .gz/.bz2/.xz/.zst.
- Format detection by content, not extension.
- Nested archives open in their own window; edits flow back into the parent archive.
- SwiftUI app: sidebar tree, Finder-style table with compression ratio, inspector with Quick Look preview, search across the whole archive, drag & drop in both directions, progress with cancellation, Liquid Glass on macOS 26.
- Create new archives (ZIP, 7z, TAR family, RAR with `rar`), optionally encrypted.
- Quick Look extension for archive contents in Finder; Finder Services "Compress with Arca" and "Extract with Arca".
- `arca` command-line tool: list, info, cat, extract, add, rm, mv, mkdir, compact, create.

### Known limitations

- Builds are signed ad hoc, not notarized yet (see the install notes below).
- Image and installer formats (DMG, ISO, WIM, VHD, MSI…) are read-only.
- VHD/VHDX, MSI, SquashFS, CHM, ARJ and UDF are read through 7-Zip and haven't been tested against real-world samples yet.
- Staged, unapplied changes to tar.* archives are lost when the window closes.

[0.1.0]: https://github.com/marcovisona/symmetrical-waddle/releases/tag/v0.1.0
