// Fixture: the fixed production files carry long doc comments that name BOTH
// `completionHandler:` and `URLAuthenticationChallenge` while describing the
// defect. A substring-grep detector trips on those comments; this one must not.
// MUST PASS.
import Foundation

/// PP-4895 — deliberately the async spelling. The banned form would read
/// `didReceive challenge: URLAuthenticationChallenge, completionHandler:
/// @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void`,
/// which the importer can leave unmatched.
final class DownloadDelegate: NSObject, URLSessionTaskDelegate {
    /* A block comment naming completionHandler: and URLAuthenticationChallenge
       together, for good measure. */
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.performDefaultHandling, nil)
    }
}
