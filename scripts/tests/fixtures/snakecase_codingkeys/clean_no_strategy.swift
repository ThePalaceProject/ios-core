import Foundation

// Snake_case CodingKeys are CORRECT when no strategy is set — the raw value is
// then matched against the incoming key directly. Flagging this would be a
// false positive on the most common correct spelling in the language.
struct Doc: Codable {
    let showTitle: Bool?
    private enum CodingKeys: String, CodingKey {
        case showTitle = "show_title"
    }
    static func parse(_ data: Data) throws -> Doc {
        return try JSONDecoder().decode(Doc.self, from: data)
    }
}
