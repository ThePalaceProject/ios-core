import Foundation

/// AI-powered book discovery using the Claude API.
/// Falls back to local keyword search when the API is unavailable.
final class ClaudeDiscoveryService: DiscoveryServiceProtocol, @unchecked Sendable {
    private let configuration: any DiscoveryConfiguration
    private let session: URLSession
    private let fallback: LocalDiscoveryFallback

    var isAvailable: Bool { configuration.isAIAvailable }

    init(
        configuration: any DiscoveryConfiguration = DefaultDiscoveryConfiguration(),
        session: URLSession = .shared,
        fallback: LocalDiscoveryFallback = LocalDiscoveryFallback()
    ) {
        self.configuration = configuration
        self.session = session
        self.fallback = fallback
    }

    func getRecommendations(prompt: DiscoveryPrompt) async throws -> [DiscoveryRecommendation] {
        guard !Task.isCancelled else { throw DiscoveryError.cancelled }

        guard let apiKey = configuration.apiKey else {
            Log.info(#file, "Claude API key not configured, falling back to local discovery")
            return try await fallback.getRecommendations(prompt: prompt)
        }

        do {
            return try await fetchFromClaude(prompt: prompt, apiKey: apiKey)
        } catch is CancellationError {
            throw DiscoveryError.cancelled
        } catch let error as DiscoveryError {
            // For rate limiting or server errors, fall back gracefully
            switch error {
            case .rateLimited, .serverError, .networkUnavailable:
                Log.warn(#file, "Claude API error, falling back to local: \(error.localizedDescription)")
                return try await fallback.getRecommendations(prompt: prompt)
            default:
                throw error
            }
        } catch {
            Log.warn(#file, "Claude API request failed, falling back to local: \(error.localizedDescription)")
            return try await fallback.getRecommendations(prompt: prompt)
        }
    }

    // MARK: - Claude API

    private func fetchFromClaude(prompt: DiscoveryPrompt, apiKey: String) async throws -> [DiscoveryRecommendation] {
        let systemMessage = buildSystemPrompt()
        let userMessage = buildUserMessage(from: prompt)

        let requestBody = ClaudeRequest(
            model: configuration.model,
            max_tokens: 4096,
            system: systemMessage,
            messages: [
                ClaudeMessage(role: "user", content: userMessage)
            ]
        )

        let jsonData = try JSONEncoder().encode(requestBody)

        var request = URLRequest(url: configuration.endpoint, timeoutInterval: configuration.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = jsonData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DiscoveryError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseClaudeResponse(data)
        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after").flatMap(Int.init)
            throw DiscoveryError.rateLimited(retryAfterSeconds: retryAfter)
        case 400..<500:
            let body = String(data: data, encoding: .utf8)
            throw DiscoveryError.serverError(statusCode: httpResponse.statusCode, message: body)
        default:
            throw DiscoveryError.serverError(statusCode: httpResponse.statusCode, message: nil)
        }
    }

    private func buildSystemPrompt() -> String {
        """
        You are a librarian AI helping readers discover books. \
        You recommend books that are commonly available in public library OPDS catalogs. \
        Always respond with a JSON array of book recommendations. Each object must have these fields:
        - "id": a unique identifier string (use title slug)
        - "title": the book title
        - "authors": array of author name strings
        - "summary": brief 1-2 sentence description
        - "reason": why you recommend this book (personalized to the user's request)
        - "confidence": a number from 0.0 to 1.0
        - "categories": array of genre/category strings

        Prioritize books that are:
        1. Widely available in public library systems
        2. Highly rated and well-reviewed
        3. Diverse in perspective and genre within the requested parameters
        4. Recent where appropriate, but include classics when relevant

        Respond ONLY with the JSON array, no other text.
        """
    }

    private func buildUserMessage(from prompt: DiscoveryPrompt) -> String {
        var parts: [String] = []

        if let text = prompt.freeText, !text.isEmpty {
            parts.append("I'm looking for: \(text)")
        }

        if let mood = prompt.mood {
            parts.append("I'm in the mood for something \(mood.emoji).")
        }

        if !prompt.genres.isEmpty {
            parts.append("I enjoy these genres: \(prompt.genres.joined(separator: ", ")).")
        }

        if !prompt.readingHistory.isEmpty {
            let historyDescriptions = prompt.readingHistory.prefix(10).map { item in
                "\"\(item.title)\" by \(item.authors.joined(separator: ", "))"
            }
            parts.append("Books I've recently read and enjoyed: \(historyDescriptions.joined(separator: "; ")).")
        }

        if parts.isEmpty {
            parts.append("Suggest some great books I should read. Surprise me with diverse, interesting picks.")
        }

        parts.append("Please recommend up to \(prompt.maxResults) books.")

        return parts.joined(separator: " ")
    }

    private func parseClaudeResponse(_ data: Data) throws -> [DiscoveryRecommendation] {
        let claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)

        guard let textContent = claudeResponse.content.first(where: { $0.type == "text" }),
              let jsonData = textContent.text.data(using: .utf8) else {
            throw DiscoveryError.invalidResponse
        }

        // The response text may contain markdown code fences; strip them.
        let cleaned = cleanJSONString(textContent.text)
        guard let cleanedData = cleaned.data(using: .utf8) else {
            throw DiscoveryError.invalidResponse
        }

        let rawRecommendations = try JSONDecoder().decode([ClaudeBookRecommendation].self, from: cleanedData)

        return rawRecommendations.map { raw in
            DiscoveryRecommendation(
                id: raw.id,
                title: raw.title,
                authors: raw.authors,
                summary: raw.summary,
                coverImageURL: nil, // Cover URLs resolved during cross-library search
                reason: raw.reason,
                confidenceScore: max(0, min(1, raw.confidence)),
                categories: raw.categories,
                availability: [] // Populated by cross-library search
            )
        }
    }

    private func cleanJSONString(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip markdown code fences
        if result.hasPrefix("```json") {
            result = String(result.dropFirst(7))
        } else if result.hasPrefix("```") {
            result = String(result.dropFirst(3))
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Claude API Models (private)

private struct ClaudeRequest: Encodable {
    let model: String
    let max_tokens: Int
    let system: String
    let messages: [ClaudeMessage]
}

private struct ClaudeMessage: Encodable {
    let role: String
    let content: String
}

private struct ClaudeResponse: Decodable {
    let content: [ClaudeContentBlock]
}

private struct ClaudeContentBlock: Decodable {
    let type: String
    let text: String?
}

private struct ClaudeBookRecommendation: Decodable {
    let id: String
    let title: String
    let authors: [String]
    let summary: String?
    let reason: String
    let confidence: Double
    let categories: [String]
}
