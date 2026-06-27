// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SnapShotKit",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SnapShotKit",
            path: "Sources/SnapShotKit",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "SnapShotKitTests",
            dependencies: ["SnapShotKit"],
            path: "Tests/SnapShotKitTests"
        )
    ]
)
