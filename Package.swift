// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArcaKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArcaKit", targets: ["ArcaKit"]),
        .executable(name: "arca", targets: ["arca"]),
    ],
    targets: [
        .systemLibrary(name: "CArchive", path: "Sources/CArchive"),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "ArcaKit", dependencies: ["CArchive", "CZlib"]),
        .executableTarget(name: "arca", dependencies: ["ArcaKit"]),
        .testTarget(name: "ArcaKitTests", dependencies: ["ArcaKit"], resources: [.copy("Fixtures")]),
    ]
)
