import Foundation

// The single-line enum body. The depth fix must not close the scan window
// before the declaration line's own cases are inspected.
struct Doc: Codable {
    let showTitle: Bool?
    private enum CodingKeys: String, CodingKey { case showTitle = "show_title" }
    static func parse(_ data: Data) throws -> Doc {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Doc.self, from: data)
    }
}
