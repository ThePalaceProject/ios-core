// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PalaceFoundation",
    platforms: [.iOS(.v16)],
    products: [.library(name: "PalaceFoundation", targets: ["PalaceFoundation"])],
    targets: [.target(name: "PalaceFoundation", path: "Sources")]
)
