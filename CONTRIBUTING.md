# Contributing to Arca

Thanks for your interest in Arca! Arca is a native macOS archive manager built with Swift and SwiftUI. Contributions of all sizes are welcome: bug reports, tests, documentation, accessibility improvements, and focused code changes.

## Before you start

- Read the [README](https://github.com/marcovisona/arca) for supported formats, architecture and known limitations.
- Search existing issues and pull requests to avoid duplicate work.
- For a substantial feature or architectural change, open an issue first to discuss scope.
- For a first contribution, look for issues labeled `good first issue` or `help wanted`.

## Build and test

Requirements: macOS 14+ and Xcode 26 (Swift 6.2).

```bash
# Core library and tests
swift test

# macOS app (requires XcodeGen)
brew install xcodegen
cd App
xcodegen
open Arca.xcodeproj
```

The first app build may download a pinned 7-Zip binary and verify its checksum. The core can also be built and tested on Linux with `libarchive-dev` and `zlib1g-dev` installed.

## Reporting bugs

Please include:

- macOS version, chip architecture (Apple silicon/Intel), and Arca version or commit;
- the archive format and operation involved;
- clear reproduction steps, expected behavior and actual behavior;
- relevant console output or screenshots, if available.

**Privacy:** do not upload confidential archives, passwords or personal data. Provide a minimal synthetic sample when possible.

## Submitting a pull request

1. Fork the repository and create a branch with a descriptive name.
2. Keep the change focused; avoid unrelated refactors.
3. Add or update tests when behavior changes, especially for archive integrity and recovery.
4. Run `swift test`; for UI changes, test the macOS app as well.
5. Open a pull request explaining the problem, the solution and how you tested it. Include before/after screenshots for UI changes.
6. Link the relevant issue (for example, `Closes #123`) if applicable.

Archive integrity matters: modifications must never silently corrupt user data. Preserve or extend transactional/rollback guarantees when touching archive-writing code.

## Code and collaboration

- Follow the surrounding Swift/SwiftUI conventions and existing project structure.
- Prefer understandable changes and meaningful tests over broad rewrites.
- Be respectful and constructive in issues, reviews and discussions.
- Maintainers may suggest changes before merging; submission does not guarantee acceptance.

## Licensing

By submitting a contribution, you agree to license it under Arca's [MIT license](https://github.com/marcovisona/arca/blob/main/LICENSE). Do not submit code or assets that you do not have the right to contribute.
