// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AppSweep",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AppSweep", targets: ["AppSweep"])
    ],
    targets: [
        .executableTarget(
            name: "AppSweep",
            path: "Sources/AppSweep",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Security"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
