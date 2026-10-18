// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AndroidWebcam",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AndroidWebcamProtocol", targets: ["AndroidWebcamProtocol"]),
        .library(name: "AndroidWebcamCore", targets: ["AndroidWebcamCore"]),
        .library(name: "AndroidWebcamAppRuntime", targets: ["AndroidWebcamAppRuntime"]),
        .executable(name: "WAMC", targets: ["WAMCLauncher"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "AndroidWebcamProtocol"),
        .target(name: "AndroidWebcamCore", dependencies: ["AndroidWebcamProtocol"]),
        .target(
            name: "CameraExtensionRuntime",
            dependencies: ["AndroidWebcamCore"],
            path: "CameraExtension",
            exclude: ["README.md", "project.yml", "CameraExtension-Info.plist", "CameraExtension.entitlements"],
            swiftSettings: [.define("WAMC_COVERAGE_TESTING")],
            linkerSettings: [
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]),
        .target(
            name: "AndroidWebcamAppRuntime",
            dependencies: ["AndroidWebcamProtocol", "AndroidWebcamCore",
                           .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/AndroidWebcamApp",
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreMediaIO"),
                .linkedFramework("AVFoundation"),
            ]),
        .executableTarget(
            name: "WAMCLauncher",
            dependencies: ["AndroidWebcamAppRuntime"],
            path: "Entrypoints",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]),
        .target(
            name: "WAMCLauncherTestSupport",
            dependencies: ["AndroidWebcamAppRuntime"],
            path: "Tests/WAMCLauncherTestSupport",
            swiftSettings: [.define("WAMC_COVERAGE_TESTING")]),
        .testTarget(name: "AndroidWebcamTests",
                    dependencies: ["AndroidWebcamProtocol", "AndroidWebcamCore", "AndroidWebcamAppRuntime",
                                   "CameraExtensionRuntime", "WAMCLauncherTestSupport"]),
    ]
)
