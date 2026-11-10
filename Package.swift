// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ONVIFBrowser",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "ONVIFBrowser", targets: ["ONVIFBrowser"]),
        .executable(name: "onvif-cli", targets: ["onvif-cli"]),
        .library(name: "ONVIFCore", targets: ["ONVIFCore"]),
    ],
    targets: [
        .target(name: "ONVIFCore"),
        .executableTarget(
            name: "ONVIFBrowser",
            dependencies: ["ONVIFCore"],
            linkerSettings: [
                // The app bundle ships libswift_Concurrency.dylib in Contents/Frameworks
                // for macOS 10.15 / 11, where the OS does not provide it.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .executableTarget(name: "onvif-cli", dependencies: ["ONVIFCore"]),
        .testTarget(name: "ONVIFCoreTests", dependencies: ["ONVIFCore"]),
    ]
)
