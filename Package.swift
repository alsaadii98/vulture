// swift-tools-version:6.0
// Vulture — a free, open-source cleaner and disk tool for macOS.
// Copyright (C) 2026 Vulture contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "Vulture",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VultureCore", targets: ["VultureCore"]),
        .executable(name: "vulture", targets: ["vulture"]),
    ],
    targets: [
        .target(
            name: "VultureCore",
            resources: [.copy("Rules")]
        ),
        .executableTarget(
            name: "vulture",
            dependencies: ["VultureCore"]
        ),
        .testTarget(
            name: "VultureCoreTests",
            dependencies: ["VultureCore"]
        ),
    ]
)
