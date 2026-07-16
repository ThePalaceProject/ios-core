import Foundation

final class HTTPStubURLProtocol: URLProtocol {
    struct StubbedResponse {
        let statusCode: Int
        let headers: [String: String]?
        let body: Data?
    }

    private static let handlerQueue = DispatchQueue(label: "HTTPStubURLProtocol.handlerQueue")
    private static let _requestHandlers = LockIsolated<[(URLRequest) -> StubbedResponse?]>([])
    private static var requestHandlers: [(URLRequest) -> StubbedResponse?] {
        get { _requestHandlers.value }
        set { _requestHandlers.value = newValue }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
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

    /// Canonical name adopted by the `SingletonResetRegistry` bootstrap path
    /// (swarm_4b64e4e0 Fix 1). Forwards to `reset()` — both methods clear
    /// the handler array under the same queue. Existing `reset()` callers
    /// continue to work unchanged.
    static func removeAllHandlers() {
        reset()
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
