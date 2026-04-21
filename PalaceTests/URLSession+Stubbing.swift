import Foundation

extension URLSession {
    private static let _sharedStubbedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        return URLSession(configuration: config)
    }()

    /// Returns a process-wide shared URLSession configured with HTTPStubURLProtocol.
    /// One session is reused across all tests so that we don't leak a fresh
    /// URLSession (and its private delegate queue) per call. Leaked sessions
    /// fire callbacks on freed state long after the owning test method has
    /// returned, causing libdispatch use-after-free crashes on whichever
    /// unrelated test runs next.
    static func stubbedSession() -> URLSession {
        return _sharedStubbedSession
    }
}
