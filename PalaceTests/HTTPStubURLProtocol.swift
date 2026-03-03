import Foundation

final class HTTPStubURLProtocol: URLProtocol {
  struct StubbedResponse {
    let statusCode: Int
    let headers: [String: String]?
    let body: Data?
  }
  
  private static let handlerQueue = DispatchQueue(label: "HTTPStubURLProtocol.handlerQueue")
  private static var requestHandlers: [(URLRequest) -> StubbedResponse?] = []
  
  override class func canInit(with request: URLRequest) -> Bool {
    return true
  }
  
  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }
  
  override func startLoading() {
    let request = self.request
    let response: StubbedResponse? = Self.handler(for: request)
    
    guard let stub = response else {
      let notFound = HTTPURLResponse(url: request.url!, statusCode: 501, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: notFound, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
      return
    }
    
    let url = request.url ?? URL(string: "about:blank")!
    let httpResponse = HTTPURLResponse(
      url: url,
      statusCode: stub.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: stub.headers
    )!
    
    client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
    if let body = stub.body {
      client?.urlProtocol(self, didLoad: body)
    }
    client?.urlProtocolDidFinishLoading(self)
  }
  
  override func stopLoading() { }
  
  // MARK: - Public API
  
  static func register(_ handler: @escaping (URLRequest) -> StubbedResponse?) {
    handlerQueue.sync {
      requestHandlers.append(handler)
    }
  }
  
  static func reset() {
    handlerQueue.sync {
      requestHandlers.removeAll()
    }
  }
  
  private static func handler(for request: URLRequest) -> StubbedResponse? {
    return handlerQueue.sync {
      for resolver in requestHandlers.reversed() {
        if let response = resolver(request) {
          return response
        }
      }
      return nil
    }
  }
}


