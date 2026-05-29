#if canImport(UIKit)
import Foundation
import TriageBotCore

/// Network-backed `FallbackClassifier` that asks Claude (Sonnet 4.6 by
/// default) to match the user's description against the bundled KB. Only
/// invoked when the local keyword classifier returns `.escalate` AND the
/// `triage_bot_ai_fallback_enabled` Firebase RC flag is on.
///
/// Sterilization runs FIRST: the user's text is passed through
/// `AIFallbackPromptBuilder.sanitize` (which applies `ContextRedactor`'s
/// patterns) before being embedded in the prompt. Bearer/Basic/OAuth/SAML
/// credentials, barcode/PIN values, email addresses, and UUIDs are stripped
/// before any byte leaves the device. Verified by
/// `AIFallbackPromptBuilderTests.testSanitize_stripsAllRedactorPatterns`.
///
/// Failure modes (offline, timeout, missing API key, rate limit, parse error)
/// all surface as `FallbackError`, which the ViewModel translates to
/// `ConversationAction.aiFallbackUnavailable`. Net result: a fallback failure
/// looks identical to the local-only escalate path from the user's POV.
public final class ClaudeFallbackClassifier: FallbackClassifier {

    public enum Model: String, Sendable {
        case sonnet46 = "claude-sonnet-4-6"
        case haiku45 = "claude-haiku-4-5-20251001"
        case opus47 = "claude-opus-4-7"
    }

    private let keyProvider: @Sendable () -> String?
    private let model: Model
    private let session: URLSession
    private let timeout: TimeInterval
    private let rateLimiter: FallbackRateLimiter

    /// - Parameters:
    ///   - keyProvider: closure that returns the current API key (or nil if
    ///     unavailable). Production passes `{ AnthropicKeyStore().read() }`
    ///     so the key is fetched from Keychain on every call — never held
    ///     in-memory beyond the duration of the request. Tests inject a
    ///     stub.
    ///   - rateLimiter: caps calls per minute + per session. Defaults to
    ///     conservative limits so even a runaway UI loop can't run up the
    ///     bill.
    public init(
        keyProvider: @escaping @Sendable () -> String?,
        model: Model = .sonnet46,
        timeout: TimeInterval = 8,
        session: URLSession = .shared,
        rateLimiter: FallbackRateLimiter = FallbackRateLimiter()
    ) {
        self.keyProvider = keyProvider
        self.model = model
        self.timeout = timeout
        self.session = session
        self.rateLimiter = rateLimiter
    }

    public func classify(
        userText: String,
        category: KBCategory?,
        context: ContextSnapshot?,
        knowledgeBase kb: KnowledgeBase
    ) async throws -> ClassificationResult {
        guard rateLimiter.record() else {
            throw FallbackError.rateLimited
        }
        guard let apiKey = keyProvider(), !apiKey.isEmpty else {
            throw FallbackError.apiKeyMissing
        }

        // Sterilize first — this MUST run before any network call. The
        // promptBuilder doesn't enforce sanitization itself (it accepts
        // already-sanitized text per its API contract); we do it here so the
        // contract is enforced at the network boundary.
        let sanitized = AIFallbackPromptBuilder.sanitize(userText)
        let userPrompt = AIFallbackPromptBuilder.userPrompt(
            sanitizedUserText: sanitized,
            category: category,
            context: context,
            knowledgeBase: kb
        )

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = ClaudeRequest(
            model: model.rawValue,
            maxTokens: 256,
            temperature: 0.1,
            system: AIFallbackPromptBuilder.systemPrompt,
            messages: [ClaudeRequest.Message(role: "user", content: userPrompt)]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .notConnectedToInternet || urlError.code == .networkConnectionLost {
            throw FallbackError.offline
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw FallbackError.timeout
        } catch {
            throw FallbackError.other("network: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw FallbackError.other("non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 429:
            throw FallbackError.rateLimited
        case 401, 403:
            throw FallbackError.apiKeyMissing
        default:
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw FallbackError.other("HTTP \(http.statusCode): \(preview)")
        }

        let claudeResponse: ClaudeResponse
        do {
            claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        } catch {
            throw FallbackError.responseUnparseable("envelope decode: \(error.localizedDescription)")
        }
        guard let modelText = claudeResponse.content.first(where: { $0.type == "text" })?.text else {
            throw FallbackError.responseUnparseable("no text content in response")
        }

        return try AIFallbackPromptBuilder.parseResponse(modelText, knowledgeBase: kb)
    }
}

// MARK: - Anthropic Messages API DTOs

private struct ClaudeRequest: Encodable {
    let model: String
    let maxTokens: Int
    let temperature: Double
    let system: String
    let messages: [Message]

    struct Message: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model, system, messages, temperature
        case maxTokens = "max_tokens"
    }
}

private struct ClaudeResponse: Decodable {
    let content: [Block]

    struct Block: Decodable {
        let type: String
        let text: String?
    }
}
#endif
