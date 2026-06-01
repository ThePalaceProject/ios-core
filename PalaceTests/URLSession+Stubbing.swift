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
    static func stubbedSession() -> URLSession {
        return _sharedStubbedSession
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
