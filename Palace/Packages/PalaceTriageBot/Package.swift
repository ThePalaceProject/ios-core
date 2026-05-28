// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PalaceTriageBot",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        .macOS(.v12)
    ],
    products: [
        // Pure-Swift business logic. No UIKit / SwiftUI / Firebase. KMP-portable
        // contract — every type and protocol in this product has a 1:1 Kotlin
        // analogue and the bundled catalog.json is the shared schema.
        .library(
            name: "TriageBotCore",
            targets: ["TriageBotCore"]
        ),
        // iOS-native adapters that implement TriageBotCore's protocols
        // (ContextProvider, TelemetrySink, TicketGateway). Pulls in UIKit,
        // OSLog, FeatureFlag wiring. Android writes its own version.
        .library(
            name: "TriageBotIOS",
            targets: ["TriageBotIOS"]
        ),
        // SwiftUI chat surface. Inherently per-platform — Android writes
        // Compose. UI shape is documented in README so both stay aligned.
        .library(
            name: "TriageBotUI",
            targets: ["TriageBotUI"]
        )
    ],
    targets: [
        .target(
            name: "TriageBotCore",
            resources: [.process("Resources")]
        ),
        .target(
            name: "TriageBotIOS",
            dependencies: ["TriageBotCore"]
        ),
        .target(
            name: "TriageBotUI",
            dependencies: ["TriageBotCore", "TriageBotIOS"]
        ),
        .testTarget(
            name: "TriageBotCoreTests",
            dependencies: ["TriageBotCore"]
        ),
        .testTarget(
            name: "TriageBotUITests",
            dependencies: ["TriageBotUI"]
        )
    ]
)
