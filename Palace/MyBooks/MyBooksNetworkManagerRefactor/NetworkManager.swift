//
//  NetworkManager.swift
//  Palace
//
//  Created by Maurice Carrier on 6/19/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

class NetworkManager: NSObject {
  static let shared = NetworkManager()
  var delegate: BooksNetworkManagerDelegate?
  
  private var session: URLSession!
  private var broadcastScheduled = false
  var bookIdentifierToDownloadInfo: [String: MyBooksDownloadInfo ] = [:]
  var bookIdentifierToDownloadProgress: [String: Progress] = [:]
  var bookIdentifierToDownloadTask: [String: URLSessionDownloadTask] = [:]
  var taskIdentifierToBook: [Int: TPPBook] = [:]
  private var taskIdentifierToRedirectAttempts: [Int: Int] = [:]
  private var reauthenticator = TPPReauthenticator()

  override init() {
    super.init()
    self.session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
  }

  func persistDownloadState() {}
  func restoreDownloadState() {}
}

extension NetworkManager {
  enum State {
    
  }
}

extension NetworkManager: BooksDownloadManager {
  @objc func startDownload(for book: TPPBook) {
    let downloadAction = { [weak self] in
      self?.startDownload(for: book, withRequest: nil)
    }
    
    book.defaultAcquisition?.availability.matchUnavailable(
      nil,
      limited: { _ in downloadAction() },
      unlimited: { _ in downloadAction() },
      reserved: nil,
      ready: { _ in downloadAction() }
    )
  }

  func pauseDownload(for book: TPPBook) {
    guard let downloadTask = bookIdentifierToDownloadTask[book.identifier] else {
      return
    }
    
    downloadTask.suspend()
  }
  
  func cancelDownload(for book: TPPBook) {
    guard let downloadTask = bookIdentifierToDownloadTask[book.identifier] else {
      return
    }
    
    downloadTask.cancel()
    bookIdentifierToDownloadTask.removeValue(forKey: book.identifier)
    bookIdentifierToDownloadInfo.removeValue(forKey: book.identifier)
    taskIdentifierToBook.removeValue(forKey: downloadTask.taskIdentifier)
    
    TPPBookRegistry.shared.setState(.DownloadNeeded, for: book.identifier)
    broadcastUpdate()
  }
  
  func resumeDownload(for book: TPPBook) {
    guard let downloadTask = bookIdentifierToDownloadTask[book.identifier] else {
      return
    }
    
    downloadTask.resume()
  }
}

extension NetworkManager {
  func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest? = nil) {
    let state = TPPBookRegistry.shared.state(for: book.identifier)
    
    guard let loginRequired = TPPUserAccount.sharedAccount().authDefinition?.needsAuth
    else { return }
    
    let location = TPPBookRegistry.shared.location(forIdentifier: book.identifier)
    switch state {
    case .Unregistered:
      processUnregisteredState(
        for: book,
        location: location,
        loginRequired: loginRequired
      )
    case .Downloading:
      return
    case .DownloadFailed, .DownloadNeeded, .Holding, .SAMLStarted:
      break
    case .DownloadSuccessful, .Used, .Unsupported:
      NSLog("Ignoring nonsensical download request.")
      return
    }
    
    processDownload(
      for: book,
      withState: state,
      andRequest: initedRequest,
      loginRequired: loginRequired
    )
  }

  func processUnregisteredState(for book: TPPBook, location: TPPBookLocation?, loginRequired: Bool) {
    guard book.defaultAcquisitionIfBorrow == nil,
          ((book.defaultAcquisitionIfOpenAccess != nil) || !loginRequired) else {
      TPPBookRegistry.shared.addBook(book, location: location, state: .DownloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
      return
    }
  }

  private func processDownload(for book: TPPBook, withState state: TPPBookState, andRequest initedRequest: URLRequest?, loginRequired: Bool) {
    if TPPUserAccount.sharedAccount().hasCredentials() || !loginRequired {
      processDownloadWithCredentials(for: book, withState: state, andRequest: initedRequest)
    } else {
      requestCredentialsAndStartDownload(for: book)
    }
  }

  private func requestCredentialsAndStartDownload(for book: TPPBook) {
#if FEATURE_DRM_CONNECTOR
    if AdobeCertificate.defaultCertificate?.hasExpired ?? false {
      // ADEPT crashes the app with expired certificate.
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: TPPAlertUtils.expiredAdobeDRMAlert(), viewController: nil, animated: true, completion: nil)
    } else {
      TPPAccountSignInViewController.requestCredentials {
        self.startDownload(for: book)
      }
    }
#else
    TPPAccountSignInViewController.requestCredentials { [weak self] in
      self?.startDownload(for: book)
    }
#endif
  }
  
  private func processDownloadWithCredentials(
    for book: TPPBook,
    withState state: TPPBookState,
    andRequest initedRequest: URLRequest?
  ) {
    if state == .Unregistered || state == .Holding {
      startBorrowForBook(book, attemptDownload: true, borrowCompletion: nil)
    } else if book.distributor == OverdriveDistributorKey && book.defaultBookContentType == .audiobook {
#if FEATURE_OVERDRIVE
      processOverdriveDownload(for: book, withState: state)
#endif
    } else {
      processRegularDownload(for: book, withState: state, andRequest: initedRequest)
    }
  }

  @objc func startBorrowForBook(_ book: TPPBook, attemptDownload shouldAttemptDownload: Bool, borrowCompletion: (() -> Void)?) {
    TPPBookRegistry.shared.setProcessing(true, for: book.identifier)
    
    TPPOPDSFeed.withURL(book.defaultAcquisitionIfBorrow?.hrefURL, shouldResetCache: true) { [weak self] feed, error in
      guard let self = self else { return }
      TPPBookRegistry.shared.setProcessing(false, for: book.identifier)
      
      if let feed = feed, !feed.entries.isEmpty,
         let borrowedEntry = feed.entries.first as? TPPOPDSEntry,
         let borrowedBook = TPPBook(entry: borrowedEntry),
         let location = TPPBookRegistry.shared.location(forIdentifier: borrowedBook.identifier) {
        
        TPPBookRegistry.shared.addBook(
          borrowedBook,
          location: location,
          state: .DownloadNeeded,
          fulfillmentId: nil,
          readiumBookmarks: nil,
          genericBookmarks: nil
        )
        
        if shouldAttemptDownload {
          startDownload(for: borrowedBook)
        }
        
      } else {
        self.delegate?.process(error: error as? [String: Any], for: book)
      }
      
      DispatchQueue.main.async {
        borrowCompletion?()
      }
    }
  }

  private func processOverdriveDownload(for book: TPPBook, withState state: TPPBookState) {
    guard let url = book.defaultAcquisition?.hrefURL else { return }
#if canImport(ADEPT)
    OverdriveAPIExecutor.shared.fulfillBook(withUrlString: url.absoluteString, username: TPPUserAccount.sharedAccount().barcode, PIN: TPPUserAccount.sharedAccount().PIN) { [weak self] responseHeaders, error in
      self?.handleOverdriveResponse(for: book, url: URL, withState: state, responseHeaders: responseHeaders, error: error)
    }
#endif
  }
  
  private func processRegularDownload(for book: TPPBook, withState state: TPPBookState, andRequest initedRequest: URLRequest?) {
    guard let url = book.defaultAcquisition?.hrefURL else { return }
    let request = initedRequest ?? TPPNetworkExecutor.bearerAuthorized(request: URLRequest(url: url))
    
    guard let requestURL = request.url else {
      logInvalidURLRequest(for: book, withState: state, url: url, request: request)
      return
    }
    
    if TPPUserAccount.sharedAccount().cookies != nil && state != .SAMLStarted {
      processSAMLCookies(for: book, withRequest: request)
    } else {
      addDownloadTask(with: request, book: book)
    }
  }

  private func logInvalidURLRequest(for book: TPPBook, withState state: TPPBookState, url: URL?, request: URLRequest?) {
    TPPBookRegistry.shared.setState(.SAMLStarted, for: book.identifier)
    guard let someCookies = TPPUserAccount.sharedAccount().cookies, var mutableRequest = request else { return }
    
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      
      mutableRequest.cachePolicy = .reloadIgnoringCacheData
      
      let loginCancelHandler: () -> Void = { [weak self] in
        TPPBookRegistry.shared.setState(.DownloadNeeded, for: book.identifier)
        self?.cancelDownload(for: book.identifier)
      }
      
      let bookFoundHandler: (_ request: URLRequest?, _ cookies: [HTTPCookie]) -> Void = { [weak self] request, cookies in
        TPPUserAccount.sharedAccount().setCookies(cookies)
        self?.startDownload(for: book, withRequest: mutableRequest)
      }
      
      let problemFoundHandler: (_ problemDocument: TPPProblemDocument?) -> Void = { [weak self] problemDocument in
        TPPBookRegistry.shared.setState(.DownloadNeeded, for: book.identifier)
        
        self?.reauthenticator.authenticateIfNeeded(TPPUserAccount.sharedAccount(), usingExistingCredentials: false) { [weak self] in
          self?.startDownload(for: book)
        }
      }
      
      let model = TPPCookiesWebViewModel(
        cookies: someCookies,
        request: mutableRequest,
        loginCompletionHandler: nil,
        loginCancelHandler: loginCancelHandler,
        bookFoundHandler: bookFoundHandler,
        problemFoundHandler: problemFoundHandler,
        autoPresentIfNeeded: true
      )
      let cookiesVC = TPPCookiesWebViewController(model: model)
      cookiesVC.loadViewIfNeeded()
    }
  }

  private func processSAMLCookies(for book: TPPBook, withRequest request: URLRequest) {
    let cookieStorage = session.configuration.httpCookieStorage
    if let cookies = TPPUserAccount.sharedAccount().cookies {
      for cookie in cookies {
        cookieStorage?.setCookie(cookie)
      }
    }
    
    addDownloadTask(with: request, book: book)
  }

  func cancelDownload(for bookIdentifier: String) {
    guard let info = downloadInfo(forBookIdentifier: bookIdentifier) else {
      let state = TPPBookRegistry.shared.state(for: bookIdentifier)
      if state != .DownloadFailed {
        NSLog("Ignoring nonsensical cancellation request.")
        return
      }
      
      TPPBookRegistry.shared.setState(.DownloadNeeded, for: bookIdentifier)
      return
    }
    
#if FEATURE_DRM_CONNECTOR
    if info.rightsManagement == .adobe {
      NYPLADEPT.sharedInstance().cancelFulfillment(withTag: bookIdentifier)
      return
    }
#endif
    
    info.downloadTask.cancel { resumeData in
      TPPBookRegistry.shared.setState(.DownloadNeeded, for: bookIdentifier)
      self.broadcastUpdate()
    }
  }
  
  private func downloadInfo(forBookIdentifier bookIdentifier: String) -> MyBooksDownloadInfo? {
    bookIdentifierToDownloadInfo[bookIdentifier]
  }

  private func broadcastUpdate() {
    guard !broadcastScheduled else { return }
    
    broadcastScheduled = true
    
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      self.broadcastUpdateNow()
    }
  }
  
  private func broadcastUpdateNow() {
    broadcastScheduled = false
    
    NotificationCenter.default.post(
      name: Notification.Name.TPPMyBooksDownloadCenterDidChange,
      object: self
    )
  }
}

extension NetworkManager: URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
      let handler = TPPBasicAuth(credentialsProvider: TPPUserAccount.sharedAccount())
      handler.handleChallenge(challenge, completion: completionHandler)
    }
  
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let maxRedirectAttempts: UInt = 10
    
    var redirectAttempts = self.taskIdentifierToRedirectAttempts[task.taskIdentifier] ?? 0
    
    if redirectAttempts >= maxRedirectAttempts {
      completionHandler(nil)
      return
    }
    
    redirectAttempts += 1
    self.taskIdentifierToRedirectAttempts[task.taskIdentifier] = redirectAttempts
    
    let authorizationKey = "Authorization"
    
    // Since any "Authorization" header will be dropped on redirection for security
    // reasons, we need to again manually set the header for the redirected request
    // if we originally manually set the header to a bearer token. There's no way
    // to use URLSession's standard challenge handling approach for bearer tokens.
    if let originalAuthorization = task.originalRequest?.allHTTPHeaderFields?[authorizationKey],
       originalAuthorization.hasPrefix("Bearer") {
      // Do not pass on the bearer token to other domains.
      if task.originalRequest?.url?.host != request.url?.host {
        completionHandler(request)
        return
      }
      
      // Prevent redirection from HTTPS to a non-HTTPS URL.
      if task.originalRequest?.url?.scheme == "https" && request.url?.scheme != "https" {
        completionHandler(nil)
        return
      }
      
      var mutableAllHTTPHeaderFields = request.allHTTPHeaderFields ?? [:]
      mutableAllHTTPHeaderFields[authorizationKey] = originalAuthorization
      
      var mutableRequest = URLRequest(url: request.url!)
      mutableRequest.allHTTPHeaderFields = mutableAllHTTPHeaderFields
      
      completionHandler(mutableRequest)
    } else {
      completionHandler(request)
    }
  }
  
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let book = self.taskIdentifierToBook[task.taskIdentifier] else {
      return
    }
    
    self.taskIdentifierToRedirectAttempts.removeValue(forKey: task.taskIdentifier)
    
    if let error = error as NSError?, error.code != NSURLErrorCancelled {
      logBookDownloadFailure(book, reason: "networking error", downloadTask: task, metadata: ["urlSessionError": error])
      failDownloadWithAlert(for: book)
      return
    }
  }
  
  @objc func addDownloadTask(with request: URLRequest, book: TPPBook) {
    let task = self.session.downloadTask(with: request)
    
    self.bookIdentifierToDownloadInfo[book.identifier] =
    MyBooksDownloadInfo(downloadProgress: 0.0,
                        downloadTask: task,
                        rightsManagement: .unknown)
    
    self.taskIdentifierToBook[task.taskIdentifier] = book
    
    task.resume()
    
    let location = TPPBookRegistry.shared.location(forIdentifier: book.identifier)
    
    TPPBookRegistry.shared.addBook(book,
                                   location: location,
                                   state: .Downloading,
                                   fulfillmentId: nil,
                                   readiumBookmarks: nil,
                                   genericBookmarks: nil)
    
    NotificationCenter.default.post(name: .TPPMyBooksDownloadCenterDidChange, object: self)
  }
}

extension NetworkManager: URLSessionDownloadDelegate {
  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didResumeAtOffset fileOffset: Int64,
    expectedTotalBytes: Int64
  ) {
    NSLog("Ignoring unexpected resumption.")
  }
  
  private func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int,
    totalBytesWritten: Int,
    totalBytesExpectedToWrite: Int
  ) {
    let key = downloadTask.taskIdentifier
    guard let book = taskIdentifierToBook[key] else {
      return
    }
    
    if bytesWritten == totalBytesWritten {
      guard let mimeType = downloadTask.response?.mimeType else { return }
      
      switch mimeType {
      case ContentTypeAdobeAdept:
        bookIdentifierToDownloadInfo[book.identifier] =
        downloadInfo(forBookIdentifier: book.identifier)?.withRightsManagement(.adobe)
      case ContentTypeReadiumLCP:
        bookIdentifierToDownloadInfo[book.identifier] =
        downloadInfo(forBookIdentifier: book.identifier)?.withRightsManagement(.lcp)
      case ContentTypeEpubZip:
        bookIdentifierToDownloadInfo[book.identifier] =
        downloadInfo(forBookIdentifier: book.identifier)?.withRightsManagement(.none)
      case ContentTypeBearerToken:
        bookIdentifierToDownloadInfo[book.identifier] =
        downloadInfo(forBookIdentifier: book.identifier)?.withRightsManagement(.simplifiedBearerTokenJSON)
#if FEATURE_OVERDRIVE
      case "application/json":
        bookIdentifierToDownloadInfo[book.identifier] =
        downloadInfo(forBookIdentifier: book.identifier)?.withRightsManagement(.overdriveManifestJSON)
#endif
      default:
        if TPPOPDSAcquisitionPath.supportedTypes().contains(mimeType) {
          NSLog("Presuming no DRM for unrecognized MIME type \"\(mimeType)\".")
          if let info = downloadInfo(forBookIdentifier: book.identifier)?.withRightsManagement(.none) {
            bookIdentifierToDownloadInfo[book.identifier] = info
          }
        } else {
          NSLog("Authentication might be needed after all")
          downloadTask.cancel()
          TPPBookRegistry.shared.setState(.DownloadFailed, for: book.identifier)
          broadcastUpdate()
          return
        }
      }
    }
    
    let rightsManagement = downloadInfo(forBookIdentifier: book.identifier)?.rightsManagement ?? .none
    if rightsManagement != MyBooksDownloadInfo.RightsManagement.adobe && rightsManagement != MyBooksDownloadInfo.RightsManagement.simplifiedBearerTokenJSON && rightsManagement != MyBooksDownloadInfo.RightsManagement.overdriveManifestJSON {
      if totalBytesExpectedToWrite > 0 {
        bookIdentifierToDownloadInfo[book.identifier] =
        downloadInfo(forBookIdentifier: book.identifier)?
          .withDownloadProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        broadcastUpdate()
      }
    }
  }
  
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let book = taskIdentifierToBook[downloadTask.taskIdentifier] else {
      return
    }
    
    taskIdentifierToRedirectAttempts.removeValue(forKey: downloadTask.taskIdentifier)
    
    var failureRequiringAlert = false
    var failureError = downloadTask.error
    var problemDoc: TPPProblemDocument?
    let rights = downloadInfo(forBookIdentifier: book.identifier)?.rightsManagement ?? .unknown
    
    if let response = downloadTask.response, response.isProblemDocument() {
      do {
        let problemDocData = try Data(contentsOf: location)
        problemDoc = try TPPProblemDocument.fromData(problemDocData)
      } catch let error {
        TPPErrorLogger.logProblemDocumentParseError(error as NSError, problemDocumentData: nil, url: location, summary: "Error parsing problem doc downloading \(String(describing: book.distributor)) book", metadata: ["book": book.loggableShortString])
      }
      
      try? FileManager.default.removeItem(at: location)
      failureRequiringAlert = true
    }
    
    if !book.canCompleteDownload(withContentType: downloadTask.response?.mimeType ?? "") {
      try? FileManager.default.removeItem(at: location)
      failureRequiringAlert = true
    }
    
    if failureRequiringAlert {
      logBookDownloadFailure(book, reason: "Download Error", downloadTask: downloadTask, metadata: ["problemDocument": problemDoc?.dictionaryValue ?? "N/A"])
    } else {
      TPPProblemDocumentCacheManager.sharedInstance().clearCachedDoc(book.identifier)
      
      switch rights {
      case .unknown:
        logBookDownloadFailure(book, reason: "Unknown rights management", downloadTask: downloadTask, metadata: nil)
        failureRequiringAlert = true
      case .adobe:
#if FEATURE_DRM_CONNECTOR
        if let acsmData = try? Data(contentsOf: location),
           let acsmString = String(data: acsmData, encoding: .utf8),
           acsmString.contains(">application/pdf</dc:format>") {
          let msg = NSLocalizedString("\(book.title) is an Adobe PDF, which is not supported.", comment: "")
          failureError = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.ignore.rawValue, userInfo: [NSLocalizedDescriptionKey: msg])
          logBookDownloadFailure(book, reason: "Received PDF for AdobeDRM rights", downloadTask: downloadTask, metadata: nil)
          failureRequiringAlert = true
        } else if let acsmData = try? Data(contentsOf: location) {
          NSLog("Download finished. Fulfilling with userID: \((TPPUserAccount.sharedAccount().userID)!)")
          NYPLADEPT.sharedInstance().fulfill(withACSMData: acsmData, tag: book.identifier, userID: TPPUserAccount.sharedAccount().userID, deviceID: TPPUserAccount.sharedAccount().deviceID)
        }
#endif
      case .lcp:
        fulfillLCPLicense(fileUrl: location, forBook: book, downloadTask: downloadTask)
      case .simplifiedBearerTokenJSON:
        if let data = try? Data(contentsOf: location) {
          if let dictionary = TPPJSONObjectFromData(data) as? [String: Any],
             let simplifiedBearerToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dictionary) {
            let mutableRequest = NSMutableURLRequest(url: simplifiedBearerToken.location)
            mutableRequest.setValue("Bearer \(simplifiedBearerToken.accessToken)", forHTTPHeaderField: "Authorization")
            
            let task = session.downloadTask(with: mutableRequest as URLRequest)
            bookIdentifierToDownloadInfo[book.identifier] = MyBooksDownloadInfo(
              downloadProgress: 0.0,
              downloadTask: task,
              rightsManagement: .none,
              bearerToken: simplifiedBearerToken
            )
            book.bearerToken = simplifiedBearerToken.accessToken
            taskIdentifierToBook[task.taskIdentifier] = book
            task.resume()
          } else {
            logBookDownloadFailure(book, reason: "No Simplified Bearer Token in deserialized data", downloadTask: downloadTask, metadata: nil)
            failDownloadWithAlert(for: book)
          }
        } else {
          logBookDownloadFailure(book, reason: "No Simplified Bearer Token data available on disk", downloadTask: downloadTask, metadata: nil)
          failDownloadWithAlert(for: book)
        }
      case .overdriveManifestJSON:
        failureRequiringAlert = !replaceBook(book, withFileAtURL: location, forDownloadTask: downloadTask)
      case .none:
        failureRequiringAlert = !moveFile(at: location, toDestinationForBook: book, forDownloadTask: downloadTask)
      }
    }
    
    if failureRequiringAlert {
      DispatchQueue.main.async {
        let hasCredentials = TPPUserAccount.sharedAccount().hasCredentials()
        let loginRequired = TPPUserAccount.sharedAccount().authDefinition?.needsAuth ?? false
        if downloadTask.response?.indicatesAuthenticationNeedsRefresh(with: problemDoc) == true || (!hasCredentials && loginRequired) {
          self.reauthenticator.authenticateIfNeeded(
            TPPUserAccount.sharedAccount(),
            usingExistingCredentials: hasCredentials,
            authenticationCompletion: nil
          )
        }
        self.alertForProblemDocument(problemDoc, error: failureError, book: book)
      }
      TPPBookRegistry.shared.setState(.DownloadFailed, for: book.identifier)
    }
    
    broadcastUpdate()
  }
}

extension NetworkManager {
  private func logBookDownloadFailure(_ book: TPPBook, reason: String, downloadTask: URLSessionTask, metadata: [String: Any]?) {
    let rights = downloadInfo(forBookIdentifier: book.identifier)?.rightsManagementString ?? ""
    let bookType = TPPBookContentTypeConverter.stringValue(of: book.defaultBookContentType)
    let context = "\(String(describing: book.distributor)) \(bookType) download fail: \(reason)"
    
    var dict: [String: Any] = metadata ?? [:]
    dict["book"] = book.loggableDictionary
    dict["rightsManagement"] = rights
    dict["taskOriginalRequest"] = downloadTask.originalRequest?.loggableString
    dict["taskCurrentRequest"] = downloadTask.currentRequest?.loggableString
    dict["response"] = downloadTask.response ?? "N/A"
    dict["downloadError"] = downloadTask.error ?? "N/A"
    
    TPPErrorLogger.logError(withCode: .downloadFail, summary: context, metadata: dict)
  }
  
  func fulfillLCPLicense(fileUrl: URL, forBook book: TPPBook, downloadTask: URLSessionDownloadTask) {
#if LCP
    let lcpService = LCPLibraryService()
    let licenseUrl = fileUrl.deletingPathExtension().appendingPathExtension(lcpService.licenseExtension)
    
    do {
      _ = try FileManager.default.replaceItemAt(licenseUrl, withItemAt: fileUrl)
    } catch {
      TPPErrorLogger.logError(error, summary: "Error renaming LCP license file", metadata: [
        "fileUrl": fileUrl.absoluteString,
        "licenseUrl": licenseUrl.absoluteString,
        "book": book.loggableDictionary
      ])
      failDownloadWithAlert(for: book)
      return
    }
    
    let lcpProgress: (Double) -> Void = { [weak self] progressValue in
      guard let self = self else { return }
      self.bookIdentifierToDownloadInfo[book.identifier] = self.downloadInfo(forBookIdentifier: book.identifier)?.withDownloadProgress(progressValue)
      self.broadcastUpdate()
    }
    
    let lcpCompletion: (URL?, Error?) -> Void = { [weak self] localUrl, error in
      guard let self = self else { return }
      if let error = error {
        let summary = "\(String(describing: book.distributor)) LCP license fulfillment error"
        TPPErrorLogger.logError(error, summary: summary, metadata: [
          "book": book.loggableDictionary,
          "licenseURL": licenseUrl.absoluteString,
          "localURL": localUrl?.absoluteString ?? "N/A"
        ])
        let errorMessage = "Fulfilment Error: \(error.localizedDescription)"
        self.failDownloadWithAlert(for: book, withMessage: errorMessage)
        return
      }
      
      guard let localUrl = localUrl,
            let license = TPPLCPLicense(url: licenseUrl),
            self.replaceBook(book, withFileAtURL: localUrl, forDownloadTask: downloadTask)
      else {
        let errorMessage = "Error replacing license file with file \(localUrl?.absoluteString ?? "")"
        self.failDownloadWithAlert(for: book, withMessage: errorMessage)
        return
      }
      TPPBookRegistry.shared.setFulfillmentId(license.identifier, for: book.identifier)
      
      if book.defaultBookContentType == .pdf,
         let bookURL = self.fileUrl(for: book.identifier) {
        TPPBookRegistry.shared.setState(.Downloading, for: book.identifier)
        LCPPDFs(url: bookURL)?.extract(url: bookURL) { _, _ in
          TPPBookRegistry.shared.setState(.DownloadSuccessful, for: book.identifier)
        }
      }
    }
    
    let fulfillmentDownloadTask = lcpService.fulfill(licenseUrl, progress: lcpProgress, completion: lcpCompletion)
    if let fulfillmentDownloadTask = fulfillmentDownloadTask {
      self.bookIdentifierToDownloadInfo[book.identifier] = MyBooksDownloadInfo(downloadProgress: 0.0, downloadTask: fulfillmentDownloadTask, rightsManagement: .none)
    }
#endif
  }
  
  func failDownloadWithAlert(for book: TPPBook, withMessage message: String? = nil) {
    let location = TPPBookRegistry.shared.location(forIdentifier: book.identifier)
    
    TPPBookRegistry.shared.addBook(book,
                                   location: location,
                                   state: .DownloadFailed,
                                   fulfillmentId: nil,
                                   readiumBookmarks: nil,
                                   genericBookmarks: nil)
    
    DispatchQueue.main.async {
      let errorMessage = message ?? "No error message"
      let formattedMessage = String.localizedStringWithFormat(NSLocalizedString("The download for %@ could not be completed.", comment: ""), book.title)
      let finalMessage = "\(formattedMessage)\n\(errorMessage)"
      let alert = TPPAlertUtils.alert(title: "DownloadFailed", message: finalMessage)
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
    }
    
    broadcastUpdate()
  }
  
  func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook) {
    let msg = String(format: NSLocalizedString("The download for %@ could not be completed.", comment: ""), book.title)
    let alert = TPPAlertUtils.alert(title: "DownloadFailed", message: msg)
    
    if let problemDoc = problemDoc {
      TPPProblemDocumentCacheManager.sharedInstance().cacheProblemDocument(problemDoc, key: book.identifier)
      TPPAlertUtils.setProblemDocument(controller: alert, document: problemDoc, append: true)
      
      if problemDoc.type == TPPProblemDocument.TypeNoActiveLoan {
        TPPBookRegistry.shared.removeBook(forIdentifier: book.identifier)
      }
    } else if let error = error {
      alert.message = String(format: "%@\n\nError: %@", msg, error.localizedDescription)
    }
    
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
  
  func moveFile(at sourceLocation: URL, toDestinationForBook book: TPPBook, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool {
    var removeError: Error?
    var moveError: Error?
    
    guard let finalFileURL = fileUrl(for: book.identifier) else { return false }
    
    do {
      try FileManager.default.removeItem(at: finalFileURL)
    } catch {
      removeError = error
    }
    
    var success = false
    
    do {
      try FileManager.default.moveItem(at: sourceLocation, to: finalFileURL)
      success = true
    } catch {
      moveError = error
    }
    
    if success {
      TPPBookRegistry.shared.setState(.DownloadSuccessful, for: book.identifier)
    } else if let moveError = moveError {
      logBookDownloadFailure(book, reason: "Couldn't move book to final disk location", downloadTask: downloadTask, metadata: [
        "moveError": moveError,
        "removeError": removeError?.localizedDescription ?? "N/A",
        "sourceLocation": sourceLocation.absoluteString,
        "finalFileURL": finalFileURL.absoluteString
      ])
    }
    
    return success
  }
  
  private func replaceBook(_ book: TPPBook, withFileAtURL sourceLocation: URL, forDownloadTask downloadTask: URLSessionDownloadTask) -> Bool {
    guard let destURL = fileUrl(for: book.identifier) else { return false }
    do {
      let _ = try FileManager.default.replaceItemAt(destURL, withItemAt: sourceLocation, options: .usingNewMetadataOnly)
      TPPBookRegistry.shared.setState(.DownloadSuccessful, for: book.identifier)
      return true
    } catch {
      logBookDownloadFailure(book,
                             reason: "Couldn't replace downloaded book",
                             downloadTask: downloadTask,
                             metadata: [
                              "replaceError": error,
                              "destinationFileURL": destURL as Any,
                              "sourceFileURL": sourceLocation as Any
                             ])
    }
    
    return false
  }
  
  func fileUrl(for identifier: String, account: String = AccountsManager.shared.currentAccountId ?? "") -> URL? {
    guard let book = TPPBookRegistry.shared.book(forIdentifier: identifier) else {
      return nil
    }
    
    let pathExtension = pathExtension(for: book)
    let contentDirectoryURL = self.contentDirectoryURL(account)
    let hashedIdentifier = identifier.sha256()
    
    return contentDirectoryURL?.appendingPathComponent(hashedIdentifier).appendingPathExtension(pathExtension)
  }
  
  func contentDirectoryURL(_ account: String = AccountsManager.shared.currentAccountId ?? "") -> URL? {
    guard let directoryURL = TPPBookContentMetadataFilesHelper.directory(for: account)?.appendingPathComponent("content") else {
      NSLog("[contentDirectoryURL] nil directory.")
      return nil
    }
    
    var isDirectory: ObjCBool = false
    if !FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
      do {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
      } catch {
        NSLog("Failed to create directory.")
        return nil
      }
    }
    
    return directoryURL
  }
  
  func pathExtension(for book: TPPBook?) -> String {
#if LCP
    if let book = book {
      if LCPAudiobooks.canOpenBook(book) {
        return "lcpa"
      }
      
      if LCPPDFs.canOpenBook(book) {
        return "zip"
      }
    }
#endif
    return "epub"
  }
}
