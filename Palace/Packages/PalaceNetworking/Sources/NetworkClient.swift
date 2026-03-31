import Foundation

/// Protocol for performing HTTP network operations.
public protocol NetworkClient: Sendable {

  /// Performs a data request and returns the response.
  @available(iOS 15.0, macOS 12.0, *)
  func data(for request: URLRequest) async throws -> (Data, URLResponse)

  /// Performs a data request with a completion handler.
  func performDataTask(
    with request: URLRequest,
    completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
  )
}

/// Default implementation using URLSession.
extension URLSession: NetworkClient {

  public func performDataTask(
    with request: URLRequest,
    completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
  ) {
    let task = (self as URLSession).dataTask(with: request) { data, response, error in
      completionHandler(data, response, error)
    }
    task.resume()
  }
}
