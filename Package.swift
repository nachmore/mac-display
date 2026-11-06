// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mac-display",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "mac-display",
            path: "Sources/mac-display",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
