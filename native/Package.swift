// swift-tools-version: 5.10
// speaker-native: speaker labelling (pyannote models in Core ML, via SpeakerKit)
// on the Neural Engine / GPU. Never touches the network at run time — models
// are fetched once, at build time, by `speaker-native fetch-models`.
import PackageDescription

let package = Package(
    name: "SpeakerNative",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned exactly so builds are reproducible (same policy as requirements.lock).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "speaker-native",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
            ],
            path: "Sources/SpeakerNative"
        ),
    ]
)
