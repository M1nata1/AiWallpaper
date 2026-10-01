// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AiWallpaper",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AiWallpaper", targets: ["AiWallpaper"])
    ],
    targets: [
        // Media import, conversion and the wallpaper library. No UI code.
        .target(
            name: "WallpaperCore",
            path: "Sources/WallpaperCore"
        ),
        // The menu bar app: desktop windows, playback engine and SwiftUI screens.
        .executableTarget(
            name: "AiWallpaper",
            dependencies: ["WallpaperCore"],
            path: "Sources/AiWallpaper"
        ),
        .testTarget(
            name: "WallpaperCoreTests",
            dependencies: ["WallpaperCore"],
            path: "Tests/WallpaperCoreTests"
        )
    ]
)
