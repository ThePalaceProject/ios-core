import Foundation

/// Protocol for AI Discovery configuration, injectable for testing.
/// Reads API keys and settings from UserDefaults and environment variables.
/// NEVER hardcodes API keys.
protocol DiscoveryConfiguration: Sendable {
    var apiKey: String? { get }
    var endpoint: URL { get }
    var model: String { get }
    var isEnabled: Bool { get }
    var isAIAvailable: Bool { get }
    var maxRecommendations: Int { get }
    var requestTimeout: TimeInterval { get }
}

/// Default production implementation that reads from UserDefaults/environment.
struct DefaultDiscoveryConfiguration: DiscoveryConfiguration {
    private static let apiKeyDefaultsKey = "DiscoveryClaudeAPIKey"
    private static let endpointDefaultsKey = "DiscoveryClaudeEndpoint"
    private static let modelDefaultsKey = "DiscoveryClaudeModel"
    private static let enabledDefaultsKey = "DiscoveryFeatureEnabled"

    /// The Claude API key -- checked in order: UserDefaults, environment variable, Info.plist.
    var apiKey: String? {
        if let key = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey), !key.isEmpty {
            return key
        }
        if let key = ProcessInfo.processInfo.environment["CLAUDE_API_KEY"], !key.isEmpty {
            return key
        }
        if let key = Bundle.main.object(forInfoDictionaryKey: "ClaudeAPIKey") as? String, !key.isEmpty {
            return key
        }
        return nil
    }

    /// The Claude API endpoint. Defaults to the public Anthropic API.
    var endpoint: URL {
        if let urlString = UserDefaults.standard.string(forKey: Self.endpointDefaultsKey),
           let url = URL(string: urlString) {
            return url
        }
        return URL(string: "https://api.anthropic.com/v1/messages")!
    }

    /// The Claude model to use.
    var model: String {
        UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? "claude-sonnet-4-20250514"
    }

    /// Whether the discovery feature is enabled.
    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true
    }

    /// Whether AI recommendations are available (requires API key).
    var isAIAvailable: Bool {
        apiKey != nil && isEnabled
    }

    /// Maximum number of recommendations per request.
    let maxRecommendations: Int = 20

    /// Request timeout in seconds.
    let requestTimeout: TimeInterval = 30

    // MARK: - Setters (for Settings UI)

    static func setAPIKey(_ key: String?) {
        UserDefaults.standard.set(key, forKey: apiKeyDefaultsKey)
    }

    static func setEndpoint(_ url: URL?) {
        UserDefaults.standard.set(url?.absoluteString, forKey: endpointDefaultsKey)
    }

    static func setModel(_ model: String?) {
        UserDefaults.standard.set(model, forKey: modelDefaultsKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)
    }
}
