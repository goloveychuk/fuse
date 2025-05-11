// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FSKitSample",
    platforms: [
        .macOS("15.4"),
    ],
    targets: [
        // .target(name: "clibfuse",  dependencies: [], publicHeadersPath: "libfuse"),
        .systemLibrary(name: "clibfuse", pkgConfig: "fuse3", providers: [
            // .brew(["osxfuse"]),
            .apt(["libfuse3-dev"]),
        ]),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "Fuse", dependencies: ["clibfuse"]),
    ]
)
