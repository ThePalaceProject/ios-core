// Fixture: a completion-handler delegate method with NO auth challenge in it,
// and an auth-challenge helper with NO completion handler. Neither is the
// poisoned shape. MUST PASS.
import Foundation

final class Redirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request)
    }

    func describe(_ challenge: URLAuthenticationChallenge) -> String {
        challenge.protectionSpace.authenticationMethod
    }
}
