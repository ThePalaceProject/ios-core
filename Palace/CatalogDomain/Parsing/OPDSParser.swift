import Foundation

public final class OPDSParser {
    public enum ParserError: Error, LocalizedError {
        case invalidXML
        case invalidFeed
        case invalidJSON

        public var errorDescription: String? {
            switch self {
            case .invalidXML: return "Unable to parse OPDS XML."
            case .invalidFeed: return "Invalid or unsupported OPDS feed format."
            case .invalidJSON: return "Unable to parse OPDS 2 JSON."
            }
        }
    }

    func parseFeed(from data: Data) throws -> CatalogFeed {
        let format = OPDSFormat.detect(from: data)

        switch format {
        case .opds2:
            return try parseOPDS2Feed(from: data)
        case .opds1, .unknown:
            return try parseOPDS1Feed(from: data)
        }
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
