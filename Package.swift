// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpaceLabeler",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SpaceLabeler", targets: ["SpaceLabeler"])],
    targets: [.executableTarget(name: "SpaceLabeler")]
)
