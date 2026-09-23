import Foundation

struct Outer: Codable {
    struct Inner: Codable {
        let firstName: String?
        enum CodingKeys: String, CodingKey {
            case firstName = "first_name"
        }
    }
    let inner: Inner
    static func parse(_ data: Data) throws -> Outer {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Outer.self, from: data)
    }
}
