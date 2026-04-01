import Foundation

/// Protocol for the AI-powered discovery engine.
protocol DiscoveryServiceProtocol: Sendable {
    /// Get AI-powered book recommendations based on a discovery prompt.
    func getRecommendations(prompt: DiscoveryPrompt) async throws -> [DiscoveryRecommendation]

    /// Check if the service is available (e.g., API key configured, network reachable).
    var isAvailable: Bool { get }
}

/// Errors specific to the discovery service.
enum DiscoveryError: Error, LocalizedError {
    case apiKeyNotConfigured
    case networkUnavailable
    case rateLimited(retryAfterSeconds: Int?)
    case invalidResponse
    case serverError(statusCode: Int, message: String?)
    case searchFailed(underlyingError: Error)
    case noLibrariesConfigured
    case allLibrariesFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .apiKeyNotConfigured:
            return NSLocalizedString("AI discovery is not configured. Please set up your API key in Settings.", comment: "Discovery error")
        case .networkUnavailable:
            return NSLocalizedString("Network is unavailable. Please check your connection.", comment: "Discovery error")
        case .rateLimited(let seconds):
            if let seconds {
                return String(format: NSLocalizedString("Too many requests. Please try again in %d seconds.", comment: "Discovery rate limit error"), seconds)
            }
            return NSLocalizedString("Too many requests. Please try again later.", comment: "Discovery rate limit error")
        case .invalidResponse:
            return NSLocalizedString("Received an unexpected response. Please try again.", comment: "Discovery error")
        case .serverError(_, let message):
            return message ?? NSLocalizedString("Server error. Please try again later.", comment: "Discovery error")
        case .searchFailed(let error):
            return String(format: NSLocalizedString("Search failed: %@", comment: "Discovery search error"), error.localizedDescription)
        case .noLibrariesConfigured:
            return NSLocalizedString("No libraries are configured. Please add a library first.", comment: "Discovery error")
        case .allLibrariesFailed:
            return NSLocalizedString("Could not reach any of your libraries. Please try again.", comment: "Discovery error")
        case .cancelled:
            return NSLocalizedString("Search was cancelled.", comment: "Discovery error")
        }
    }
}
