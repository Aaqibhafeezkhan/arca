
### Install

1. Download `Arca-<version>.dmg`, open it and drag **Arca** to **Applications**.
2. This preview is signed ad hoc, not notarized. On first launch macOS blocks it: open **System Settings → Privacy & Security** and click **Open Anyway**, or run
   ```bash
   xattr -dr com.apple.quarantine /Applications/Arca.app
   ```
3. Optional: `brew install --cask rar` to edit and create RAR archives.

To enable the bundled shell command after installing the app, run once:

```bash
sudo /Applications/Arca.app/Contents/Resources/install-cli.sh
arca --version
```

Then use `arca list archive.zip` from any directory. The installer links `/usr/local/bin/arca` to the executable in the app, so app updates also update the command. Keep the app in `/Applications`; make sure `/usr/local/bin` is on your `PATH`.

A standalone command-line tool is also in `arca-cli-<version>-macos-universal.tar.gz`. Requires macOS 14 or later (Apple silicon and Intel).
