// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tiles",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Tiles", targets: ["Tiles"])],
    targets: [.executableTarget(name: "Tiles")]
)
