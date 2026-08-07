// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ScreenRecordHost",
    platforms: [.macOS("15.0")],
    targets: [
        .target(
            name: "CameraSessionBridge",
            path: "Sources/CameraSessionBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "ScreenRecordHost",
            dependencies: ["CameraSessionBridge"],
            path: "Sources/ScreenRecordHost"
        )
    ]
)
