// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FSKitSample",
    // platforms: [
    //     .macOS("15.4"),
    // ],
    targets: [
        // Use the local libfuse submodule instead
        // .systemLibrary(name: "clibfuse", pkgConfig: "fuse3", 
        //     providers: [
        //         // .brew(["osxfuse"]),
        //         .apt(["fuse3"]),    
        //     ],
        // ),
        .target(
                name: "clibfuse",
                dependencies: [],
                path: "Sources/clibfuse",
                sources: [
                
                ],
                publicHeadersPath: ".",
                cSettings: [
                ],
                linkerSettings: [
                    // Use static library
                    .unsafeFlags([
                        "-l:libfuse3.a",
                        // "-ldl", "-lrt", "-lpthread"  // Dependencies required by libfuse
                    ])
                ]
        ),
                .target(name: "FSKit"),
        .target(name: "common", dependencies: ["FSKit"],  path: "FSKitExpExtension/common"),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "Fuse", dependencies: ["clibfuse", "FSKit", "common"]),
    ]
)
