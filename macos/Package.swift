// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AndroidWebcam",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AndroidWebcamProtocol", targets: ["AndroidWebcamProtocol"]),
        .library(name: "AndroidWebcamCore", targets: ["AndroidWebcamCore"]),
        .executable(name: "WAMC", targets: ["AndroidWebcamApp"]),
    ],
    targets: [
        .target(name: "AndroidWebcamProtocol"),
        .target(name: "AndroidWebcamCore", dependencies: ["AndroidWebcamProtocol"]),
        .executableTarget(
            name: "AndroidWebcamApp",
            dependencies: ["AndroidWebcamProtocol", "AndroidWebcamCore"],
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("AVFoundation"),
            ]),
        .testTarget(name: "AndroidWebcamTests",
                    dependencies: ["AndroidWebcamProtocol", "AndroidWebcamCore"]),
    ]
)
