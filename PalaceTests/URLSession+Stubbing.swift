import Foundation

extension URLSession {
    /// Process-wide stubbed session. Converted from `let` to `var` in
    /// swarm_4b64e4e0 Fix 1 so the `SingletonResetRegistry` can replace
    /// it between tests via `_resetStubbedSession()`. The previous
    /// `static let` form left a permanently bound session whose private
    /// delegate queue accumulated callbacks across tests and produced the
    /// `libdispatch` use-after-free described in the header comment below.
    private static var _sharedStubbedSession: URLSession = URLSession._buildStubbedSession()

    private static func _buildStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Returns a process-wide shared URLSession configured with HTTPStubURLProtocol.
    /// One session is reused across all tests so that we don't leak a fresh
    /// URLSession (and its private delegate queue) per call. Leaked sessions
    /// fire callbacks on freed state long after the owning test method has
    /// returned, causing libdispatch use-after-free crashes on whichever
    /// unrelated test runs next.
    ///
    /// Preserved for the 33 legacy callers. New code SHOULD prefer
    /// `URLSession.stubbed(handlers:)` (Wave 2, Module A) which returns a
    /// fresh per-call session so that two tests cannot share handler
    /// state through the same URLSession.
    static func stubbedSession() -> URLSession {
        return _sharedStubbedSession
    }

    /// Wave 2 (swarm_b503a876 Module A) — per-call factory that returns
    /// a FRESH `URLSession` configured with `HTTPStubURLProtocol` plus
    /// any additional URLProtocol classes the caller supplies (e.g. a
    /// test-local mock protocol). No caching — every call yields a new
    /// session whose lifetime the caller owns.
    ///
    /// The returned session is tracked via the Wave 1 reset registry
    /// (`URLSession._resetStubbedSession` resetter), so any in-flight
    /// task drains gracefully if the registry fires between this call
    /// and `finishTasksAndInvalidate()`.
    ///
    /// **Lifecycle contract:** the caller MUST invalidate the returned
    /// session before its owner goes out of scope — `tearDown` is the
    /// natural seam. Use `finishTasksAndInvalidate()` (not
    /// `invalidateAndCancel()`) so completion handlers from in-flight
    /// tasks land on a still-live delegate queue.
    ///
    /// - Parameter handlers: Optional URLProtocol classes prepended
    ///   ahead of `HTTPStubURLProtocol` in the session config so they
    ///   get first crack at interception. Defaults to no additional
    ///   handlers.
    /// - Returns: A fresh URLSession owned by the caller.
    static func stubbed(handlers: [URLProtocol.Type] = []) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = handlers + [HTTPStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Test-only: invalidate the cached stubbed session and rebuild on
    /// next read. Registered into `SingletonResetRegistry` by
    /// `PalaceTestSetup.bootstrap()` — fires after every test so the
    /// next test sees a fresh URLSession (and a fresh delegate queue),
    /// preventing the cross-test libdispatch use-after-free described in
    /// the file's original header comment.
    ///
    /// Uses `finishTasksAndInvalidate()` — NOT `invalidateAndCancel()`.
    /// The latter would cancel in-flight tasks mid-flight, which races
    /// with completion handlers reading freed state — the very bug the
    /// shared singleton existed to avoid. `finishTasksAndInvalidate()`
    /// lets in-flight tasks drain on the OLD session before its delegate
    /// queue tears down.
    static func _resetStubbedSession() {
        let old = _sharedStubbedSession
        _sharedStubbedSession = _buildStubbedSession()
        old.finishTasksAndInvalidate()
    }
}
