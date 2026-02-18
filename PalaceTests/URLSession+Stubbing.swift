import Foundation

extension URLSession {
    static func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStubURLProtocol.self]
        return URLSession(configuration: config)
    }
}



