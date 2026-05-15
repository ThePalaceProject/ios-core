import Foundation
import PalaceLogging

public final class OPDSParser {
    enum ParserError: Error, LocalizedError, Equatable {
        case invalidXML
        case invalidFeed
        case invalidJSON
        /// Server returned an RFC 7807 problem document (Content-Type: application/problem+json).
        /// Carries the structured fields so callers can surface title/detail to the user instead
        /// of a generic "invalid response" message.
        case problemDocument(TPPProblemDocument)

        var errorDescription: String? {
            switch self {
            case .invalidXML: return "Unable to parse OPDS XML."
            case .invalidFeed: return "Invalid or unsupported OPDS feed format."
            case .invalidJSON: return "Unable to parse OPDS 2 JSON."
            case .problemDocument(let doc):
                // Prefer the server's title+detail; fall back to whichever is non-empty.
                let title = doc.title ?? ""
                let detail = doc.detail ?? ""
                if !title.isEmpty && !detail.isEmpty { return "\(title): \(detail)" }
                if !title.isEmpty { return title }
                if !detail.isEmpty { return detail }
                return "The server returned a problem document."
            }
        }

        // Manual Equatable because TPPProblemDocument is an NSObject (not Equatable).
        // Case-identity equality is sufficient for tests and existing call sites.
        static func == (lhs: ParserError, rhs: ParserError) -> Bool {
            switch (lhs, rhs) {
            case (.invalidXML, .invalidXML),
                 (.invalidFeed, .invalidFeed),
                 (.invalidJSON, .invalidJSON):
                return true
            case (.problemDocument(let a), .problemDocument(let b)):
                return a.type == b.type
                    && a.title == b.title
                    && a.status == b.status
                    && a.detail == b.detail
                    && a.instance == b.instance
            default:
                return false
            }
        }
    }

    public init() {}

    public func parseFeed(from data: Data) throws -> CatalogFeed {
        try parseFeed(from: data, contentType: nil)
    }

    /// Parse a catalog feed, honoring the response Content-Type so RFC 7807
    /// problem documents (`application/problem+json`) surface structured errors
    /// instead of falling through to the generic JSON parser.
    public func parseFeed(from data: Data, contentType: String?) throws -> CatalogFeed {
        if isProblemDocumentContentType(contentType) {
            // Decode as RFC 7807 problem document and surface its structured fields.
            // Use the lenient `fromProblemResponseData` so partially-shaped problem
            // bodies still produce a usable title/detail.
            if let doc = TPPProblemDocument.fromProblemResponseData(data) {
                throw ParserError.problemDocument(doc)
            }
            // Body wasn't decodable as a problem document. Synthesize one so the
            // caller still sees a structured error rather than ParserError.invalidJSON.
            throw ParserError.problemDocument(
                TPPProblemDocument.fromDictionary([
                    "title": "Server Error",
                    "detail": "The server returned a problem response that could not be decoded."
                ])
            )
        }


        let format = OPDSFormat.detect(from: data)

        switch format {
        case .opds2:
            return try parseOPDS2Feed(from: data)
        case .opds1, .unknown:
            return try parseOPDS1Feed(from: data)
        }
    }

    /// Returns true for RFC 7807 problem document content types.
    /// Matches `application/problem+json` and `application/api-problem+json`
    /// (server variant); tolerant to charset/profile parameters.
    private func isProblemDocumentContentType(_ contentType: String?) -> Bool {
        guard let lowercased = contentType?.lowercased() else { return false }
        return lowercased.contains("problem+json")
    }

    // MARK: - OPDS 1 (XML)

    private func parseOPDS1Feed(from data: Data) throws -> CatalogFeed {
        guard let xml = TPPXML.xml(withData: data) else { throw ParserError.invalidXML }
        let feed = TPPOPDSFeed(xml: xml)
        guard let catalogFeed = CatalogFeed(feed: feed) else { throw ParserError.invalidFeed }
        return catalogFeed
    }

    // MARK: - OPDS 2 (JSON)

    private func parseOPDS2Feed(from data: Data) throws -> CatalogFeed {
        let opds2Feed: OPDS2Feed
        do {
            opds2Feed = try OPDS2Feed.from(data: data)
        } catch let decodingError as DecodingError {
            let detail: String
            switch decodingError {
            case .keyNotFound(let key, let ctx):
                detail = "Missing key '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
            case .typeMismatch(let type, let ctx):
                detail = "Type mismatch for \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
            case .valueNotFound(let type, let ctx):
                detail = "Null value for \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
            case .dataCorrupted(let ctx):
                detail = "Corrupted at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)"
            @unknown default:
                detail = decodingError.localizedDescription
            }
            Log.warn(#file, "[OPDS2-DIAG] Failed to decode OPDS2 feed: \(detail)")
            // Preview first 500 chars of JSON for debugging
            if let preview = String(data: data.prefix(500), encoding: .utf8) {
                Log.info(#file, "[OPDS2-DIAG] JSON preview: \(preview)")
            }
            throw ParserError.invalidJSON
        } catch {
            Log.warn(#file, "[OPDS2-DIAG] Failed to parse OPDS2 JSON: \(error)")
            throw ParserError.invalidJSON
        }

        Log.info(#file, "[OPDS2-DIAG] OPDSParser detected OPDS 2 feed: \"\(opds2Feed.title)\", " +
            "groups=\(opds2Feed.groups?.count ?? 0), " +
            "publications=\(opds2Feed.publications?.count ?? 0), " +
            "navigation=\(opds2Feed.navigation?.count ?? 0)")

        return CatalogFeed(opds2Feed: opds2Feed)
    }
}
