// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FSKitSample2",
    platforms: [
        .macOS("15.0"),
    ],
    // dependencies: [
    //     .package(path: "../fskit")
    // ],
    targets: [
        .executableTarget(
            name: "FSKitSample",
            // dependencies: [
            //     .product(name: "FSKit", package: "fskit"),
            //     .product(name: "common", package: "fskit")
            // ],
            path: ".",
            sources: ["Benchmark.swift"]
        )
    ]
) 