// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ScreenRecordHost",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(
            name: "ScreenRecordHost",
            path: "Sources/ScreenRecordHost"
        )
    ]
)
