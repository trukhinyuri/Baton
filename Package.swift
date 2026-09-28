// swift-tools-version: 6.0
import PackageDescription

// The app's target is BatonApp, not Baton: on the default case-insensitive macOS disk, a Baton target and the baton
// CLI would share one source folder and one build product. scripts/build-app.sh puts it in Baton.app/Contents/MacOS/Baton.
let package = Package(
    name: "Baton",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BatonApp", targets: ["BatonApp"]),
        .executable(name: "baton", targets: ["baton"]),
        .library(name: "BatonKit", targets: ["BatonKit"]),
    ],
    targets: [
        .target(name: "BatonKit"),
        .executableTarget(name: "BatonApp", dependencies: ["BatonKit"]),
        .executableTarget(name: "baton", dependencies: ["BatonKit"]),
        .testTarget(name: "BatonKitTests", dependencies: ["BatonKit"], resources: [.copy("Fixtures")]),
    ]
)
