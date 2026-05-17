// swift-tools-version: 6.0
// Package.swift — Xenon360
// Xbox 360 JIT-less interpreter emulator for iOS/iPadOS 26

import PackageDescription

let package = Package(
    name: "Xenon360",
    platforms: [
        .iOS(.v26),
        .macCatalyst(.v26),
    ],
    products: [
        .library(
            name: "Xenon360Core",
            targets: ["Xenon360Core"]
        ),
    ],
    dependencies: [],
    targets: [
        // Core emulator library (CPU, Memory, Loader, GPU, Audio)
        .target(
            name: "Xenon360Core",
            path: "Sources/Xenon360",
            sources: [
                "Core/XenonMemory.swift",
                "Core/XenonCPU.swift",
                "Core/PowerPCDisasm.swift",
                "Core/Emulator.swift",
                "Loader/XEXLoader.swift",
                "GPU/XenosGPU.swift",
                "Audio/XenonAudio.swift",
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-O",              // optimize
                    "-whole-module-optimization",
                ], .when(configuration: .release)),
                .define("XENON360_DEBUG", .when(configuration: .debug)),
            ]
        ),

        // Unit tests
        .testTarget(
            name: "Xenon360Tests",
            dependencies: ["Xenon360Core"],
            path: "Tests/Xenon360Tests"
        ),
    ]
)
