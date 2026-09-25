import Foundation

struct Doc: Codable {
    let showTitle: Bool?
    private enum CodingKeys: String, CodingKey {
        // no-snakecase-codingkeys: intentional, this container is decoded by a
        // second decoder that does not set the strategy.
        case showTitle = "show_title"
    }
    static func parse(_ data: Data) throws -> Doc {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Doc.self, from: data)
    }
}
