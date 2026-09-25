import Foundation

struct Doc: Codable {
    let showTitle: Bool?
    private enum CodingKeys: String, CodingKey {
        case showTitle = "show_title"
    }
    static func fromData(_ data: Data) throws -> Doc {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Doc.self, from: data)
    }
}
