// Fixture: the approved async spelling. Carries no block parameter, so nothing
// for the ClangImporter to poison. MUST PASS.
import Foundation

final class DownloadDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.performDefaultHandling, nil)
    }
}
