import Foundation

/// Swift port of TPPSession. Manages a URLSession with authentication challenge handling.
@objcMembers
final class TPPSessionSwift: NSObject {

  static let shared = TPPSessionSwift()

  private static let diskCacheInMegabytes = 15
  private static let memoryCacheInMegabytes = 1

  private var urlSession: URLSession!

  private override init() {
    super.init()

    let configuration = URLSessionConfiguration.default
    if let cache = configuration.urlCache {
      cache.diskCapacity = 1024 * 1024 * TPPSessionSwift.diskCacheInMegabytes
      cache.memoryCapacity = 1024 * 1024 * TPPSessionSwift.memoryCacheInMegabytes
    }

    urlSession = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: .main
    )
  }

  // MARK: - Public API

  func upload(
    with request: URLRequest,
    completionHandler handler: ((Data?, URLResponse?, Error?) -> Void)?
  ) {
    guard let body = request.httpBody else { return }
    urlSession.uploadTask(with: request, from: body) { data, response, error in
      handler?(data, response, error)
    }.resume()
  }

  @discardableResult
  func withURL(
    _ url: URL,
    shouldResetCache: Bool,
    completionHandler handler: @escaping (Data?, URLResponse?, Error?) -> Void
  ) -> URLRequest {

    if shouldResetCache {
      TPPNetworkExecutor.shared.clearCache()
    }

    var resultRequest: URLRequest?

    let completionWrapper: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
      if let error = error {
        let dataString = data.flatMap { String(data: $0, encoding: .utf8) }
          ?? (data.map { "datalength=\($0.count)" } ?? "N/A")
        TPPErrorLogger.logNetworkError(
          error as NSError,
          code: .apiCall,
          summary: String(describing: TPPSessionSwift.self),
          request: resultRequest.map { $0 as URLRequest },
          response: response,
          metadata: [
            "receivedData": dataString,
            "networking context": "NYPLSession error"
          ]
        )
        handler(nil, response, error)
        return
      }
      handler(data, response, nil)
    }

    let task: URLSessionDataTask
    if url.lastPathComponent == "borrow" {
      guard let t = TPPNetworkExecutor.shared.PUT(url, useTokenIfAvailable: false, completion: completionWrapper) else {
        return URLRequest(url: url)
      }
      task = t
    } else {
      guard let t = TPPNetworkExecutor.shared.GET(url, cachePolicy: .useProtocolCachePolicy, useTokenIfAvailable: false, completion: completionWrapper) else {
        return URLRequest(url: url)
      }
      task = t
    }

    resultRequest = task.originalRequest
    return task.originalRequest ?? URLRequest(url: url)
  }
}

// MARK: - URLSessionTaskDelegate

extension TPPSessionSwift: URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    Log.info(#file, "NSURLSessionTask: \(task.currentRequest?.url?.absoluteString ?? "nil"). Challenge: \(challenge.protectionSpace.authenticationMethod)")

    let challenger = TPPBasicAuth(credentialsProvider: TPPUserAccount.sharedAccount())
    challenger.handleChallenge(challenge, completion: completionHandler)
  }
}
