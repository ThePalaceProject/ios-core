import Foundation

@objc class TPPSession: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

  private static let diskCacheInMegabytes: Int = 15
  private static let memoryCacheInMegabytes: Int = 1

  @objc static let sharedSession: TPPSession = {
    let session = TPPSession()
    return session
  }()

  private var session: URLSession!

  private override init() {
    super.init()

    let configuration = URLSessionConfiguration.default
    assert(configuration.urlCache != nil)
    configuration.urlCache?.diskCapacity = 1024 * 1024 * TPPSession.diskCacheInMegabytes
    configuration.urlCache?.memoryCapacity = 1024 * 1024 * TPPSession.memoryCacheInMegabytes
    configuration.urlCredentialStorage = nil

    session = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: .main
    )
  }

  // MARK: - URLSessionTaskDelegate

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    Log.log("\(task.currentRequest?.url?.absoluteString ?? ""): Challenge Received: \(challenge.protectionSpace.authenticationMethod)")

    let challenger = TPPBasicAuth(credentialsProvider: TPPUserAccount.sharedAccount())
    challenger.handleChallenge(challenge, completion: completionHandler)
  }

  // MARK: - Public methods

  @objc func upload(with request: URLRequest, completionHandler handler: ((Data?, URLResponse?, Error?) -> Void)?) {
    session.uploadTask(with: request, from: request.httpBody, completionHandler: { data, response, error in
      handler?(data, response, error)
    }).resume()
  }

  @objc func withURL(
    _ url: URL,
    shouldResetCache: Bool,
    completionHandler handler: @escaping (Data?, URLResponse?, Error?) -> Void
  ) -> URLRequest? {
    var req: URLRequest?

    let completionWrapper: (Data?, URLResponse?, Error?) -> Void = { data, response, error in
      if let error = error {
        let dataString = data.flatMap { String(data: $0, encoding: .utf8) }
          ?? data.map { "datalength=\($0.count)" }
        TPPErrorLogger.logNetworkError(
          error,
          code: .apiCall,
          summary: String(describing: type(of: self)),
          request: req as URLRequest?,
          response: response,
          metadata: [
            "receivedData": dataString ?? "N/A",
            "networking context": "NYPLSession error"
          ]
        )
        handler(nil, response, error)
        return
      }
      handler(data, response, nil)
    }

    if shouldResetCache {
      TPPNetworkExecutor.shared.clearCache()
    }

    let lastPathComponent = url.lastPathComponent
    if lastPathComponent == "borrow" {
      req = TPPNetworkExecutor.shared.PUT(url, useTokenIfAvailable: false, completion: completionWrapper)?.originalRequest
    } else {
      req = TPPNetworkExecutor.shared.GET(url, cachePolicy: .useProtocolCachePolicy, useTokenIfAvailable: false, completion: completionWrapper)?.originalRequest
    }

    return req
  }
}
