// swift-tools-version:6.0
// DayBar — today's calendar events in the macOS menu bar.
// Build the app: scripts/build-app.sh <out-dir>
import PackageDescription

let package = Package(
    name: "DayBar",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "DayBar",
            path: "Sources/DayBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
