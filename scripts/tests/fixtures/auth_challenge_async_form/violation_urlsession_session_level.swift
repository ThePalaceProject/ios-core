// Fixture: the SESSION-level challenge (URLSessionDelegate) shares the same
// poisoned block type. MUST be flagged (ACF-1).
import Foundation

final class SessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}
