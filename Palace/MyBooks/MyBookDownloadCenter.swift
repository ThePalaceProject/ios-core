//
//  TPPMyBookDownloadCenter.swift
//  Palace
//
//  Created by Maurice Carrier on 6/13/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

#if canImport(ADEPT)
import ADEPT
import OverdriveProcessor
extension MyBooksDownloadCenter: NYPLADEPTDelegate { }
#endif

class MyBooksDownloadCenter: NSObject {
  typealias DisplayStrings = Strings.MyDownloadCenter
  
  static let shared = MyBooksDownloadCenter()
  let networkManager = NetworkManager.shared
  
  private var bookIdentifierOfBookToRemove: String?
  private var broadcastScheduled = false
  private var reauthenticator = TPPReauthenticator()
  
  override init() {
    super.init()
    networkManager.delegate = self
#if canImport(ADEPT)
    if !AdobeCertificate.defaultCertificate.hasExpired {
      NYPLADEPT.sharedInstance().delegate = self
    }
#endif
  }
}

extension MyBooksDownloadCenter: BooksNetworkManagerDelegate {
  func process(error: [String: Any]?, for book: TPPBook) {
    guard let errorType = error?["type"] as? String else {
      showGenericBorrowFailedAlert(for: book)
      return
    }
    
    let alertTitle = DisplayStrings.borrowFailed
    var alertMessage: String
    var alert: UIAlertController
    
    switch errorType {
    case TPPProblemDocument.TypeLoanAlreadyExists:
      alertMessage = DisplayStrings.loanAlreadyExistsAlertMessage
      alert = TPPAlertUtils.alert(title: alertTitle, message: alertMessage)
      
    case TPPProblemDocument.TypeInvalidCredentials:
      NSLog("Invalid credentials problem when borrowing a book, present sign in VC")
      reauthenticator.authenticateIfNeeded(TPPUserAccount.sharedAccount(), usingExistingCredentials: false) { [weak self] in
        self?.networkManager.startDownload(for: book)
      }
      return
    default:
      alertMessage = String(format: DisplayStrings.borrowFailedMessage, book.title)
      alert = TPPAlertUtils.alert(title: alertTitle, message: alertMessage)
      
      if let error = error {
        TPPAlertUtils.setProblemDocument(controller: alert, document:  TPPProblemDocument.fromDictionary(error), append: false)
      }
    }
    
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
  
  func showGenericBorrowFailedAlert(for book: TPPBook) {
    let formattedMessage = String(format: DisplayStrings.borrowFailedMessage, book.title)
    let alert = TPPAlertUtils.alert(title: DisplayStrings.borrowFailed, message: formattedMessage)
    TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert, viewController: nil, animated: true, completion: nil)
  }
  
  func handleOverdriveResponse(
    for book: TPPBook,
    url: URL?,
    withState state: TPPBookState,
    responseHeaders: [AnyHashable: Any]?,
    error: Error?
  ) {
#if canImport(ADEPT)
    let summary = "Overdrive audiobook fulfillment error"
    let summaryWrongHeaders = "Overdrive audiobook fulfillment: wrong headers"
    let nA = "N/A"
    let responseHeadersKey = "responseHeaders"
    let acquisitionURLKey = "acquisitionURL"
    let bookKey = "book"
    let bookRegistryStateKey = "bookRegistryState"
    
    if let error = error {
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
    
    guard let scope = normalizedHeaders?[scopeKey],
          let patronAuthorization = normalizedHeaders?[patronAuthorizationKey],
          let requestURLString = normalizedHeaders?[locationKey] else {
      TPPErrorLogger.logError(withCode: .overdriveFulfillResponseParseFail, summary: summaryWrongHeaders, metadata: [
        responseHeadersKey: responseHeaders ?? nA,
        acquisitionURLKey: url?.absoluteString ?? nA,
        bookKey: book.loggableDictionary,
        bookRegistryStateKey: TPPBookStateHelper.stringValue(from: state)
      ])
      self.failDownloadWithAlert(for: book)
      return
    }
    
    let request = OverdriveAPIExecutor.shared.getManifestRequest(withUrlString: requestURLString, token: patronAuthorization, scope: scope)
    self.addDownloadTask(with: request, book: book)
#endif
  }
}
