// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PalaceNetworking",
    platforms: [.iOS(.v16)],
    products: [.library(name: "PalaceNetworking", targets: ["PalaceNetworking"])],
    dependencies: [.package(path: "../PalaceFoundation")],
    targets: [.target(name: "PalaceNetworking", dependencies: ["PalaceFoundation"], path: "Sources")]
)
