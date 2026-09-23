// Fixture: the PP-4895 shape — URLSessionTaskDelegate auth challenge written in
// the completion-handler form. MUST be flagged (ACF-1).
import Foundation

final class DownloadDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }
}
