// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DockPopover",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DockPopover",
            path: "Sources/DockPopover"
        )
    ]
)
