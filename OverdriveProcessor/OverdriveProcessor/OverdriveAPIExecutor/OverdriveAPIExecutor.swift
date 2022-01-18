import Foundation

enum OverdriveAPIHost: String {
  case TestingHost = "https://integration.api.overdrive.com"
  case TestingPatronHost = "https://integration-patron.api.overdrive.com"
  case Host = "https://api.overdrive.com"
  case PatronHost = "https://patron.api.overdrive.com"
  case OAuthHost = "https://oauth.overdrive.com"
  case OAuthPatronHost = "https://oauth-patron.overdrive.com"
}

enum OverdriveAPIEndpoint: String {
  case Token = "/token"
  case PatronToken = "/patrontoken"
  case Checkout = "/v1/patrons/me/checkouts"
}

enum HTTPMethodType: String {
  case GET, POST, PUT, DELETE
}

@objcMembers public class OverdriveAPIExecutor: NSObject {
  public static let shared = OverdriveAPIExecutor()
  
  private let responder: OverdriveAPIResponder
    
  private let urlSession: URLSession
    
  private static var shouldPerformHTTPRedirection: Bool = true
    
  public private(set) var bearerToken: OverdriveToken?
  
  // Since Overdrive uses different patron token per collections,
  // We need to store the token by the `username` and `x-overdrive-scope` from circulation manager.
  // There is a possibility for an edge case which very rarely would happen,
  // when an user uses the exact same `username` across two different libraries,
  // and the two libraries share the same OD scope, an invalid token would be returned.
  private var patronTokens : [String: OverdriveToken]
  
  private let patronTokenLock = NSRecursiveLock()
  
  override init() {
    responder = OverdriveAPIResponder()
    
    urlSession = URLSession.init(configuration: URLSessionConfiguration.default, delegate: responder, delegateQueue: nil)
    
    patronTokens = [:]
    
    super.init()
  }
    
  // MARK: - Manifest
    
  ///    Retrieve the cached patron token stored by username and scope
  ///    Return an URL Request for Overdrive Manifest file with the token in it's Authorization header
  ///    SimpleE takes manifest URL request and execute it
  ///
  ///     - Parameter urlString: URL for Overdrive manifest file
  ///     - Parameter username: Library username / barcode for retriving the patron token
  ///     - Parameter scope: 'x-overdrive-scope' value from circulation manager
  public func getManifestRequest(urlString: String, username: String, scope: String) -> URLRequest? {
    guard let url = URL(string: urlString),
      let token = patronTokens[tokenKey(username: username, scope: scope)],
      !token.isExpired() else {
      return nil
    }
    
    let header = ["Authorization":"Bearer \(token.accessToken)"]
    
    return urlRequest(url: url, method: .GET, header: header)
  }
    
  ///    Request Overdrive Manifest file
  ///    This is for testing use, SimpleE directly get the manifest URL request and execute it
  ///
  ///     - Parameter urlString: URL for Overdrive manifest file
  ///     - Parameter username: Library username / barcode for retriving the patron token
  ///     - Parameter scope: 'x-overdrive-scope' value from circulation manager
  ///     - Parameter completion: Completion handler return the data and an error, they are optional in a mutually exclusive way
  func requestManifest(urlString: String,
                       username: String,
                       scope: String,
                       completion: @escaping (_ json: [String: Any]?, _: Error?)->()) {
    guard let token = patronTokens[tokenKey(username: username, scope: scope)],
      !token.isExpired() else {
      let error = NSError(domain: NYPLOverdriveDomain, code: NYPLOverdriveErrorCode.invalidToken.rawValue, userInfo: nil)
      completion(nil, error)
      return
    }
    
    guard let url = URL(string: urlString) else {
      let userInfo = ["url": urlString]
      let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: userInfo)
      completion(nil, error)
      return
    }
    
    let header = ["Authorization":"Bearer \(token.accessToken)"]
    
    let request = urlRequest(url: url, method: .GET, header: header)
    
    post(request: request) { result in
      switch result {
      case .success(let json):
        completion(json, nil)
      case .failure(let error):
        completion(nil, error)
      }
    }
  }
    
  // MARK: - Loan
    
  ///    Borrow a book before fulfilling the loan
  ///    This is for testing use, the borrow mechanism is already implemented in SimpleE
  ///    This request might fail due to book already being borrowed, but we can still process to fulfill the loan if thats the case
  ///
  ///     - Parameter urlString: URL for borrowing a book
  ///     - Parameter username: Library username / barcode
  ///     - Parameter PIN: Library PIN / password
  ///     - Parameter completion: Completion handler return the data and an error, they are optional in a mutually exclusive way
  func borrowBook(urlString: String,
                  username: String,
                  PIN: String,
                  completion: @escaping (_ json: [String: Any]?, _: Error?)->()) {
    guard let url = URL(string: urlString) else {
      let userInfo = ["url": urlString]
      let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: userInfo)
      completion(nil, error)
      return
    }
    
    let header = basicAuthHeader(username: username, password: PIN)
    
    let request = urlRequest(url: url, method: .GET, header: header)
    
    post(request: request) { result in
      switch result {
      case .success(let json):
        completion(json, nil)
      case .failure(let error):
        completion(nil, error)
      }
    }
  }
    
  /// Fulfilling Overdrive loan for a book to get the Scope and the manifest download url
  /// To get the data we need from response header, we need to prevent HTTP redirection
  ///
  /// - Parameter urlString: URL for loan fulfillment
  /// - Parameter username: Library username / barcode
  /// - Parameter PIN: Library PIN / password
  /// - Parameter completion: This is always called and returns either the
  /// response headers or an error in a mutually exclusive way. The response
  /// headers keys are all lowercased.
  public func fulfillBook(urlString: String,
                          username: String,
                          PIN: String,
                          completion: @escaping (_ responseHeader: [String: Any]?, _ error: NSError?)->()) {
    guard let url = URL(string: urlString) else {
      let userInfo = ["url": urlString]
      let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: userInfo)
      completion(nil, error)
      return
    }
    
    let header = basicAuthHeader(username: username, password: PIN)
    
    let request = urlRequest(url: url, method: .GET, header: header)
    
    responder.shouldPerformHTTPRedirection = false
    
    let task = urlSession.dataTask(with: request) { (data, response, error) in
        
      if let error = error as NSError? {
        completion(nil, error)
        return
      }
        
      guard let response = (response as? HTTPURLResponse) else {
        let userInfo = ["url": urlString]
        let error = NSError(domain: NYPLOverdriveDomain,
                            code: NYPLOverdriveErrorCode.nilHTTPResponse.rawValue,
                            userInfo: userInfo)
        completion(nil, error)
        return
      }
    
      guard var responseHeaders = response.allHeaderFields as? [String: Any] else {
        var headerFields = response.allHeaderFields
        headerFields.removeValue(forKey: "Authorization")
        headerFields.removeValue(forKey: "authorization")
        let error = NSError(domain: NYPLOverdriveDomain, code: NYPLOverdriveErrorCode.invalidResponseHeader.rawValue, userInfo: ["header":headerFields])
        completion(nil, error)
        return
      }

      responseHeaders.formLowercaseKeys()
    
      completion(responseHeaders, nil)
    }
    
    task.resume()
  }
    
  // MARK: - Authentication

  ///    Refresh bearer token from Overdrive
  ///
  ///     - Parameter key: Overdrive client key
  ///     - Parameter secret: Overdrive client secret
  ///     - Parameter completion: Completion handler return an token and an error, they are optional in a mutually exclusive way
  public func refreshBearerToken(key: String,
                                 secret: String,
                                 completion: @escaping (_ error: Error?)->()) {
      
    let grantType = "grant_type=client_credentials"
    
    guard let url = URL(string: OverdriveAPIHost.OAuthHost.rawValue + OverdriveAPIEndpoint.Token.rawValue),
      let body = grantType.data(using: .ascii) else {
        let userInfo = ["url": OverdriveAPIHost.OAuthHost.rawValue + OverdriveAPIEndpoint.Token.rawValue,
                        "body": grantType]
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: userInfo)
        completion(error)
        return
    }
    
    let header = basicAuthHeader(username: key, password: secret)
    
    let request = urlRequest(url: url, method: .POST, header: header, body: body)
    
    post(request: request) { result in
      switch result {
      case .success(let json):
        guard let token = OverdriveToken(json: json) else {
          let error = NSError(domain: NYPLOverdriveDomain,
                              code: NYPLOverdriveErrorCode.parseTokenError.rawValue,
                              userInfo: json)
          completion(error)
          return
        }
        
        self.bearerToken = token
        completion(nil)
      case .failure(let error):
        completion(error)
      }
    }
  }
  
  ///    Refresh patron token from Overdrive
  ///
  ///     - Parameter key: Overdrive client key
  ///     - Parameter secret: Overdrive client secret
  ///     - Parameter username: Patron's library card number
  ///     - Parameter secret: Patron's PIN
  ///     - Parameter scope: Scope from circulation manager
  ///     - Parameter completion: Completion handler return an token and an error, they are optional in a mutually exclusive way
  public func refreshPatronToken(key: String,
                                 secret: String,
                                 username: String,
                                 PIN: String?,
                                 scope: String,
                                 completion: @escaping (_ error: Error?)->())
  {
    var bodyArray = [
      "grant_type=password",
      "username=\(username)",
      "scope=\(scope)"
    ]
    
    if let PIN = PIN, !PIN.isEmpty {
      bodyArray.append("password=\(PIN)")
    } else {
      bodyArray.append("password=ignored")
      bodyArray.append("password_required=false")
    }
    
    let bodyString = bodyArray.joined(separator: "&")
    
    guard let url = URL(string: OverdriveAPIHost.OAuthPatronHost.rawValue + OverdriveAPIEndpoint.PatronToken.rawValue),
      let body = bodyString.data(using: .ascii) else {
        let userInfo = ["url": OverdriveAPIHost.OAuthPatronHost.rawValue + OverdriveAPIEndpoint.PatronToken.rawValue,
                        "body": bodyString]
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: userInfo)
        completion(error)
        return
    }
    
    let header = basicAuthHeader(username: key, password: secret)
    
    let request = urlRequest(url: url, method: .POST, header: header, body: body)
    
    post(request: request) { result in
      switch result {
      case .success(let json):
        guard let token = OverdriveToken(json: json) else {
          let error = NSError(domain: NYPLOverdriveDomain,
                              code: NYPLOverdriveErrorCode.parseTokenError.rawValue,
                              userInfo: json)
          completion(error)
          return
        }
        
        self.patronTokenLock.lock()
        
        self.patronTokens[self.tokenKey(username: username, scope: scope)] = token
        
        self.patronTokenLock.unlock()
        completion(nil)
      case .failure(let error):
        completion(error)
      }
    }
  }
  
  public func hasValidPatronToken(username: String, scope: String) -> Bool {
    guard let token = patronTokens[tokenKey(username: username, scope: scope)] else {
      return false
    }
    
    return !token.isExpired()
  }
  
  // MARK: - Network request
  
  private func post(request: URLRequest,
                    completion: @escaping (_ result: Result<[String: Any], Error>)->()) {
    responder.shouldPerformHTTPRedirection = true
    
    let task = urlSession.dataTask(with: request) { (data, response, error) in

      if let error = error as NSError? {
        completion(.failure(error))
        return
      }

      guard let response = (response as? HTTPURLResponse) else {
        let error = NSError(domain: NYPLOverdriveDomain,
                            code: NYPLOverdriveErrorCode.nilHTTPResponse.rawValue,
                            userInfo: ["request": request.loggableString])
        completion(.failure(error))
        return
      }

      guard response.statusCode != 204 else {
        completion(.success([:]))
        return
      }

      guard let data = data else {
        let error = NSError(domain: NYPLOverdriveDomain,
                            code: NYPLOverdriveErrorCode.nilData.rawValue,
                            userInfo: ["request": request.loggableString,
                                       "response": response])
        completion(.failure(error))
        return
      }

      if let oauthError = try? NYPLOAuth2Error.fromData(data) {
        let error = oauthError.nsError(forRequest: request, response: response)
        let nsError = NSError(domain: "OverdriveAPI: " + error.domain,
                              code: error.code, userInfo: error.userInfo)
        completion(.failure(nsError))
        return
      }

      guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String:Any] else {
        let error = NSError(domain: NYPLOverdriveDomain,
                            code: NYPLOverdriveErrorCode.parseJsonFail.rawValue,
                            userInfo: ["request": request.loggableString,
                                       "response data": String(data: data, encoding: .utf8) ?? "",
                                       "response": response])
        completion(.failure(error))
        return
      }

      guard response.statusCode >= 200 && response.statusCode <= 299 else {
        let error = NSError(domain: NYPLOverdriveDomain,
                            code: NYPLOverdriveErrorCode.authorizationFail.rawValue,
                            userInfo: ["request": request.loggableString,
                                       "error_json": json,
                                       "response": response])
        completion(.failure(error))
        return
      }

      completion(.success(json))
    }
        
    task.resume()
  }

  // MARK: - Helpers
  
  private func urlRequest(url: URL, method: HTTPMethodType, header: [String: String] = [:], body: Data? = nil) -> URLRequest {
    var request = URLRequest(url: url)
    
    request.httpMethod = method.rawValue
    request.httpBody = body
    
    for (headerKey, headerValue) in header {
      request.setValue(headerValue, forHTTPHeaderField: headerKey)
    }
      
    return request
  }
  
  private func basicAuthHeader(username: String, password: String) -> [String: String] {
    let authString = Data("\(username):\(password)".utf8).base64EncodedString()
    return ["Authorization": "Basic \(authString)"]
  }
  
  private func tokenKey(username: String, scope: String) -> String {
    return "\(username)_\(scope)"
  }
}
