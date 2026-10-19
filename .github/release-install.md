
### Install

1. Download `Arca-<version>.dmg`, open it and drag **Arca** to **Applications**.
2. This preview is signed ad hoc, not notarized. On first launch macOS blocks it: open **System Settings → Privacy & Security** and click **Open Anyway**, or run
   ```bash
   xattr -dr com.apple.quarantine /Applications/Arca.app
   ```
3. Optional: `brew install --cask rar` to edit and create RAR archives.

The command-line tool is in `arca-cli-<version>-macos-universal.tar.gz`. Requires macOS 14 or later (Apple silicon and Intel).
