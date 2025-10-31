//
//  TPPMyBookDownloadCenter.swift
//  Palace
//
//  Created by Maurice Carrier on 6/13/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import UIKit
import PalaceAudiobookToolkit
import Combine

#if FEATURE_OVERDRIVE
import OverdriveProcessor
#endif

@objc class MyBooksDownloadCenter: NSObject, URLSessionDelegate {
  typealias DisplayStrings = Strings.MyDownloadCenter
  
  @objc static let shared = MyBooksDownloadCenter()
  
  private var userAccount: TPPUserAccount
  private var reauthenticator: Reauthenticator
  private var bookRegistry: TPPBookRegistryProvider
  
  private var bookIdentifierOfBookToRemove: String?
  private var broadcastScheduled = false
  private var session: URLSession!
  
  // Thread-safe actor-based dictionaries
  private let bookIdentifierToDownloadInfo = SafeDictionary<String, MyBooksDownloadInfo>()
  private var bookIdentifierToDownloadProgress: [String: Progress] = [:]
  private let bookIdentifierToDownloadTask = SafeDictionary<String, URLSessionDownloadTask>()
  private let taskIdentifierToBook = SafeDictionary<Int, TPPBook>()
  private var taskIdentifierToRedirectAttempts: [Int: Int] = [:]
  
  // Serial execution for download operations (replaces downloadQueue)
  private let downloadExecutor = SerialExecutor()
  
  let downloadProgressPublisher = PassthroughSubject<(String, Double), Never>()
  private var maxConcurrentDownloads: Int = 5 
  private var pendingStartQueue: [TPPBook] = []
  
  init(
    userAccount: TPPUserAccount = TPPUserAccount.sharedAccount(),
    reauthenticator: Reauthenticator = TPPReauthenticator(),
    bookRegistry: TPPBookRegistryProvider = TPPBookRegistry.shared
  ) {
    self.userAccount = userAccount
    self.bookRegistry = bookRegistry
    self.reauthenticator = reauthenticator
    
    super.init()
    
#if FEATURE_DRM_CONNECTOR
    if !(AdobeCertificate.defaultCertificate?.hasExpired ?? true)
    {
      NYPLADEPT.sharedInstance().delegate = self
    }
#else
    NSLog("Cannot import ADEPT")
#endif
    
    let backgroundIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".downloadCenterBackgroundIdentifier"
    let configuration = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
    configuration.isDiscretionary = false
    configuration.waitsForConnectivity = false
    if #available(iOS 13.0, *) {
      configuration.allowsConstrainedNetworkAccess = true
    }
    self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    
    // Setup intelligent download management
    setupNetworkMonitoring()
  }
  
  func startBorrow(for book: TPPBook, attemptDownload shouldAttemptDownload: Bool, borrowCompletion: (() -> Void)? = nil) {
    bookRegistry.setProcessing(true, for: book.identifier)
    
    TPPOPDSFeed.withURL((book.defaultAcquisition)?.hrefURL, shouldResetCache: true, useTokenIfAvailable: true) { [weak self] feed, error in
      self?.bookRegistry.setProcessing(false, for: book.identifier)
      
      if let feed = feed,
         let borrowedEntry = feed.entries.first as? TPPOPDSEntry,
         let borrowedBook = TPPBook(entry: borrowedEntry) {

        let location = self?.bookRegistry.location(forIdentifier: borrowedBook.identifier)

        // Determine correct registry state based on availability
        var newState: TPPBookState = .downloadNeeded
        borrowedBook.defaultAcquisition?.availability.matchUnavailable(
          { _ in newState = .holding },
          limited: { _ in newState = .downloadNeeded },
          unlimited: { _ in newState = .downloadNeeded },
          reserved: { _ in newState = .holding },
          ready: { _ in newState = .downloadNeeded }
        )

        self?.bookRegistry.addBook(
          borrowedBook,
          location: location,
          state: newState,
          fulfillmentId: nil,
          readiumBookmarks: nil,
          genericBookmarks: nil
        )

        // Emit explicit state update so SwiftUI lists refresh immediately
        self?.bookRegistry.setState(newState, for: borrowedBook.identifier)

        if shouldAttemptDownload && newState == .downloadNeeded {
          self?.startDownloadIfAvailable(book: borrowedBook)
        }

      } else {
        self?.process(error: error as? [String: Any], for: book)
      }
      
      runOnMainAsync {
        borrowCompletion?()
      }
    }
  }
  
  private func startDownloadIfAvailable(book: TPPBook) {
    let downloadAction = { [weak self] in
      self?.startDownload(for: book)
    }
    
    book.defaultAcquisition?.availability.matchUnavailable(
      nil,
      limited: { _ in downloadAction() },
      unlimited: { _ in downloadAction() },
      reserved: nil,
      ready: { _ in downloadAction() })
  }
  
  private var hasAttemptedAuthentication = false
  private var isRequestingCredentials = false
  
  private func process(error: [String: Any]?, for book: TPPBook) {
    guard let errorType = error?["type"] as? String else {
      showGenericBorrowFailedAlert(for: book)
      return
    }
    
    let alertTitle = DisplayStrings.borrowFailed
    
    switch errorType {
    case TPPProblemDocument.TypeLoanAlreadyExists:
      let alertMessage = DisplayStrings.loanAlreadyExistsAlertMessage
      let alert = TPPAlertUtils.alert(title: alertTitle, message: alertMessage)
      runOnMainAsync {
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
      }
      
    case TPPProblemDocument.TypeInvalidCredentials:
      guard !hasAttemptedAuthentication else {
        showAlert(for: book, with: error, alertTitle: alertTitle)
        return
      }
      
      guard !isRequestingCredentials else {
        NSLog("Already requesting credentials, skipping re-authentication for: \(book.title)")
        return
      }
      
      hasAttemptedAuthentication = true
      isRequestingCredentials = true
      
      // Reset flag after a delay to handle cancellation cases where completion isn't called
      runOnMainAfter(seconds: 2.0) { [weak self] in
        self?.isRequestingCredentials = false
      }
      
      NSLog("Invalid credentials problem when borrowing a book, present sign in VC")
      
      reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: false) { [weak self] in
        guard let self = self else {
          NSLog("❌ Self is nil after authentication, skipping startDownload")
          return
        }
        
        self.isRequestingCredentials = false
        
        // Only retry if user now has credentials to prevent infinite recursion
        if self.userAccount.hasCredentials() {
          runOnMainAsync {
            self.startDownload(for: book)
          }
        } else {
          NSLog("Authentication completed but no credentials present, user may have cancelled")
        }
      }
      
    default:
      showAlert(for: book, with: error, alertTitle: alertTitle)
    }
  }
  
  private func showAlert(for book: TPPBook, with error: [String: Any]?, alertTitle: String) {
    let alertMessage = String(format: DisplayStrings.borrowFailedMessage, book.title)
    let alert = TPPAlertUtils.alert(title: alertTitle, message: alertMessage)
    
    if let error = error {
      TPPAlertUtils.setProblemDocument(controller: alert, document: TPPProblemDocument.fromDictionary(error), append: false)
    }
    
    runOnMainAsync {
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
    }
  }
  
  private func showGenericBorrowFailedAlert(for book: TPPBook) {
    let formattedMessage = String(format: DisplayStrings.borrowFailedMessage, book.title)
    let alert = TPPAlertUtils.alert(title: DisplayStrings.borrowFailed, message: formattedMessage)
    runOnMainAsync {
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
    }
  }
  
  @objc func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest? = nil) {
    var state = bookRegistry.state(for: book.identifier)
    let location = bookRegistry.location(forIdentifier: book.identifier)
    // If this account requires auth and there are no stored credentials, prompt for sign-in now.
    let loginRequired = (userAccount.authDefinition?.needsAuth ?? false) && !userAccount.hasCredentials()
    
    switch state {
    case .unregistered:
      state = processUnregisteredState(
        for: book,
        location: location,
        loginRequired: loginRequired
      )
    case .downloading:
      return
    case .downloadFailed, .downloadNeeded, .holding, .SAMLStarted:
      break
    case .downloadSuccessful, .used, .unsupported, .returning:
      NSLog("Ignoring nonsensical download request.")
      return
    }
    
    if activeDownloadCount() >= maxConcurrentDownloads {
      enqueuePending(book)
      return
    }

    if loginRequired {
      requestCredentialsAndStartDownload(for: book)
    } else {
      processDownloadWithCredentials(for: book, withState: state, andRequest: initedRequest)
    }
  }
  
  private func processUnregisteredState(for book: TPPBook, location: TPPBookLocation?, loginRequired: Bool?) -> TPPBookState {
    if (book.defaultAcquisitionIfBorrow == nil && (book.defaultAcquisitionIfOpenAccess != nil || !(loginRequired ?? false))) {
      bookRegistry.addBook(book, location: location, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
      return .downloadNeeded
    }
    return .unregistered
  }
  
  private func requestCredentialsAndStartDownload(for book: TPPBook) {
    guard !isRequestingCredentials else {
      NSLog("Already requesting credentials for authentication, skipping duplicate request for: \(book.title)")
      return
    }
    
    isRequestingCredentials = true
    
    // Reset flag after a delay to handle cancellation cases where completion isn't called
    runOnMainAfter(seconds: 2.0) { [weak self] in
      self?.isRequestingCredentials = false
    }
    
#if FEATURE_DRM_CONNECTOR
    if AdobeCertificate.defaultCertificate?.hasExpired ?? false {
      isRequestingCredentials = false
      // ADEPT crashes the app with expired certificate.
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: TPPAlertUtils.expiredAdobeDRMAlert(), viewController: nil, animated: true, completion: nil)
    } else {
      TPPAccountSignInViewController.requestCredentials { [weak self] in
        guard let self = self else { return }
        self.isRequestingCredentials = false
        
        // Only retry download if user now has credentials
        // This prevents infinite recursion when refreshAuthIfNeeded returns false immediately
        if self.userAccount.hasCredentials() {
          self.startDownload(for: book)
        } else {
          NSLog("Sign-in completed but no credentials present, user may have cancelled")
        }
      }
    }
#else
    TPPAccountSignInViewController.requestCredentials { [weak self] in
      guard let self = self else { return }
      self.isRequestingCredentials = false
      
      // Only retry download if user now has credentials
      // This prevents infinite recursion when refreshAuthIfNeeded returns false immediately
      if self.userAccount.hasCredentials() {
        self.startDownload(for: book)
      } else {
        NSLog("Sign-in completed but no credentials present, user may have cancelled")
      }
    }
#endif
  }
  
  private func processDownloadWithCredentials(
    for book: TPPBook,
    withState state: TPPBookState,
    andRequest initedRequest: URLRequest?
  ) {
    if state == .unregistered || state == .holding {
      startBorrow(for: book, attemptDownload: true, borrowCompletion: nil)
    } else {
#if FEATURE_OVERDRIVE
      if book.distributor == OverdriveDistributorKey && book.defaultBookContentType == .audiobook {
        processOverdriveDownload(for: book, withState: state)
        return
      }
#endif
      processRegularDownload(for: book, withState: state, andRequest: initedRequest)
    }
  }
  
#if FEATURE_OVERDRIVE
  private func processOverdriveDownload(for book: TPPBook, withState state: TPPBookState) {
    guard let url = book.defaultAcquisition?.hrefURL else { return }
    
    let completion: ([AnyHashable: Any]?, Error?) -> Void = { [weak self] responseHeaders, error in
      self?.handleOverdriveResponse(for: book, url: url, withState: state, responseHeaders: responseHeaders, error: error)
    }
    
    if let token = userAccount.authToken {
      OverdriveAPIExecutor.shared.fulfillBook(urlString: url.absoluteString, authType: .token(token), completion: completion)
    } else if let username = userAccount.username, let pin = userAccount.PIN {
      OverdriveAPIExecutor.shared.fulfillBook(urlString: url.absoluteString, authType: .basic(username: username, pin: pin), completion: completion)
    }
  }
#endif
  
#if FEATURE_OVERDRIVE
  private func handleOverdriveResponse(
    for book: TPPBook,
    url: URL?,
    withState state: TPPBookState,
    responseHeaders: [AnyHashable: Any]?,
    error: Error?
  ) {
    let summaryWrongHeaders = "Overdrive audiobook fulfillment: wrong headers"
    let nA = "N/A"
    let responseHeadersKey = "responseHeaders"
    let acquisitionURLKey = "acquisitionURL"
    let bookKey = "book"
    let bookRegistryStateKey = "bookRegistryState"
    
    if let error = error {
      let summary = "Overdrive audiobook fulfillment error"
      
      TPPErrorLogger.logError(error, summary: summary, metadata: [
        responseHeadersKey: responseHeaders ?? nA,
        acquisitionURLKey: url?.absoluteString ?? nA,
        bookKey: book.loggableDictionary,
        bookRegistryStateKey: TPPBookStateHelper.stringValue(from: state)
      ])
      self.failDownloadWithAlert(for: book)
      return
    }
    
    let normalizedHeaders = responseHeaders?.mapKeys { String(describing: $0).lowercased() }
    let scopeKey = "x-overdrive-scope"
    let patronAuthorizationKey = "x-overdrive-patron-authorization"
    let locationKey = "location"
    
    guard let scope = normalizedHeaders?[scopeKey] as? String,
          let patronAuthorization = normalizedHeaders?[patronAuthorizationKey] as? String,
          let requestURLString = normalizedHeaders?[locationKey] as? String,
          let request = OverdriveAPIExecutor.shared.getManifestRequest(urlString: requestURLString, token: patronAuthorization, scope: scope)
    else {
      TPPErrorLogger.logError(withCode: .overdriveFulfillResponseParseFail, summary: summaryWrongHeaders, metadata: [
        responseHeadersKey: responseHeaders ?? nA,
        acquisitionURLKey: url?.absoluteString ?? nA,
        bookKey: book.loggableDictionary,
        bookRegistryStateKey: TPPBookStateHelper.stringValue(from: state)
      ])
      self.failDownloadWithAlert(for: book)
      return
    }
    
    self.addDownloadTask(with: request, book: book)
  }
#endif
  
  private func processRegularDownload(for book: TPPBook, withState state: TPPBookState, andRequest initedRequest: URLRequest?) {
    if book.isExpired && book.defaultAcquisitionIfBorrow != nil {
      Log.warn(#file, "Book \(book.identifier) is expired. Attempting to re-borrow before download.")
      bookRegistry.setState(.unregistered, for: book.identifier)
      startBorrow(for: book, attemptDownload: true, borrowCompletion: nil)
      return
    }
    
    if state == .downloadNeeded && book.defaultAcquisitionIfBorrow != nil {
      Log.info(#file, "Book \(book.identifier) has borrow acquisition but is in downloadNeeded state. Refreshing loan status.")
      bookRegistry.setState(.unregistered, for: book.identifier)
      startBorrow(for: book, attemptDownload: true, borrowCompletion: nil)
      return
    }
    
    let request: URLRequest
    if let initedRequest = initedRequest {
      request = initedRequest
    } else if let url = book.defaultAcquisition?.hrefURL {
      request = TPPNetworkExecutor.bearerAuthorized(request: URLRequest(url: url, applyingCustomUserAgent: true))
    } else {
      logInvalidURLRequest(for: book, withState: state, url: nil, request: nil)
      return
    }
    
    guard let _ = request.url else {
      logInvalidURLRequest(for: book, withState: state, url: book.defaultAcquisition?.hrefURL, request: request)
      return
    }
    
    // Ensure we are within disk budget before proceeding
    MemoryPressureMonitor.shared.reclaimDiskSpaceIfNeeded(minimumFreeMegabytes: 512)
    enforceContentDiskBudgetIfNeeded(adding: 0)

    if let cookies = userAccount.cookies, state != .SAMLStarted {
      handleSAMLStartedState(for: book, withRequest: request, cookies: cookies)
    } else {
      clearAndSetCookies()
      addDownloadTask(with: request, book: book)
    }
  }
  
  private func logInvalidURLRequest(for book: TPPBook, withState state: TPPBookState, url: URL?, request: URLRequest?) {
    bookRegistry.setState(.SAMLStarted, for: book.identifier)
    guard let someCookies = self.userAccount.cookies, var mutableRequest = request else { return }
    
    runOnMainAsync { [weak self] in
      guard let self = self else { return }
      
      mutableRequest.cachePolicy = .reloadIgnoringCacheData
      
      let loginCancelHandler: () -> Void = { [weak self] in
        self?.bookRegistry.setState(.downloadNeeded, for: book.identifier)
        self?.cancelDownload(for: book.identifier)
      }
      
      let bookFoundHandler: (_ request: URLRequest?, _ cookies: [HTTPCookie]) -> Void = { [weak self] request, cookies in
        self?.userAccount.setCookies(cookies)
        self?.startDownload(for: book, withRequest: mutableRequest)
      }
      
      let problemFoundHandler: (_ problemDocument: TPPProblemDocument?) -> Void = { [weak self] problemDocument in
        guard let self = self else { return }
        self.bookRegistry.setState(.downloadNeeded, for: book.identifier)
        
        guard !self.isRequestingCredentials else {
          NSLog("Already requesting credentials, skipping re-authentication in problemFoundHandler for: \(book.title)")
          return
        }
        
        self.isRequestingCredentials = true
        
        // Reset flag after a delay to handle cancellation cases where completion isn't called
        runOnMainAfter(seconds: 2.0) { [weak self] in
          self?.isRequestingCredentials = false
        }
        
        self.reauthenticator.authenticateIfNeeded(self.userAccount, usingExistingCredentials: false) { [weak self] in
          guard let self = self else { return }
          self.isRequestingCredentials = false
          
          // Only retry if user now has credentials to prevent infinite recursion
          if self.userAccount.hasCredentials() {
            self.startDownload(for: book)
          } else {
            NSLog("Authentication completed but no credentials present, user may have cancelled")
          }
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
  
  private func handleSAMLStartedState(for book: TPPBook, withRequest request: URLRequest, cookies: [HTTPCookie]) {
    bookRegistry.setState(.SAMLStarted, for: book.identifier)
    
    runOnMainAsync { [weak self] in
      var mutableRequest = request
      mutableRequest.cachePolicy = .reloadIgnoringCacheData
      
      let model = TPPCookiesWebViewModel(cookies: cookies, request: mutableRequest, loginCompletionHandler: nil, loginCancelHandler: {
        self?.handleLoginCancellation(for: book)
      }, bookFoundHandler: { request, cookies in
        self?.handleBookFound(for: book, withRequest: request, cookies: cookies)
      }, problemFoundHandler: { problemDocument in
        self?.handleProblem(for: book, problemDocument: problemDocument)
      }, autoPresentIfNeeded: true)
      
      let cookiesVC = TPPCookiesWebViewController(model: model)
      cookiesVC.loadViewIfNeeded()
    }
  }
  
  private func handleLoginCancellation(for book: TPPBook) {
    bookRegistry.setState(.downloadNeeded, for: book.identifier)
    cancelDownload(for: book.identifier)
  }
  
  private func handleBookFound(for book: TPPBook, withRequest request: URLRequest?, cookies: [HTTPCookie]) {
    userAccount.setCookies(cookies)
    if let request = request {
      startDownload(for: book, withRequest: request)
    }
  }
  
  private func handleProblem(for book: TPPBook, problemDocument: TPPProblemDocument?) {
    bookRegistry.setState(.downloadNeeded, for: book.identifier)
    
    guard !isRequestingCredentials else {
      NSLog("Already requesting credentials, skipping re-authentication in handleProblem for: \(book.title)")
      return
    }
    
    isRequestingCredentials = true
    
    // Reset flag after a delay to handle cancellation cases where completion isn't called
    runOnMainAfter(seconds: 2.0) { [weak self] in
      self?.isRequestingCredentials = false
    }
    
    reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: false) { [weak self] in
      guard let self = self else { return }
      self.isRequestingCredentials = false
      
      // Only retry if user now has credentials to prevent infinite recursion
      if self.userAccount.hasCredentials() {
        self.startDownload(for: book)
      } else {
        NSLog("Authentication completed but no credentials present, user may have cancelled")
      }
    }
  }
  
  private func clearAndSetCookies() {
    let cookieStorage = self.session.configuration.httpCookieStorage
    cookieStorage?.cookies?.forEach { cookie in
      cookieStorage?.deleteCookie(cookie)
    }
    self.userAccount.cookies?.forEach { cookie in
      cookieStorage?.setCookie(cookie)
    }
  }
  
  @objc func cancelDownload(for identifier: String) {
    guard let info = downloadInfo(forBookIdentifier: identifier) else {
      let state = bookRegistry.state(for: identifier)
      if state != .downloadFailed {
        NSLog("Ignoring nonsensical cancellation request.")
        return
      }
      
      bookRegistry.setState(.downloadNeeded, for: identifier)
      return
    }
    
#if FEATURE_DRM_CONNECTOR
    if info.rightsManagement == .adobe {
      NYPLADEPT.sharedInstance().cancelFulfillment(withTag: identifier)
      return
    }
#endif
    
    info.downloadTask.cancel { [weak self] resumeData in
      self?.bookRegistry.setState(.downloadNeeded, for: identifier)
      self?.broadcastUpdate()
    }
  }
}

extension MyBooksDownloadCenter {
  func deleteLocalContent(for identifier: String, account: String? = nil) {
    let current_account: String? = account ?? AccountsManager.shared.currentAccountId
    guard let book = bookRegistry.book(forIdentifier: identifier),
          let bookURL = fileUrl(for: identifier, account: current_account) else {
      Log.warn(#file, "Could not find book to delete local content \(identifier)")
      return
    }
    
    do {
      switch book.defaultBookContentType {
      case .epub, .pdf:
        if FileManager.default.fileExists(atPath: bookURL.path) {
          try FileManager.default.removeItem(at: bookURL)
        } else {
          Log.info(#file, "Content file already missing (nothing to delete): \(bookURL.lastPathComponent)")
        }
#if LCP
        if book.defaultBookContentType == .pdf {
          try LCPPDFs.deletePdfContent(url: bookURL)
        }
#endif
      case .audiobook:
        try deleteLocalAudiobookContent(forAudiobook: book, at: bookURL)
      case .unsupported:
        Log.warn(#file, "Unsupported content type for deletion.")
      }
    } catch {
      Log.error(#file, "Failed to remove local content for book with identifier \(identifier): \(error.localizedDescription)")
    }
  }
  
  private func deleteLocalAudiobookContent(forAudiobook book: TPPBook, at bookURL: URL) throws {
#if LCP
    let isLcpAudiobook = LCPAudiobooks.canOpenBook(book)
#else
    let isLcpAudiobook = false
#endif
    
    // LCP Audiobooks are a single binary file, without an easily loaded manifest.
    // So they skip this logic that deleted the local audio files, used by other
    // audiobook types.
    // TODO: Update LCP so we don't have to special case it here.
    if (!isLcpAudiobook) {
      let manifestData = try Data(contentsOf: bookURL)
      let manifest = try Manifest.customDecoder().decode(Manifest.self, from: manifestData)
      AudiobookFactory.audiobookClass(for: manifest).deleteLocalContent(manifest: manifest, bookIdentifier: book.identifier)
    }
    
    if FileManager.default.fileExists(atPath: bookURL.path) {
      try FileManager.default.removeItem(at: bookURL)
    } else {
      Log.info(#file, "Audiobook content already missing (nothing to delete): \(bookURL.lastPathComponent)")
    }
    Log.info(#file, "Successfully deleted audiobook manifest & content \(book.identifier)")
  }
  
  @objc func returnBook(withIdentifier identifier: String, completion: (() -> Void)? = nil) {
    guard let book = bookRegistry.book(forIdentifier: identifier) else {
      completion?()
      return
    }
    
    let state = bookRegistry.state(for: identifier)
    let downloaded = (state == .downloadSuccessful) || (state == .used)
    
    // Process Adobe Return
#if FEATURE_DRM_CONNECTOR
    if let fulfillmentId = bookRegistry.fulfillmentId(forIdentifier: identifier),
       userAccount.authDefinition?.needsAuth == true {
      NSLog("Return attempt for book. userID: %@", userAccount.userID ?? "")
      NYPLADEPT.sharedInstance().returnLoan(fulfillmentId,
                                            userID: userAccount.userID,
                                            deviceID: userAccount.deviceID) { success, error in
        if !success {
          NSLog("Failed to return loan via NYPLAdept.")
        }
      }
    }
#endif
    
    if book.revokeURL == nil {
      if downloaded {
        deleteLocalContent(for: identifier)
        purgeAllAudiobookCaches(force: true)
      }

      bookRegistry.setState(.unregistered, for: identifier)
      bookRegistry.removeBook(forIdentifier: identifier)
      Task {
        try? await TPPBookRegistry.shared.syncAsync()
        runOnMainAsync { completion?() }
      }
    } else {
      bookRegistry.setProcessing(true, for: book.identifier)
      
      TPPOPDSFeed.withURL(book.revokeURL, shouldResetCache: false, useTokenIfAvailable: true) { feed, error in
        self.bookRegistry.setProcessing(false, for: book.identifier)
        
        if let feed = feed, feed.entries.count == 1, let entry = feed.entries[0] as? TPPOPDSEntry {
          if downloaded {
            self.deleteLocalContent(for: identifier)
            self.purgeAllAudiobookCaches(force: true)
          }
          if let returnedBook = TPPBook(entry: entry) {
            self.bookRegistry.updateAndRemoveBook(returnedBook)
            self.bookRegistry.setState(.unregistered, for: identifier)
            Task {
              try? await TPPBookRegistry.shared.syncAsync()
              runOnMainAsync { completion?() }
            }
          } else {
            NSLog("Failed to create book from entry. Book not removed from registry.")
            Task {
              try? await TPPBookRegistry.shared.syncAsync()
              runOnMainAsync { completion?() }
            }
          }
        } else {
          if let errorType = error?["type"] as? String {
            if errorType == TPPProblemDocument.TypeNoActiveLoan {
              if downloaded {
                self.deleteLocalContent(for: identifier)
                self.purgeAllAudiobookCaches(force: true)
              }
              self.bookRegistry.setState(.unregistered, for: identifier)
              self.bookRegistry.removeBook(forIdentifier: identifier)
              Task {
                try? await TPPBookRegistry.shared.syncAsync()
                runOnMainAsync { completion?() }
              }
            } else if errorType == TPPProblemDocument.TypeInvalidCredentials {
              NSLog("Invalid credentials problem when returning a book, present sign in VC")
              self.reauthenticator.authenticateIfNeeded(self.userAccount, usingExistingCredentials: false) { [weak self] in
                self?.returnBook(withIdentifier: identifier, completion: completion)
              }
            }
          } else {
            runOnMainAsync {
              let formattedMessage = String(format: NSLocalizedString("The return of %@ could not be completed.", comment: ""), book.title)
              let alert = TPPAlertUtils.alert(title: "ReturnFailed", message: formattedMessage)
              if let error = error as? Decoder, let document = try? TPPProblemDocument(from: error) {
                TPPAlertUtils.setProblemDocument(controller: alert, document: document, append: true)
              }
              runOnMainAsync {
                TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
              }
            }
            runOnMainAsync { completion?() }
          }
        }
      }
    }
  }
}

extension MyBooksDownloadCenter: URLSessionDownloadDelegate {
  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didResumeAtOffset fileOffset: Int64,
    expectedTotalBytes: Int64
  ) {
    NSLog("Ignoring unexpected resumption.")
  }
  
  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let key = downloadTask.taskIdentifier
    
    // Bridge to async for actor access
    Task {
      guard let book = await taskIdentifierToBook.get(key) else {
        return
      }
      
      await handleDownloadProgress(
        for: book,
        task: downloadTask,
        bytesWritten: bytesWritten,
        totalBytesWritten: totalBytesWritten,
        totalBytesExpectedToWrite: totalBytesExpectedToWrite
      )
    }
  }
  
  private func handleDownloadProgress(
    for book: TPPBook,
    task: URLSessionDownloadTask,
    bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) async {
    
    if bytesWritten == totalBytesWritten {
      guard let mimeType = task.response?.mimeType else {
        Log.error(#file, "No MIME type in response for book: \(book.identifier)")
        return
      }
      
      Log.info(#file, "Download MIME type detected for \(book.identifier): \(mimeType)")
      
      switch mimeType {
      case ContentTypeAdobeAdept:
        if let info = await downloadInfoAsync(forBookIdentifier: book.identifier)?.withRightsManagement(.adobe) {
          await bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        }
      case ContentTypeReadiumLCP:
        if let info = await downloadInfoAsync(forBookIdentifier: book.identifier)?.withRightsManagement(.lcp) {
          await bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        }
      case ContentTypeEpubZip:
        if let info = await downloadInfoAsync(forBookIdentifier: book.identifier)?.withRightsManagement(.none) {
          await bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        }
      case ContentTypeBearerToken:
        if let info = await downloadInfoAsync(forBookIdentifier: book.identifier)?.withRightsManagement(.simplifiedBearerTokenJSON) {
          await bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        }
#if FEATURE_OVERDRIVE
      case "application/json":
        if let info = await downloadInfoAsync(forBookIdentifier: book.identifier)?.withRightsManagement(.overdriveManifestJSON) {
          await bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        }
#endif
      default:
        if TPPOPDSAcquisitionPath.supportedTypes().contains(mimeType) {
          NSLog("Presuming no DRM for unrecognized MIME type \"\(mimeType)\".")
          if let info = await downloadInfoAsync(forBookIdentifier: book.identifier)?.withRightsManagement(.none) {
            await bookIdentifierToDownloadInfo.set(book.identifier, value: info)
          }
        } else if TPPUserAccount.sharedAccount().isTokenRefreshRequired() {
          NSLog("Authentication might be needed after all")
          TPPNetworkExecutor.shared.refreshTokenAndResume(task: task)
          return
        }
      }
    }
    
    let rightsManagement = await downloadInfoAsync(forBookIdentifier: book.identifier)?.rightsManagement ?? .none
    if rightsManagement != .adobe && rightsManagement != .simplifiedBearerTokenJSON && rightsManagement != .overdriveManifestJSON {
      if totalBytesExpectedToWrite > 0 {
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if let info = await downloadInfoAsync(forBookIdentifier: book.identifier)?.withDownloadProgress(progress) {
          await bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        }
        // Fire both notification and publisher so SwiftUI cells and BookDetail can update
        await MainActor.run {
          downloadProgressPublisher.send((book.identifier, progress))
        }
        broadcastUpdate()
      }
    }
  }
  
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // CRITICAL: Must move file synchronously before delegate returns
    // URLSession will delete the temp file as soon as this method completes
    
    // Move file to a safe location first
    let tempDir = FileManager.default.temporaryDirectory
    let safeLocation = tempDir.appendingPathComponent(UUID().uuidString + "_" + location.lastPathComponent)
    
    do {
      try FileManager.default.moveItem(at: location, to: safeLocation)
    } catch {
      Log.error(#file, "Failed to preserve download file: \(error.localizedDescription)")
      return
    }
    
    // Now process async with preserved file
    Task {
      await handleDownloadCompletion(session: session, task: downloadTask, location: safeLocation)
    }
  }
  
  private func handleDownloadCompletion(session: URLSession, task: URLSessionDownloadTask, location: URL) async {
    guard let book = await taskIdentifierToBook.get(task.taskIdentifier) else {
      return
    }
    
    taskIdentifierToRedirectAttempts.removeValue(forKey: task.taskIdentifier)
    
    var failureRequiringAlert = false
    var failureError = task.error
    var problemDoc: TPPProblemDocument?
    let rights = await downloadInfoAsync(forBookIdentifier: book.identifier)?.rightsManagement ?? .unknown
    
    Log.info(#file, "Download completed for \(book.identifier) with rights: \(rights)")
    
    if let response = task.response, response.isProblemDocument() {
      do {
        let problemDocData = try Data(contentsOf: location)
        problemDoc = try TPPProblemDocument.fromData(problemDocData)
      } catch let error {
        TPPErrorLogger.logProblemDocumentParseError(error as NSError, problemDocumentData: nil, url: location, summary: "Error parsing problem doc downloading \(String(describing: book.distributor)) book", metadata: ["book": book.loggableShortString])
      }
      
      try? FileManager.default.removeItem(at: location)
      failureRequiringAlert = true
    }
    
    if !book.canCompleteDownload(withContentType: task.response?.mimeType ?? "") {
      try? FileManager.default.removeItem(at: location)
      failureRequiringAlert = true
    }
    
    if failureRequiringAlert {
      logBookDownloadFailure(book, reason: "Download Error", downloadTask: task, metadata: ["problemDocument": problemDoc?.dictionaryValue ?? "N/A"])
    } else {
      TPPProblemDocumentCacheManager.sharedInstance().clearCachedDoc(book.identifier)
      
      switch rights {
      case .unknown:
        Log.error(#file, "❌ Rights management is unknown for book: \(book.identifier) - LCP fulfillment will NOT be called")
        logBookDownloadFailure(book, reason: "Unknown rights management", downloadTask: task, metadata: nil)
        failureRequiringAlert = true
      case .adobe:
#if FEATURE_DRM_CONNECTOR
        if let acsmData = try? Data(contentsOf: location),
           let acsmString = String(data: acsmData, encoding: .utf8),
           acsmString.contains(">application/pdf</dc:format>") {
          let msg = NSLocalizedString("\(book.title) is an Adobe PDF, which is not supported.", comment: "")
          failureError = NSError(domain: TPPErrorLogger.clientDomain, code: TPPErrorCode.ignore.rawValue, userInfo: [NSLocalizedDescriptionKey: msg])
          logBookDownloadFailure(book, reason: "Received PDF for AdobeDRM rights", downloadTask: task, metadata: nil)
          failureRequiringAlert = true
        } else if let acsmData = try? Data(contentsOf: location) {
          NSLog("Download finished. Fulfilling with userID: \(userAccount.userID ?? "")")
          NYPLADEPT.sharedInstance().fulfill(withACSMData: acsmData, tag: book.identifier, userID: userAccount.userID, deviceID: userAccount.deviceID)
        }
#endif
      case .lcp:
        fulfillLCPLicense(fileUrl: location, forBook: book, downloadTask: task)
      case .simplifiedBearerTokenJSON:
        if let data = try? Data(contentsOf: location) {
          if let dictionary = TPPJSONObjectFromData(data) as? [String: Any],
             let simplifiedBearerToken = MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: dictionary) {
            var mutableRequest = URLRequest(url: simplifiedBearerToken.location, applyingCustomUserAgent: true)
            mutableRequest.setValue("Bearer \(simplifiedBearerToken.accessToken)", forHTTPHeaderField: "Authorization")
            let newTask = session.downloadTask(with: mutableRequest as URLRequest)
            let downloadInfo = MyBooksDownloadInfo(
              downloadProgress: 0.0,
              downloadTask: newTask,
              rightsManagement: .none,
              bearerToken: simplifiedBearerToken
            )
            await bookIdentifierToDownloadInfo.set(book.identifier, value: downloadInfo)
            book.bearerToken = simplifiedBearerToken.accessToken
            await taskIdentifierToBook.set(newTask.taskIdentifier, value: book)
            newTask.resume()
          } else {
            logBookDownloadFailure(book, reason: "No Simplified Bearer Token in deserialized data", downloadTask: task, metadata: nil)
            failDownloadWithAlert(for: book)
          }
        } else {
          logBookDownloadFailure(book, reason: "No Simplified Bearer Token data available on disk", downloadTask: task, metadata: nil)
          failDownloadWithAlert(for: book)
        }
      case .overdriveManifestJSON:
        failureRequiringAlert = !replaceBook(book, withFileAtURL: location, forDownloadTask: task)
      case .none:
        failureRequiringAlert = !moveFile(at: location, toDestinationForBook: book, forDownloadTask: task)
      }
    }
    
    if failureRequiringAlert {
      runOnMainAsync {
        let hasCredentials = self.userAccount.hasCredentials()
        let loginRequired = self.userAccount.authDefinition?.needsAuth ?? false
        if task.response?.indicatesAuthenticationNeedsRefresh(with: problemDoc) == true || (!hasCredentials && loginRequired) {
          self.reauthenticator.authenticateIfNeeded(
            self.userAccount,
            usingExistingCredentials: hasCredentials,
            authenticationCompletion: nil
          )
        }
        
        // Check if the error is "No active loan" - attempt to re-borrow
        if let problemDoc = problemDoc, problemDoc.type == TPPProblemDocument.TypeNoActiveLoan {
          Log.info(#file, "Download failed due to no active loan. Attempting to borrow book: \(book.identifier)")
          
          // Update state to unregistered so borrow logic will work
          self.bookRegistry.setState(.unregistered, for: book.identifier)
          
          // Try to borrow the book (which will auto-download if successful)
          self.startBorrow(for: book, attemptDownload: true) { [weak self] in
            // If borrow completed, check if download started
            let newState = self?.bookRegistry.state(for: book.identifier)
            if newState != .downloading && newState != .downloadSuccessful {
              // Borrow didn't result in download, show the error
              self?.alertForProblemDocument(problemDoc, error: failureError, book: book)
            }
          }
        } else {
          // For other errors, show alert immediately
          self.alertForProblemDocument(problemDoc, error: failureError, book: book)
        }
      }
      bookRegistry.setState(.downloadFailed, for: book.identifier)
    }
    
    broadcastUpdate()
    // Attempt to start next pending downloads
    schedulePendingStartsIfPossible()
  }
  
  /// Async-first download info accessor
  func downloadInfoAsync(forBookIdentifier bookIdentifier: String) async -> MyBooksDownloadInfo? {
    guard let downloadInfo = await bookIdentifierToDownloadInfo.get(bookIdentifier) else {
      return nil
    }
    
    if downloadInfo is MyBooksDownloadInfo {
      return downloadInfo
    } else {
      Log.error(#file, "Corrupted download info detected for book \(bookIdentifier), removing entry")
      await bookIdentifierToDownloadInfo.remove(bookIdentifier)
      return nil
    }
  }
  
  /// Synchronous wrapper for legacy compatibility (delegates, @objc methods)
  /// WARNING: This can cause priority inversion - prefer async APIs where possible
  @objc func downloadInfo(forBookIdentifier bookIdentifier: String) -> MyBooksDownloadInfo? {
    // Use RunLoop spinning instead of semaphore to avoid priority inversion
    var result: MyBooksDownloadInfo?
    var isComplete = false
    
    Task {
      result = await self.downloadInfoAsync(forBookIdentifier: bookIdentifier)
      isComplete = true
    }
    
    // Spin run loop instead of blocking with semaphore (avoids priority inversion)
    let timeoutDate = Date().addingTimeInterval(2.0) // Shorter timeout for UI responsiveness
    while !isComplete && Date() < timeoutDate {
      RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    
    if !isComplete {
      Log.warn(#file, "⚠️ Actor access slow for downloadInfo - returning nil for UI responsiveness")
      return nil
    }
    
    return result
  }
  
  func broadcastUpdate() {
    runOnMainAfter(seconds: 0.2) {
      self.broadcastUpdateNow()
    }
  }
  
  private func broadcastUpdateNow() {
    NotificationCenter.default.post(
      name: Notification.Name.TPPMyBooksDownloadCenterDidChange,
      object: self
    )
    // Emit explicit progress updates for all active downloads using our stored info
    Task {
      let allKeys = await bookIdentifierToDownloadInfo.keys()
      for bookID in allKeys {
        if let info = await bookIdentifierToDownloadInfo.get(bookID) {
          await MainActor.run {
            downloadProgressPublisher.send((bookID, Double(info.downloadProgress)))
          }
        }
      }
    }
  }
}

extension MyBooksDownloadCenter: URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
      let handler = TPPBasicAuth(credentialsProvider: userAccount)
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
      
      var mutableRequest = URLRequest(url: request.url!, applyingCustomUserAgent: true)
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
    Task {
      await handleTaskCompletion(task: task, error: error)
    }
  }
  
  private func handleTaskCompletion(task: URLSessionTask, error: Error?) async {
    guard let book = await taskIdentifierToBook.get(task.taskIdentifier) else {
      return
    }
    
    self.taskIdentifierToRedirectAttempts.removeValue(forKey: task.taskIdentifier)
    
    if let error = error as NSError?, error.code != NSURLErrorCancelled {
      logBookDownloadFailure(book, reason: "networking error", downloadTask: task, metadata: ["urlSessionError": error])
      failDownloadWithAlert(for: book)
      return
    }
    // Attempt to start next pending downloads
    schedulePendingStartsIfPossible()
  }
  
  private func addDownloadTask(with request: URLRequest, book: TPPBook) {
    var modifiableRequest = request
    let task = self.session.downloadTask(with: modifiableRequest.applyCustomUserAgent())
    
    let downloadInfo = MyBooksDownloadInfo(
      downloadProgress: 0.0,
      downloadTask: task,
      rightsManagement: .unknown
    )
    
    // CRITICAL: Store task info BEFORE resuming to prevent race condition
    // URLSession delegate callbacks can fire immediately after resume()
    Task {
      await self.bookIdentifierToDownloadInfo.set(book.identifier, value: downloadInfo)
      await self.taskIdentifierToBook.set(task.taskIdentifier, value: book)
      
      // Resume task AFTER storage to ensure delegate callbacks can find it
      task.resume()
      
      // Update registry and notify
      self.bookRegistry.addBook(book,
                               location: self.bookRegistry.location(forIdentifier: book.identifier),
                               state: .downloading,
                               fulfillmentId: nil,
                               readiumBookmarks: nil,
                               genericBookmarks: nil)
      
      runOnMainAsync {
        NotificationCenter.default.post(name: .TPPMyBooksDownloadCenterDidChange, object: self)
      }

      // After starting one, see if we can start pending ones within capacity
      self.schedulePendingStartsIfPossible()
    }
  }
}

// MARK: - Download Throttling and Disk Budget
extension MyBooksDownloadCenter {
  private func activeDownloadCount() -> Int {
    // Use RunLoop spinning to avoid priority inversion
    var count = 0
    var isComplete = false
    
    Task {
      let allInfo = await bookIdentifierToDownloadInfo.values()
      let runningTasks = allInfo.compactMap { info -> URLSessionTask? in
        return info.downloadTask
      }.filter { $0.state == .running }
      count = runningTasks.count
      isComplete = true
    }
    
    // Spin run loop for short time
    let timeoutDate = Date().addingTimeInterval(0.5)
    while !isComplete && Date() < timeoutDate {
      RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    
    if !isComplete {
      Log.warn(#file, "⚠️ Actor access slow for activeDownloadCount - returning 0")
      return 0
    }
    
    return count
  }

  private func enqueuePending(_ book: TPPBook) {
    if !pendingStartQueue.contains(where: { $0.identifier == book.identifier }) {
      pendingStartQueue.append(book)
    }
  }

  private func schedulePendingStartsIfPossible() {
    let capacity = maxConcurrentDownloads - activeDownloadCount()
    guard capacity > 0 else { return }
    let toStart = Array(pendingStartQueue.prefix(capacity))
    if !toStart.isEmpty {
      pendingStartQueue.removeFirst(min(capacity, pendingStartQueue.count))
      toStart.forEach { startDownload(for: $0) }
    }
  }

  /// Enforces a soft content disk budget. If `adding` is >0, assumes that many bytes will be added
  /// and makes room accordingly, deleting least-recently-used content first.
  @objc func enforceContentDiskBudgetIfNeeded(adding bytesToAdd: Int64) {
    let smallDevice = UIScreen.main.nativeBounds.height <= 1334 // iPhone 6/7/8 size and below
    // Relax budgets: give small devices ~1.2GB, others ~2.5GB before eviction
    let budgetBytes: Int64 = smallDevice ? (1_200 * 1024 * 1024) : (2_500 * 1024 * 1024)

    let currentUsage = contentDirectoryUsageBytes()
    var neededFree = (currentUsage + bytesToAdd) - budgetBytes
    guard neededFree > 0 else { return }

    let files = listContentFilesSortedByLRU()
    let fm = FileManager.default
    for url in files {
      if neededFree <= 0 { break }
      // Never delete LCP license/content files during eviction
      let ext = url.pathExtension.lowercased()
      if ext == "lcpl" || ext == "lcpa" { continue }
      if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
        try? fm.removeItem(at: url)
        neededFree -= Int64(size)
      }
    }
  }

  private func contentDirectoryUsageBytes() -> Int64 {
    guard let dir = contentDirectoryURL(AccountsManager.shared.currentAccountId) else { return 0 }
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
    var total: Int64 = 0
    for url in contents {
      if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { total += Int64(size) }
    }
    return total
  }

  private func listContentFilesSortedByLRU() -> [URL] {
    guard let dir = contentDirectoryURL(AccountsManager.shared.currentAccountId) else { return [] }
    let fm = FileManager.default
    guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
    return contents.sorted { a, b in
      let ra = try? a.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
      let rb = try? b.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
      let da = ra?.contentAccessDate ?? ra?.contentModificationDate ?? Date.distantPast
      let db = rb?.contentAccessDate ?? rb?.contentModificationDate ?? Date.distantPast
      return da < db
    }
  }
}

extension MyBooksDownloadCenter {
  // Public helpers for memory monitor
  @objc func limitActiveDownloads(max: Int) {
    maxConcurrentDownloads = max
    
    Task {
      await limitActiveDownloadsAsync(max: max)
    }
  }
  
  private func limitActiveDownloadsAsync(max: Int) async {
    let allInfo = await bookIdentifierToDownloadInfo.values()
    let running = allInfo.compactMap { $0.downloadTask }.filter { $0.state == .running }
    let suspended = allInfo.compactMap { $0.downloadTask }.filter { $0.state == .suspended }

    if running.count > max {
      var nonAudiobookTasks: [URLSessionTask] = []
      for task in running {
        if let book = await taskIdentifierToBook.get(task.taskIdentifier) {
          if book.defaultBookContentType != .audiobook {
            nonAudiobookTasks.append(task)
          }
        } else {
          nonAudiobookTasks.append(task)
        }
      }
      
      let tasksToSuspend = nonAudiobookTasks.dropFirst(Swift.max(0, max - (running.count - nonAudiobookTasks.count)))
      for task in tasksToSuspend { 
        Log.info(#file, "Suspending non-audiobook download to respect limits")
        task.suspend() 
      }
    } else if running.count < max {
      let toResume = min(max - running.count, suspended.count)
      if toResume > 0 {
        for task in suspended.prefix(toResume) { task.resume() }
      }
    }
    schedulePendingStartsIfPossible()
  }

  @objc func pauseAllDownloads() {
    Task {
      await pauseAllDownloadsAsync()
    }
  }
  
  private func pauseAllDownloadsAsync() async {
    let allInfo = await bookIdentifierToDownloadInfo.values()
    for info in allInfo {
      if let book = await taskIdentifierToBook.get(info.downloadTask.taskIdentifier),
         book.defaultBookContentType == .audiobook {
        Log.info(#file, "Preserving audiobook download/streaming for: \(book.title)")
        continue
      }
      info.downloadTask.suspend()
    }
  }
  
  @objc func resumeIntelligentDownloads() {
    limitActiveDownloads(max: maxConcurrentDownloads)
  }
  
  func setupNetworkMonitoring() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(networkConditionsChanged),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    Log.info(#file, "Network monitoring setup for download optimization")
  }
  
  @objc private func networkConditionsChanged() {
    let currentLimit = maxConcurrentDownloads
    limitActiveDownloads(max: currentLimit)
  }
  
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
    
    // Use enhanced logging if enabled
    Task {
      await DeviceSpecificErrorMonitor.shared.logDownloadFailure(
        book: book,
        reason: reason,
        error: downloadTask.error,
        metadata: dict
      )
    }
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
      failDownloadWithAlert(for: book, withMessage: error.localizedDescription)
      return
    }
    
    let lcpProgress: (Double) -> Void = { [weak self] progressValue in
      guard let self = self else { return }
      Task {
        if let info = await self.downloadInfoAsync(forBookIdentifier: book.identifier)?.withDownloadProgress(progressValue) {
          await self.bookIdentifierToDownloadInfo.set(book.identifier, value: info)
        }
        self.broadcastUpdate()
      }
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
            let license = TPPLCPLicense(url: licenseUrl)
      else {
        let errorMessage = "Error with LCP license fulfillment: \(localUrl?.absoluteString ?? "")"
        self.failDownloadWithAlert(for: book, withMessage: errorMessage)
        return
      }
      self.bookRegistry.setFulfillmentId(license.identifier, for: book.identifier)
      
      if !self.replaceBook(book, withFileAtURL: localUrl, forDownloadTask: downloadTask) {
        if book.defaultBookContentType == .audiobook {
          Log.warn(#file, "Content storage failed for audiobook, but streaming still available")
        } else {
          let errorMessage = "Error replacing content file with file \(localUrl.absoluteString)"
          self.failDownloadWithAlert(for: book, withMessage: errorMessage)
          return
        }
      } else {
        if book.defaultBookContentType == .audiobook {
          Log.info(#file, "Audiobook content stored successfully, offline playback now available")
        }
      }
      
      Task {
        if book.defaultBookContentType == .pdf,
           let bookURL = self.fileUrl(for: book.identifier) {
          self.bookRegistry.setState(.downloading, for: book.identifier)
          let _ = try? await LCPPDFs(url: bookURL)?.extract(url: bookURL)
          self.bookRegistry.setState(.downloadSuccessful, for: book.identifier)
        }
      }
    }
    
    let fulfillmentDownloadTask = lcpService.fulfill(licenseUrl, progress: lcpProgress, completion: lcpCompletion)
    
    if book.defaultBookContentType == .audiobook {
      Log.info(#file, "LCP audiobook license fulfilled, ready for streaming: \(book.identifier)")
      
      if let license = TPPLCPLicense(url: licenseUrl) {
        self.bookRegistry.setFulfillmentId(license.identifier, for: book.identifier)
      } else {
        Log.error(#file, "🔑 ❌ Failed to read license for fulfillment ID")
      }
      
      self.copyLicenseForStreaming(book: book, sourceLicenseUrl: licenseUrl)
      self.bookRegistry.setState(.downloadSuccessful, for: book.identifier)
      
      runOnMainAsync {
        self.broadcastUpdate()
      }
    }
    
    if let fulfillmentDownloadTask = fulfillmentDownloadTask {
      let downloadInfo = MyBooksDownloadInfo(downloadProgress: 0.0, downloadTask: fulfillmentDownloadTask, rightsManagement: .none)
      Task {
        await self.bookIdentifierToDownloadInfo.set(book.identifier, value: downloadInfo)
      }
    }
#endif
  }
  
  /// Copies the LCP license file to the content directory for streaming support
  /// while preserving the existing fulfillment flow
  private func copyLicenseForStreaming(book: TPPBook, sourceLicenseUrl: URL) {
#if LCP
    Log.info(#file, "🎵 Starting license copy for streaming: \(book.identifier)")
    
    guard let finalContentURL = self.fileUrl(for: book.identifier) else {
      Log.error(#file, "🎵 ❌ Unable to determine final content URL for streaming license copy")
      return
    }
    
    let streamingLicenseUrl = finalContentURL.deletingPathExtension().appendingPathExtension("lcpl")
    Log.info(#file, "🎵 Copying license FROM: \(sourceLicenseUrl.path)")
    Log.info(#file, "🎵 Copying license TO: \(streamingLicenseUrl.path)")
    
    do {
      try? FileManager.default.removeItem(at: streamingLicenseUrl)
      try FileManager.default.copyItem(at: sourceLicenseUrl, to: streamingLicenseUrl)
      
      let fileExists = FileManager.default.fileExists(atPath: streamingLicenseUrl.path)
    } catch {
      TPPErrorLogger.logError(error, summary: "Failed to copy LCP license for streaming", metadata: [
        "book": book.loggableDictionary,
        "sourceLicenseUrl": sourceLicenseUrl.absoluteString,
        "targetLicenseUrl": streamingLicenseUrl.absoluteString
      ])
    }
#endif
  }
  
  func failDownloadWithAlert(for book: TPPBook, withMessage message: String? = nil) {
    let location = bookRegistry.location(forIdentifier: book.identifier)
    
    bookRegistry.addBook(book,
                         location: location,
                         state: .downloadFailed,
                         fulfillmentId: nil,
                         readiumBookmarks: nil,
                         genericBookmarks: nil)
    
    runOnMainAsync {
      let errorMessage = message ?? "No error message"
      let formattedMessage = String.localizedStringWithFormat(NSLocalizedString("The download for %@ could not be completed.", comment: ""), book.title)
      let finalMessage = "\(formattedMessage)\n\(errorMessage)"
      let alert = TPPAlertUtils.alert(title: "DownloadFailed", message: finalMessage)
      runOnMainAsync {
        TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
      }
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
        bookRegistry.removeBook(forIdentifier: book.identifier)
      }
    } else if let error = error {
      alert.message = String(format: "%@\n\nError: %@", msg, error.localizedDescription)
    }
    
    runOnMainAsync {
      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
    }
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
      bookRegistry.setState(.downloadSuccessful, for: book.identifier)
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
      // Note: For LCP audiobooks, state is set in fulfillLCPLicense after license is ready
      // For non-LCP audiobooks and other content types, set state here after content is successfully stored
#if LCP
      let isLCPAudiobook = book.defaultBookContentType == .audiobook && LCPAudiobooks.canOpenBook(book)
      if !isLCPAudiobook {
        bookRegistry.setState(.downloadSuccessful, for: book.identifier)
      }
#else
      bookRegistry.setState(.downloadSuccessful, for: book.identifier)
#endif
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
  
  @objc func fileUrl(for identifier: String) -> URL? {
    return fileUrl(for: identifier, account: AccountsManager.shared.currentAccountId)
  }
  
  func fileUrl(for identifier: String, account: String?) -> URL? {
    guard let book = bookRegistry.book(forIdentifier: identifier) else {
      return nil
    }
    
    let pathExtension = pathExtension(for: book)
    let contentDirectoryURL = self.contentDirectoryURL(account)
    let hashedIdentifier = identifier.sha256()
    
    return contentDirectoryURL?.appendingPathComponent(hashedIdentifier).appendingPathExtension(pathExtension)
  }
  
  func contentDirectoryURL(_ account: String?) -> URL? {
    guard let directoryURL = TPPBookContentMetadataFilesHelper.directory(for: account ?? "")?.appendingPathComponent("content") else {
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

extension MyBooksDownloadCenter: TPPBookDownloadsDeleting {
  func reset(_ libraryID: String!) {
    reset(account: libraryID)
  }
  
  func reset(account: String) {
    if AccountsManager.shared.currentAccountId == account {
      reset()
    } else {
      deleteAudiobooks(forAccount: account)
      do {
        if let url = contentDirectoryURL(account) {
          try FileManager.default.removeItem(at: url)
        }
      } catch {
        // Handle error, if needed
      }
    }
  }
  
  func reset() {
    guard let currentAccountId = AccountsManager.shared.currentAccountId else {
      return
    }
    
    deleteAudiobooks(forAccount: currentAccountId)
    
    Task {
      let allInfo = await bookIdentifierToDownloadInfo.values()
      for info in allInfo {
        info.downloadTask.cancel(byProducingResumeData: { _ in })
      }
      
      await bookIdentifierToDownloadInfo.removeAll()
      await taskIdentifierToBook.removeAll()
    }
    
    bookIdentifierOfBookToRemove = nil
    
    do {
      if let url = contentDirectoryURL(currentAccountId) {
        try FileManager.default.removeItem(at: url)
      }
    } catch {
      // Handle error, if needed
    }
    
    broadcastUpdate()
  }
  
  func deleteAudiobooks(forAccount account: String) {
    bookRegistry.with(account: account) { registry in
      let books = registry.allBooks
      for book in books {
        if book.defaultBookContentType == .audiobook {
          deleteLocalContent(for: book.identifier, account: account)
        }
      }
    }
  }

  // Purge cached audio fragments (e.g., streaming or decrypted chunks) from the Caches directory.
  // If `force` is false, purges only when there are no active audiobooks in the registry.
  func purgeAllAudiobookCaches(force: Bool = false) {
    if !force && hasActiveAudiobooks() { return }
    let fm = FileManager.default
    guard let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
    let audioExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "oga", "wav"]
    if let contents = try? fm.contentsOfDirectory(at: cachesDir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
      for url in contents {
        do {
          let rv = try url.resourceValues(forKeys: [.isDirectoryKey])
          if rv.isDirectory == true { continue }
          if audioExtensions.contains(url.pathExtension.lowercased()) {
            try? fm.removeItem(at: url)
          }
        } catch {
          // ignore
        }
      }
    }
  }

  private func hasActiveAudiobooks() -> Bool {
    let matchingStates: [TPPBookState] = [ .downloadNeeded, .downloading, .downloadSuccessful, .used ]
    var hasActive = false
    let accountId = AccountsManager.shared.currentAccountId ?? ""
    bookRegistry.with(account: accountId) { registry in
      let audiobooks = registry.myBooks.filter { $0.defaultBookContentType == .audiobook }
      hasActive = audiobooks.contains { matchingStates.contains(registry.state(for: $0.identifier)) }
    }
    return hasActive
  }
  
  @objc func downloadProgress(for bookIdentifier: String) -> Double {
    Double(self.downloadInfo(forBookIdentifier: bookIdentifier)?.downloadProgress ?? 0.0)
  }
}

#if FEATURE_DRM_CONNECTOR
extension MyBooksDownloadCenter: NYPLADEPTDelegate {
  
  func adept(_ adept: NYPLADEPT, didFinishDownload: Bool, to adeptToURL: URL?, fulfillmentID: String?, isReturnable: Bool, rightsData: Data, tag: String, error adeptError: Error?) {
    guard let book = bookRegistry.book(forIdentifier: tag),
          let rights = String(data: rightsData, encoding: .utf8) else { return }
    
    var didSucceedCopying = false
    
    if didFinishDownload {
      guard let fileURL = fileUrl(for: book.identifier) else { return }
      let fileManager = FileManager.default
      
      do {
        try fileManager.removeItem(at: fileURL)
      } catch {
        print("Remove item error: \(error)")
      }
      
      guard let destURL = fileUrl(for: book.identifier), let adeptToURL = adeptToURL else {
        TPPErrorLogger.logError(withCode: .adobeDRMFulfillmentFail, summary: "Adobe DRM error: destination file URL unavailable", metadata: [
          "adeptError": adeptError ?? "N/A",
          "fileURLToRemove": adeptToURL ?? "N/A",
          "book": book.loggableDictionary,
          "AdobeFulfilmmentID": fulfillmentID ?? "N/A",
          "AdobeRights": rights,
          "AdobeTag": tag
        ])
        self.failDownloadWithAlert(for: book)
        return
      }
      
      do {
        try fileManager.copyItem(at: adeptToURL, to: destURL)
        didSucceedCopying = true
      } catch {
        TPPErrorLogger.logError(withCode: .adobeDRMFulfillmentFail, summary: "Adobe DRM error: failure copying file", metadata: [
          "adeptError": adeptError ?? "N/A",
          "copyError": error,
          "fromURL": adeptToURL,
          "destURL": destURL,
          "book": book.loggableDictionary,
          "AdobeFulfilmmentID": fulfillmentID ?? "N/A",
          "AdobeRights": rights,
          "AdobeTag": tag
        ])
      }
    } else {
      TPPErrorLogger.logError(withCode: .adobeDRMFulfillmentFail, summary: "Adobe DRM error: did not finish download", metadata: [
        "adeptError": adeptError ?? "N/A",
        "adeptToURL": adeptToURL ?? "N/A",
        "book": book.loggableDictionary,
        "AdobeFulfilmmentID": fulfillmentID ?? "N/A",
        "AdobeRights": rights,
        "AdobeTag": tag
      ])
    }
    
    if !didFinishDownload || !didSucceedCopying {
      self.failDownloadWithAlert(for: book)
      return
    }
    
    guard let rightsFilePath = fileUrl(for: book.identifier)?.path.appending("_rights.xml") else { return }
    do {
      try rightsData.write(to: URL(fileURLWithPath: rightsFilePath))
    } catch {
      print("Failed to store rights data.")
    }
    
    if isReturnable, let fulfillmentID = fulfillmentID {
      bookRegistry.setFulfillmentId(fulfillmentID, for: book.identifier)
    }
    
    bookRegistry.setState(.downloadSuccessful, for: book.identifier)
    
    self.broadcastUpdate()
  }
  
  func adept(_ adept: NYPLADEPT, didUpdateProgress progress: Double, tag: String) {
    Task {
      if let info = await self.downloadInfoAsync(forBookIdentifier: tag)?.withDownloadProgress(progress) {
        await self.bookIdentifierToDownloadInfo.set(tag, value: info)
      }
      self.broadcastUpdate()
    }
  }
  
  func adept(_ adept: NYPLADEPT, didCancelDownloadWithTag tag: String) {
    bookRegistry.setState(.downloadNeeded, for: tag)
    self.broadcastUpdate()
  }
  
  func didIgnoreFulfillmentWithNoAuthorizationPresent() {
    self.reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: true, authenticationCompletion: nil)
  }
}
#endif
