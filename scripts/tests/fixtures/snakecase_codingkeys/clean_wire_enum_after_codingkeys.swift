import Foundation

// REGRESSION FIXTURE (blast-radius review, 2026-09-23).
//
// The original scan loop recorded the enum's depth BEFORE counting the
// declaration line's `{`, so the exit test never fired at the enum's own
// closing brace and the scan window ran to the end of the ENCLOSING type.
// Every snake_case enum case that merely FOLLOWED a CodingKeys block in the
// same file was then flagged — the exact `OPDS2LinkRel` shape the rule
// promises to exclude structurally.
//
// The earlier clean_non_codingkey_enum.swift fixture could not catch this: it
// has no CodingKeys enum at all, so the discriminating path was never entered
// and the exclusion held by luck rather than by structure.
final class Doc: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, title, showTitle
    }

    // Not a CodingKey. Must NOT be flagged despite the snake_case raw value
    // and despite following a CodingKeys block in a .convertFromSnakeCase file.
    enum LinkRel: String {
        case passwordReset = "password_reset"
        case termsOfService = "terms_of_service"
    }

    static func parse(_ data: Data) throws -> Doc {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Doc.self, from: data)
    }
}
