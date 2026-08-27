// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mumble",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Parakeet TDT as CoreML on the Neural Engine. Optional at runtime — Apple's
        // SpeechTranscriber remains the default and needs no dependency at all.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")
    ],
    targets: [
        // The dictionary is its own target so it can be tested directly, and because its
        // behaviour is a cross-platform contract: the Windows app reimplements this logic in
        // C#, and both sides run the same vectors in shared/dictionary-test-vectors.json.
        .target(
            name: "MumbleDictionary",
            path: "Sources/MumbleDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The cleanup guard is its own target for the same reason the dictionary is: so it
        // can be tested without the app. It is the one piece here with a security argument
        // behind it — it is what stops a model answering your dictation instead of cleaning
        // it — and the app links FoundationModels, which CI's older macOS cannot load. A
        // test bundle that reaches the app is a test bundle that never runs there.
        .target(
            name: "MumbleCleanup",
            path: "Sources/MumbleCleanup",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Mumble",
            dependencies: [
                "MumbleDictionary",
                "MumbleCleanup",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Mumble",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MumbleCleanupTests",
            dependencies: ["MumbleCleanup"],
            path: "Tests/MumbleCleanupTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MumbleDictionaryTests",
            dependencies: ["MumbleDictionary"],
            path: "Tests/MumbleDictionaryTests",
            resources: [.copy("dictionary-test-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
