# Third-party notices

Arca's own code is released under the [MIT License](LICENSE). It uses or ships the following components under their own licenses.

## 7-Zip (bundled in `Arca.app/Contents/MacOS/7zz`)

Copyright (C) Igor Pavlov. Distributed unmodified as a separate executable.

- Most of the code: **GNU LGPL 2.1 or later**.
- Some code: BSD 3-clause and BSD 2-clause.
- RAR decompression code: GNU LGPL with the **unRAR license restriction** (it may not be used to re-create the RAR compression algorithm).

The full license text ships in `Arca.app/Contents/Resources/7-Zip License.txt`. Source code: <https://www.7-zip.org> and <https://github.com/ip7z/7zip>. The exact version is pinned in `App/Scripts/fetch-7zz.sh`; you can replace the binary with your own build.

## libarchive

Copyright (c) 2003-2018 Tim Kientzle and contributors. **BSD 2-clause.**

Arca links the copy shipped with macOS (`/usr/lib/libarchive.2.dylib`). Its public headers are vendored in `Sources/CArchive/include` with their license notice.

## Not bundled

- **RAR** (`rar`, RARLAB, shareware): used for RAR editing only when the user installs it. Arca never ships it.
- **zlib** and **CommonCrypto** are part of macOS.
