import Foundation

/// In-process URLProtocol that intercepts URLSession traffic for tests.
///
/// **Two APIs** (Wave 2, swarm_b503a876 Module A — ADDITIVE; legacy
/// callers continue to compile and behave identically):
///
///  1. **Legacy** — `register(_ handler:)` appends a closure-handler to
///     a global LIFO array. Historical behavior is preserved:
///     `canInit(with:)` returns `true` for every request when there is
///     at least one legacy handler registered. 33 existing test files
///     keep working without edits.
///
///  2. **New predicate API** — `registerHandler(matching:response:)`
///     registers a URL predicate paired with a canned response. When
///     ONLY predicate handlers are registered (no legacy ones),
///     `canInit(with:)` returns `true` only when a predicate matches —
///     unmatched requests fall through to the next URLProtocol in the
///     chain (`NoNetworkURLProtocol`), which fails them with
///     `NSURLErrorNotConnectedToInternet`. This closes the
///     "intercept-everything" surface area documented in swarm_f88ae9e3
///     transcript D — production code that incidentally hits a stubbed
///     URLSession no longer gets a confusing 501 from this protocol.
///
/// **Non-blocking `startLoading`** — handler resolution + response
/// emission used to run synchronously on the URLSession delegate queue,
/// which meant a handler that called `DispatchSemaphore.wait(timeout:)`
/// blocked subsequent stubbed requests for the duration of the timeout.
/// `startLoading` now dispatches the response work onto a dedicated
/// global queue so two concurrent stubbed requests do not serialize on
/// each other's handler logic. The delegate queue is released
/// immediately.
final class HTTPStubURLProtocol: URLProtocol {
    struct StubbedResponse {
        let statusCode: Int
        let headers: [String: String]?
        let body: Data?
    }

    /// A predicate-keyed handler registered via the new API. The
    /// predicate is consulted by both `canInit(with:)` (gating
    /// interception) and `handler(for:)` (resolving the response). The
    /// `name` is informational only — used for diagnostics in tests
    /// that want to assert which handler matched.
    private struct PredicateHandler {
        let matches: (URL) -> Bool
        let response: StubbedResponse
    }

    private static let handlerQueue = DispatchQueue(label: "HTTPStubURLProtocol.handlerQueue")

    /// Legacy closure-handler array. `register(_:)` appends; `reset()`
    /// drains. `canInit` returns true unconditionally when non-empty
    /// (existing 33-caller behavior). LIFO iteration in `handler(for:)`.
    private static var requestHandlers: [(URLRequest) -> StubbedResponse?] = []

    /// Predicate-handler list. `registerHandler(matching:response:)`
    /// appends; `reset()` drains alongside the legacy list. When this
    /// list is non-empty and the legacy list is empty, `canInit` is
    /// gated on predicate match — unmatched requests fall through.
    private static var predicateHandlers: [PredicateHandler] = []

    /// Dedicated queue for emitting stubbed responses. Keeps handler
    /// work off the URLSession delegate queue so two concurrent stubbed
    /// requests don't serialize on each other. Concurrent so multiple
    /// in-flight requests proceed in parallel.
    private static let responseQueue = DispatchQueue(
        label: "HTTPStubURLProtocol.responseQueue",
        attributes: .concurrent
    )

    override static func canInit(with request: URLRequest) -> Bool {
        // Snapshot both lists under the handler queue so we don't race
        // a `reset()` on the response thread.
        let (legacyCount, predicates) = handlerQueue.sync {
            return (requestHandlers.count, predicateHandlers)
        }

        // Legacy callers (the 33 existing files) keep unconditional
        // interception — preserves backward compatibility.
        if legacyCount > 0 {
            return true
        }

        // No legacy callers — the predicate gate decides. Empty
        // predicate list means we have nothing to say about this
        // request; fall through cleanly so NoNetworkURLProtocol can
        // surface a deterministic NSURLErrorNotConnectedToInternet.
        if predicates.isEmpty {
            return false
        }

        // Predicate-only callers — intercept only on URL match.
        guard let url = request.url else { return false }
        for predicate in predicates {
            if predicate.matches(url) {
                return true
            }
        }
        return false
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        // Capture state needed by the response emission so the closure
        // doesn't read `self.request` from the delegate queue after we
        // hand control back.
        let request = self.request
        let client = self.client
        let protocolInstance = self

        // Dispatch the response work onto our concurrent queue. The
        // URLSession delegate queue is released immediately and does
        // not block on any handler-internal synchronization (a handler
        // calling `DispatchSemaphore.wait(timeout: 3.0)` to model a
        // slow network no longer holds up other concurrent stubbed
        // requests).
        Self.responseQueue.async {
            let stub = Self.handler(for: request)
            guard let stub = stub else {
                guard let url = request.url else {
                    client?.urlProtocolDidFinishLoading(protocolInstance)
                    return
                }
                let notFound = HTTPURLResponse(
                    url: url,
                    statusCode: 501,
                    httpVersion: nil,
                    headerFields: nil
                )!
                client?.urlProtocol(protocolInstance, didReceive: notFound, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(protocolInstance)
                return
            }

            let url = request.url ?? URL(string: "about:blank")!
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )!

            client?.urlProtocol(protocolInstance, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            if let body = stub.body {
                client?.urlProtocol(protocolInstance, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(protocolInstance)
        }
    }

    override func stopLoading() { }

    // MARK: - Public API

    /// Legacy closure-handler registration. Preserved unchanged for the
    /// 33 existing callers. `canInit(with:)` returns `true` for every
    /// request when at least one legacy handler is registered. Use
    /// `registerHandler(matching:response:)` for new tests that want
    /// URL-gated interception.
    static func register(_ handler: @escaping (URLRequest) -> StubbedResponse?) {
        handlerQueue.sync {
            requestHandlers.append(handler)
        }
    }

    /// New predicate-handler registration (swarm_b503a876 Module A,
    /// Fix 3 — narrowed `canInit`). The supplied predicate is consulted
    /// by both `canInit(with:)` (interception gate) and `handler(for:)`
    /// (response selection). When ONLY predicate handlers are
    /// registered, unmatched requests fall through to the next
    /// URLProtocol — they do NOT get a 501.
    ///
    /// - Parameters:
    ///   - matching: Closure returning true if this handler should
    ///     intercept the request's URL.
    ///   - response: Canned response emitted on a predicate match.
    static func registerHandler(
        matching: @escaping (URL) -> Bool,
        response: StubbedResponse
    ) {
        handlerQueue.sync {
            predicateHandlers.append(PredicateHandler(matches: matching, response: response))
        }
    }

    static func reset() {
        handlerQueue.sync {
            requestHandlers.removeAll()
            predicateHandlers.removeAll()
        }
    }

    /// Canonical name adopted by the `SingletonResetRegistry` bootstrap path
    /// (swarm_4b64e4e0 Fix 1). Forwards to `reset()` — both methods clear
    /// the handler array under the same queue. Existing `reset()` callers
    /// continue to work unchanged.
    static func removeAllHandlers() {
        reset()
    }

    /// Test-only snapshot of the predicate-handler list count. Used by
    /// `HTTPStubTestCase` to assert clean teardown.
    static func _registeredPredicateHandlerCount() -> Int {
        return handlerQueue.sync { predicateHandlers.count }
    }

    /// Test-only snapshot of the legacy-handler list count. Used by
    /// `HTTPStubTestCase` to assert clean teardown.
    static func _registeredLegacyHandlerCount() -> Int {
        return handlerQueue.sync { requestHandlers.count }
    }

    private static func handler(for request: URLRequest) -> StubbedResponse? {
        return handlerQueue.sync {
            // Predicate handlers take precedence (LIFO) — newer
            // registrations win on URL match.
            if let url = request.url {
                for predicate in predicateHandlers.reversed() {
                    if predicate.matches(url) {
                        return predicate.response
                    }
                }
            }
            // Fall through to the legacy closure-handler list.
            for resolver in requestHandlers.reversed() {
                if let response = resolver(request) {
                    return response
                }
            }
            return nil
        }
    }
}
