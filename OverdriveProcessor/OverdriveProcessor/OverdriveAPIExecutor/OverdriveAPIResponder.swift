import Foundation

class OverdriveAPIResponder: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
  var shouldPerformHTTPRedirection: Bool = true
    
  // MARK: - URLSessionDelegate
      
  // TODO: - Use URLCredential for authentication and validate serverTrust
  // Currently not implemented since authorization challenge not received
  // after serverTrust challenge went through
    
//  @objc public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
//  }
    
  // MARK: - URLSessionTaskDelegate
    
  // To avoid HTTP redirection when fulfilling Overdrive loan
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(shouldPerformHTTPRedirection ? request : nil)
  }
}
