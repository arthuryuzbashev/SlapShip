// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SlapShip",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SlapShip",
            path: "Sources/SlapShip",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("QuartzCore"),
            ]
        )
    ]
)
