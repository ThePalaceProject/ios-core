// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PalaceTriageBot",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
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
        // Source targets → Swift 6 mode (race-checked). Test targets → v5 to
        // avoid test-infra churn (XCTestCase isn't Sendable). See #1130.
        .target(
            name: "TriageBotCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TriageBotIOS",
            dependencies: ["TriageBotCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "TriageBotUI",
            dependencies: ["TriageBotCore", "TriageBotIOS"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TriageBotCoreTests",
            dependencies: ["TriageBotCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TriageBotUITests",
            dependencies: ["TriageBotUI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
