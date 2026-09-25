import Foundation

struct Doc: Codable {
    let showTitle: Bool?
    private enum Keys: String, CodingKey {
        case showTitle = "show_title"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        showTitle = try c.decodeIfPresent(Bool.self, forKey: .showTitle)
    }
    static func parse(_ data: Data) throws -> Doc {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Doc.self, from: data)
    }
}
