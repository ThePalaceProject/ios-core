import Foundation

/// A typed HTTP response wrapping status code, headers, and body.
public struct NetworkResponse<Body> {
  public let statusCode: Int
  public let headers: [AnyHashable: Any]
  public let body: Body

  public init(statusCode: Int, headers: [AnyHashable: Any], body: Body) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }

  /// Whether the status code indicates success (2xx).
  public var isSuccess: Bool {
    (200..<300).contains(statusCode)
  }
}

/// Convenience type alias for data responses.
public typealias DataResponse = NetworkResponse<Data>

/// Convenience type alias for JSON responses.
public typealias JSONResponse = NetworkResponse<Any>

/// Extension for decoding JSON responses.
extension NetworkResponse where Body == Data {

  /// Decodes the body as a Decodable type.
  public func decoded<T: Decodable>(as type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
    return try decoder.decode(type, from: body)
  }

  /// Decodes the body as a JSON object.
  public func jsonObject(options: JSONSerialization.ReadingOptions = []) throws -> Any {
    return try JSONSerialization.jsonObject(with: body, options: options)
  }
}
