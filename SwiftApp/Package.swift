// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "M3U8Downloader",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "M3U8Downloader",
            path: "Sources/M3U8Downloader"
        )
    ]
)