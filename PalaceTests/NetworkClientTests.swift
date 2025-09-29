import XCTest
@testable import Palace

final class NetworkClientTests: XCTestCase {
  override func setUp() {
    super.setUp()
    HTTPStubURLProtocol.reset()
  }

  func testGET_Success() async throws {
    let expectedBody = Data("{\"ok\":true}".utf8)
    HTTPStubURLProtocol.register { req in
      guard req.url?.path == "/hello" else {
        return nil
      }
      return .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: expectedBody)
    }

    // Build a URLSessionConfiguration that uses our stub protocol
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPStubURLProtocol.self]

    // Inject executor with custom configuration into the client
    let executor = TPPNetworkExecutor(cachingStrategy: .ephemeral, sessionConfiguration: config)
    let client = URLSessionNetworkClient(executor: executor)

    let url = URL(string: "https://example.com/hello")!
    let request = NetworkRequest(method: .GET, url: url)
    let response = try await client.send(request)
    XCTAssertEqual(response.response.statusCode, 200)
    XCTAssertEqual(response.data, expectedBody)
  }
}
