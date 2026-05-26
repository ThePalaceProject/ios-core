//
//  MockBackendURLProtocol.swift
//  Palace
//
//  URLProtocol subclass that intercepts ALL network requests when active.
//  Routes requests to fixture files based on the active MockScenario.
//  Covers both legacy TPPNetworkExecutor and modern NetworkClient layers.
//

#if DEBUG

import Foundation
import PalaceLogging
import PalaceNetwork

final class MockBackendURLProtocol: URLProtocol {

    // MARK: - Static Configuration

    /// The active scenario. When nil, this protocol does not intercept.
    static var activeScenario: MockScenario?

    /// Host to scope interception to. When set, only requests to this host
    /// are considered for mocking — requests to other hosts pass through.
    /// Set automatically from the current library's catalog URL on activation.
    static var scopedHost: String?

    /// Bundle containing fixture files. Override for test bundles.
    static var fixtureBundle: Bundle = .main

    /// Direct file system path to fixtures directory. When set, bypasses bundle lookup.
    /// Set this in tests where fixtures aren't bundled.
    static var fixtureDirectoryPath: String?

    /// Request counter for diagnostics.
    private static var requestCount = 0

    // MARK: - URLProtocol Overrides

    override class func canInit(with request: URLRequest) -> Bool {
        // Only intercept when a scenario is active
        guard let scenario = activeScenario else { return false }
        // Don't intercept our own marked requests (prevent infinite recursion)
        guard URLProtocol.property(forKey: "MockBackendHandled", in: request) == nil else {
            return false
        }
        // Only intercept requests to the scoped library host (if set).
        // This prevents the mock from interfering with other libraries
        // when the user switches accounts.
        if let host = scopedHost, request.url?.host != host {
            return false
        }
        // Only intercept requests that match an explicit route.
        // Unmatched requests pass through to the real server so the
        // catalog, cover images, and other non-mocked endpoints work normally.
        let matched = scenario.routes.contains { $0.matches(request) }
        if !matched, let url = request.url?.absoluteString {
            Log.debug(#file, "MockBackend: pass-through (no route matched) \(request.httpMethod ?? "?") \(url)")
        }
        return matched
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.requestCount += 1
        let requestNum = Self.requestCount

        guard let scenario = Self.activeScenario,
              let url = request.url else {
            deliverError(NSError(domain: "MockBackend", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "No active scenario or URL"]))
            return
        }

        let method = request.httpMethod ?? "GET"
        Log.info(#file, "MockBackend [\(requestNum)] \(method) \(url.absoluteString)")

        // Find matching route
        guard let route = scenario.routes.first(where: { $0.matches(request) }) else {
            Log.warn(#file, "MockBackend [\(requestNum)] No route matched, returning 404")
            deliverResponse(statusCode: 404,
                           contentType: "application/problem+json",
                           data: makeProblemDocument(title: "Not Found",
                                                     detail: "MockBackend: no route matched \(url.path)",
                                                     status: 404))
            return
        }

        Log.info(#file, "MockBackend [\(requestNum)] Matched route: \(route.fixtureName) → \(route.statusCode)")

        // Load fixture data
        guard let fixtureData = loadFixture(route: route) else {
            deliverError(NSError(domain: "MockBackend", code: -2,
                                 userInfo: [NSLocalizedDescriptionKey: "Fixture \(route.fixtureName) not found"]))
            return
        }

        // Deliver with optional delay
        let delay = route.delayMs.map { Double($0) / 1000.0 } ?? 0

        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.deliverResponse(statusCode: route.statusCode,
                                      contentType: route.contentType,
                                      data: fixtureData,
                                      additionalHeaders: route.headers)
            }
        } else {
            deliverResponse(statusCode: route.statusCode,
                           contentType: route.contentType,
                           data: fixtureData,
                           additionalHeaders: route.headers)
        }
    }

    override func stopLoading() {
        // Nothing to cancel — responses are delivered synchronously or via short delay
    }

    // MARK: - Fixture Loading

    private func loadFixture(route: MockRoute) -> Data? {
        let name = route.fixtureName
        let possibleExtensions = ["json", "xml", "atom"]
        var data: Data?

        // Priority 0: embedded fixtures (always available, no bundle needed)
        data = EmbeddedFixtures.data(for: name)

        // Priority 1: direct file system path (set by tests)
        if let dirPath = Self.fixtureDirectoryPath {
            for ext in possibleExtensions {
                let path = "\(dirPath)/\(name).\(ext)"
                if let d = FileManager.default.contents(atPath: path) {
                    data = d
                    break
                }
            }
        }

        // Priority 2: bundle resource lookup (runtime debug menu)
        if data == nil {
            let bundle = Self.fixtureBundle
            for ext in possibleExtensions {
                if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/API") ??
                             bundle.url(forResource: name, withExtension: ext) {
                    data = try? Data(contentsOf: url)
                    if data != nil { break }
                }
            }
        }

        // Priority 3: fallback to bundle base path
        if data == nil {
            let basePath = Self.fixtureBundle.bundlePath
            for ext in possibleExtensions {
                let path = "\(basePath)/Fixtures/API/\(name).\(ext)"
                if let d = FileManager.default.contents(atPath: path) {
                    data = d
                    break
                }
            }
        }

        guard var fixtureData = data else {
            Log.error(#file, "MockBackend: fixture '\(name)' not found in bundle")
            return nil
        }

        // If fixtureKey is set, extract a sub-object from a dictionary fixture
        if let key = route.fixtureKey {
            if let dict = try? JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
               let subObject = dict[key] {
                fixtureData = (try? JSONSerialization.data(withJSONObject: subObject)) ?? fixtureData
            }
        }

        return fixtureData
    }

    // MARK: - Response Delivery

    private func deliverResponse(statusCode: Int,
                                  contentType: String,
                                  data: Data,
                                  additionalHeaders: [String: String]? = nil) {
        guard let url = request.url else { return }

        var headers: [String: String] = [
            "Content-Type": contentType,
            "Content-Length": "\(data.count)",
            "X-Mock-Backend": "true"
        ]
        additionalHeaders?.forEach { headers[$0.key] = $0.value }

        guard let response = HTTPURLResponse(url: url,
                                              statusCode: statusCode,
                                              httpVersion: "HTTP/1.1",
                                              headerFields: headers) else {
            return
        }

        // Deliver response and data synchronously, then finish on next runloop
        // tick. This ensures the URLSession delegate processes didReceive(data:)
        // before didCompleteWithError: fires — otherwise TPPNetworkResponder's
        // progressData may be empty when it tries to parse the problem document.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func deliverError(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }

    private func makeProblemDocument(title: String, detail: String, status: Int) -> Data {
        let doc: [String: Any] = [
            "type": "http://librarysimplified.org/terms/problem/mock-backend",
            "title": title,
            "detail": detail,
            "status": status
        ]
        return (try? JSONSerialization.data(withJSONObject: doc)) ?? Data()
    }
}

#endif
