// Fixture: the documented escape hatch. MUST PASS.
import Foundation

final class LegacyDelegate: NSObject, URLSessionTaskDelegate {
    // no-auth-challenge-async-form: pinned to the completion-handler form by an
    // upstream SDK constraint; tracked separately.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }
}
