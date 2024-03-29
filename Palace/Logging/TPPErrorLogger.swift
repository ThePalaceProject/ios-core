//
//  The Palace Project
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import CFNetwork
import Foundation
import FirebaseCore
import FirebaseCrashlytics

fileprivate let nullString = "null"

@objc enum TPPSeverity: NSInteger {
  case error, warning, info

  func stringValue() -> String {
    switch self {
    case .error: return "error"
    case .warning: return "warning"
    case .info: return "info"
    }
  }
}

/// Detailed error codes that span across different error reports.
/// E.g. you could have a `invalidURLSession` for a number of different api
/// calls, happening in catalog loading, sign-in, etc. So the `summary` of
/// the error will be different, but the code will be the same. Sometimes it
/// is useful in fact to search all possible instances of a given code.
@objc enum TPPErrorCode: Int {
  case ignore = 0

  // generic app related
  case appLaunch = 100
  case appLogicInconsistency = 101
  case genericErrorMsgDisplayed = 103

  // book registry / My books
  case unknownBookState = 203
  case registrySyncFailure = 204

  // sign in/out/up
  case invalidLicensor = 300
  case invalidCredentials = 301
  case barcodeException = 302
  case remoteLoginError = 303
  case userProfileDocFail = 305
  case nilSignUpURL = 306
  case adeptAuthFail = 307
  case noAuthorizationIdentifier = 308
  case noLicensorToken = 309
  case loginErrorWithProblemDoc = 310
  case missingParentBarcodeForJuvenile = 311
  case cardCreatorCredentialsDecodeFail = 312
  case oauthPatronInfoDecodeFail = 313
  case unrecognizedUniversalLink = 314
  case validationWithoutAuthToken = 315

  // audiobooks
  case audiobookCorrupted = 401
  case audiobookExternalError = 402

  // ereader
  case nilCFI = 500
  case bookmarkReadError = 501

  // Parse failure
  case parseProfileDataCorrupted = 600
  case parseProfileTypeMismatch = 601
  case parseProfileValueNotFound = 602
  case parseProfileKeyNotFound = 603
  case feedParseFail = 604
  case opdsFeedParseFail = 605
  case invalidXML = 606
  case authDocParseFail = 607
  case parseProblemDocFail = 608
  case overdriveFulfillResponseParseFail = 609
  case authDataParseFail = 610

  // account management
  case authDocLoadFail = 700
  case libraryListLoadFail = 701

  // feeds
  case opdsFeedNoData = 800
  case invalidFeedType = 801
  case noAgeGateElement = 802

  // networking, generic
  case noURL = 900
  case invalidURLSession = 901 // used to be 101 up to 3.4.0
  case apiCall = 902 // used to be 102 up to 3.4.0
  case invalidResponseMimeType = 903
  case unexpectedHTTPCodeWarning = 904
  case problemDocMessageDisplayed = 905
  case unableToMakeVCAfterLoading = 906
  case noTaskInfoAvailable = 907
  case downloadFail = 908
  case responseFail = 909
  case clientSideTransientError = 910
  case clientSideUserInterruption = 911
  case problemDocAvailable = 912
  case malformedURL = 913
  case invalidOrNoHTTPResponse = 914

  // DRM
  case epubDecodingError = 1000
  case adobeDRMFulfillmentFail = 1001
  case lcpDRMFulfillmentFail = 1002
  case lcpPassphraseAuthorizationFail = 1003
  case lcpPassphraseRetrievalFail = 1004

  // wrong content
  case unknownRightsManagement = 1100
  case unexpectedFormat = 1101

  // low-level / system related
  case missingSystemPaths = 1200
  case fileMoveFail = 1201
  case directoryURLCreateFail = 1202
  case missingExpectedObject = 1203

  // keychain
  case keychainItemAddFail = 1300
  
  // localization
  case locationAccessDenied = 1400
  case failedToGetLocation = 1401
  case unknownLocationError = 1402
}

/// Facility to report error situations to a remote logging system such as
/// Crashlytics.
///
/// Please refer to the following page for guidelines on how to file an
/// effective error report:
/// https://github.com/NYPL-Simplified/Simplified/wiki/Error-reporting-on-iOS
@objcMembers class TPPErrorLogger : NSObject {

  @objc static let clientDomain = "org.thepalaceproject.palace"

  //----------------------------------------------------------------------------
  // MARK:- Configuration

  class func configureCrashAnalytics() {
    // Only enable Crashlytics on Production builds
    guard Bundle.main.applicationEnvironment == .production else { return }
    
    #if FEATURE_CRASH_REPORTING
    if let deviceID = UIDevice.current.identifierForVendor?.uuidString {
      Crashlytics.crashlytics().setCustomValue(deviceID, forKey: "PalaceDeviceID")
    }
    #endif
  }

  class func setUserID(_ userID: String?) {
    // Only enable Crashlytics on Production builds
    guard Bundle.main.applicationEnvironment == .production else { return }

    #if FEATURE_CRASH_REPORTING
    if let userIDmd5 = userID?.md5hex() {
      Crashlytics.crashlytics().setUserID(userIDmd5)
    } else {
      Crashlytics.crashlytics().setUserID("SIGNED_OUT_USER")
    }
    #endif
  }

  //----------------------------------------------------------------------------
  // MARK:- Generic methods for error logging

  /// Reports an error.
  /// - Parameters:
  ///   - error: Any originating error that occurred.
  ///   - summary: This will be the top line (searchable) in Crashlytics UI.
  ///   - metadata: Any additional metadata to be logged.
  class func logError(_ error: Error?,
                      summary: String,
                      metadata: [String: Any]? = nil) {
    logError(error,
             code: .ignore,
             summary: summary,
             metadata: metadata)
  }


  /// Reports an error situation.
  /// - Parameters:
  ///   - code: A code identifying the error situation. Searchable in
  ///   Crashlytics UI.
  ///   - summary: This will be the top line (searchable) in Crashlytics UI.
  ///   - metadata: Any additional metadata to be logged.
  class func logError(withCode code: TPPErrorCode,
                      summary: String,
                      metadata: [String: Any]? = nil) {
    logError(nil,
             code: code,
             summary: summary,
             metadata: metadata)
  }

  /// Use this function for logging low-level errors occurring in api execution
  /// when there's no other more relevant context available, or when it's more
  /// relevant to log request and response objects.
  /// - Parameters:
  ///   - originalError: Any originating error that occurred. This will be
  ///   wrapped under `NSUnderlyingErrorKey` in Crashlytics.
  ///   - code: Client-provided code to identify errors more easily.
  ///   Searchable in Crashlytics.
  ///   - summary: Client-provided context to identify errors more easily.
  ///   Searchable in Crashlytics.
  ///   - request: Only the output of `loggableString` will be attached to the
  ///   report, to ensure privacy.
  ///   - response: Useful to understand if the error originated on the server.
  ///   - metadata: Free-form dictionary for additional metadata to be logged.
  class func logNetworkError(_ originalError: Error? = nil,
                             code: TPPErrorCode = .ignore,
                             summary: String?,
                             request: URLRequest?,
                             response: URLResponse? = nil,
                             metadata: [String: Any]? = nil) {
    logError(originalError,
             code: (code != .ignore ? code : TPPErrorCode.apiCall),
             summary: summary ?? "Network error",
             request: request,
             response: response,
             metadata: metadata)
  }

  //----------------------------------------------------------------------------
  // MARK:- Sign up/in/out errors

  /// Report when there's an error logging in to an account.
  /// - Parameters:
  ///   - error: The error returned, if any.
  ///   - library: The library the user is trying to sign in into.
  ///   - response: The response that returned the error.
  ///   - problemDocument: A structured error description returned by the server.
  ///   - metadata: Free-form dictionary for additional metadata to be logged.
  class func logLoginError(_ error: NSError?,
                           library: Account?,
                           response: URLResponse?,
                           problemDocument: TPPProblemDocument?,
                           metadata: [String: Any]?) {
    var metadata = metadata ?? [String : Any]()
    if let error = error {
      metadata[NSUnderlyingErrorKey] = error
    }
    if let response = response as? HTTPURLResponse {
      metadata["responseStatusCode"] = response.statusCode
      metadata["responseMime"] = response.mimeType ?? nullString
      metadata["responseHeaders"] = response.allHeaderFields
    }
    if let library = library {
      metadata["libraryUUID"] = library.uuid
      metadata["libraryName"] = library.name
    }
    let errorCode: Int
    if let problemDocument = problemDocument {
      metadata["problemDocument"] = problemDocument.dictionaryValue
      errorCode = TPPErrorCode.loginErrorWithProblemDoc.rawValue
    } else {
      errorCode = TPPErrorCode.remoteLoginError.rawValue
    }
    addAccountInfoToMetadata(&metadata)

    let userInfo = additionalInfo(severity: .error, metadata: metadata)
    let err = NSError(domain: "SignIn error: problem document available",
                      code: errorCode,
                      userInfo: userInfo)

    record(error: err)
  }

  /**
    Report when there's an error logging in to an account locally
    @param error related error
    @param libraryName name of the library
    @return
   */
  class func logLocalAuthFailed(error: NSError?,
                                library: Account?,
                                metadata: [String: Any]?) {
    var metadata = metadata ?? [String : Any]()
    if let library = library {
      metadata["libraryUUID"] = library.uuid
      metadata["libraryName"] = library.name
    }
    metadata["errorDescription"] = error?.localizedDescription ?? nullString
    if let error = error {
      metadata[NSUnderlyingErrorKey] = error
    }
    addAccountInfoToMetadata(&metadata)
    
    let userInfo = additionalInfo(severity: .info,
                                  message: "Local Login Failed With Error",
                                  metadata: metadata)
    let err = NSError(domain: "SignIn error: Adobe activation",
                      code: TPPErrorCode.adeptAuthFail.rawValue,
                      userInfo: userInfo)

    record(error: err)
  }

  /**
    Report when there's missing licensor data during deauthorization
    - Parameter accountId: id of the library account.
   */
  class func logInvalidLicensor(withAccountID accountId: String?) {
    var metadata = [String : Any]()
    metadata["accountTypeID"] = accountId ?? nullString
    addAccountInfoToMetadata(&metadata)
    
    let userInfo = additionalInfo(
      severity: .warning,
      message: "No Valid Licensor available to deauthorize device. Signing out TPPAccount credentials anyway with no message to the user.",
      metadata: metadata)
    let err = NSError(domain: "SignOut deauthorization error: no licensor",
                      code: TPPErrorCode.invalidLicensor.rawValue,
                      userInfo: userInfo)

    record(error: err)
  }

  /// Report when there's an issue parsing a user profile document obtained
  /// from the server during sign in / up / out process.
  /// - Parameters:
  ///   - error: The parse error.
  ///   - summary: This will be the top line (searchable) in Crashlytics UI.
  ///   - barcode: The clear-text barcode used to authenticate. This will be
  ///   hashed.
  class func logUserProfileDocumentAuthError(_ error: NSError?,
                                             summary: String,
                                             barcode: String?,
                                             metadata: [String: Any]? = nil) {
    var userInfo = metadata ?? [String : Any]()
    addAccountInfoToMetadata(&userInfo)
    userInfo = additionalInfo(severity: .error, metadata: userInfo)
    if let barcode = barcode {
      userInfo["hashedBarcode"] = barcode.md5hex()
    }
    if let originalError = error {
      userInfo[NSUnderlyingErrorKey] = originalError
    }

    let err = NSError(domain: summary,
                      code: TPPErrorCode.userProfileDocFail.rawValue,
                      userInfo: userInfo)

    record(error: err)
  }

  //----------------------------------------------------------------------------
  // MARK:- Misc

  /**
    Report when user launches the app.
   */
  class func logNewAppLaunch() {
    var metadata = [String : Any]()
    addAccountInfoToMetadata(&metadata)
    
    let userInfo = additionalInfo(severity: .info, metadata: metadata)
    let err = NSError(domain: clientDomain,
                      code: TPPErrorCode.appLaunch.rawValue,
                      userInfo: userInfo)

    record(error: err)
  }

  /**
    Report when there's an issue with barcode image encoding
    @param exception the related exception
    @param library library for which the barcode is being created
    @return
   */
  class func logBarcodeException(_ exception: NSException?, library: String?) {
    var metadata: [String : Any] = [
      "Library": library ?? nullString,
      "ExceptionName": exception?.name ?? nullString,
      "ExceptionReason": exception?.reason ?? nullString,
    ]

    addAccountInfoToMetadata(&metadata)
    let userInfo = additionalInfo(severity: .info, metadata: metadata)

    let err = NSError(domain: "SignIn error: BarcodeScanner exception",
                      code: TPPErrorCode.barcodeException.rawValue,
                      userInfo: userInfo)

    record(error: err)
  }

  class func logCatalogInitError(withCode code: TPPErrorCode,
                                 response: URLResponse?,
                                 metadata: [String: Any]?) {
    var metadata = metadata ?? [String: Any]()
    if let response = response {
      metadata["response"] = response
    }
    logError(withCode: code,
             summary: "Catalog VC Initialization",
             metadata: metadata)
  }

  /**
   Report when there's an issue parsing a problem document.
   - parameter originalError: the parsing error.
   - parameter url: the url the problem document is being fetched from.
   - parameter summary: This will be the top line (searchable) in Crashlytics UI.
   - parameter metadata: Any additional metadata to be logged for more context.
   */
  class func logProblemDocumentParseError(_ originalError: NSError,
                                          problemDocumentData: Data?,
                                          url: URL?,
                                          summary: String,
                                          metadata: [String: Any]? = nil) {
    var metadata = metadata ?? [String: Any]()
    addAccountInfoToMetadata(&metadata)
    metadata["url"] = url ?? nullString
    metadata["errorDescription"] = originalError.localizedDescription
    metadata[NSUnderlyingErrorKey] = originalError
    if let problemDocumentData = problemDocumentData {
      if let problemDocString = String(data: problemDocumentData, encoding: .utf8) {
        metadata["receivedProblemDocumentData"] = problemDocString
      }
    }

    let userInfo = additionalInfo(
      severity: .error,
      metadata: metadata)

    let err = NSError(domain: summary,
                      code: TPPErrorCode.parseProblemDocFail.rawValue,
                      userInfo: userInfo)

    record(error: err)
  }
  
  //----------------------------------------------------------------------------
  // MARK:- Private helpers

  private class func record(error: NSError) {
    // Only enable Crashlytics on Production builds
    guard Bundle.main.applicationEnvironment == .production else { return }

    #if FEATURE_CRASH_REPORTING
    Crashlytics.crashlytics().record(error: error)
    #else
    Log.error("LOG_ERROR", "\(error)")
    #endif
  }

  /// Helper to log a generic error to Crashlytics.
  /// - Parameters:
  ///   - originalError: Any originating error that occurred, if available.
  ///   - code: A code identifying the error situation.
  ///   - summary: Operating context to help identify where the error occurred.
  ///   - request: The request that returned the error.
  ///   - response: The response that returned the error.
  ///   - metadata: Any additional metadata to be logged.
  private class func logError(_ originalError: Error?,
                              code: TPPErrorCode = .ignore,
                              summary: String,
                              request: URLRequest? = nil,
                              response: URLResponse? = nil,
                              metadata: [String: Any]? = nil) {
    // compute metadata
    var metadata = metadata ?? [String : Any]()
    addAccountInfoToMetadata(&metadata)
    if let request = request {
      Log.error(#file, "Request \(request.loggableString) failed.")
      metadata["request"] = request.loggableString
    }
    if let response = response {
      metadata["response"] = response
    }
    if let originalError = originalError {
      Log.error(#file, "Error: \(originalError)")
      metadata[NSUnderlyingErrorKey] = originalError
    }

    // compute final summary and code, plus severity
    let (finalSummary, finalCode, severity) = fixUpSummary(summary,
                                                           code: code,
                                                           with: originalError)

    // build error report
    let userInfo = additionalInfo(severity: severity,
                                  metadata: metadata)
    let err = NSError(domain: finalSummary,
                      code: finalCode,
                      userInfo: userInfo)
    record(error: err)
  }

  /// Fixes up summary and code inspecting the domain and code of a given
  /// error, isolating error reasons that are user-dependent, such as
  /// no internet connection or other device limitations.
  /// - Parameters:
  ///   - summary: The currently proposed summary for the Crashlytics report.
  ///   - code: The currently proposed code for the Crashlytics report.
  ///   - err: The error to inspect.
  /// - Returns: A tuple with the final suggested summary and code to use
  /// to file a report on Crashlytics.
  private class func fixUpSummary(_ summary: String,
                                  code: TPPErrorCode,
                                  with err: Error?) -> (summary: String, code: Int, severity: TPPSeverity) {
    if let nserr = err as NSError? {
      if let (finalSummary, finalCode) = customSummaryAndCode(from: nserr) {
        return (summary: finalSummary, code: finalCode.rawValue, severity: .warning)
      }
    }

    let finalCode: Int
    if code != .ignore {
      finalCode = code.rawValue
    } else if let nserr = err as NSError? {
      finalCode = nserr.code
    } else {
      finalCode = TPPErrorCode.ignore.rawValue
    }

    return (summary: summary, code: finalCode, severity: .error)
  }

  /// Derive a custom summary and code to categorize certain error that are
  /// related to particular user conditions for which there's not much we can
  /// do, such as lack of internet connection or timeouts.
  /// - Parameter err: The error that was reported.
  /// - Returns: A tuple with a custom summary and code that will group these
  /// errors together on Crashlytics, separating them from the rest of "actual"
  /// errors.
  private class func customSummaryAndCode(from err: NSError) -> (summary: String, code: TPPErrorCode)? {
    let cfErrorDomainNetwork = (kCFErrorDomainCFNetwork as String)

    switch err.domain {

    case NSURLErrorDomain:
      switch err.code {
      case NSURLErrorUserCancelledAuthentication:
        return (summary: "User Cancelled Authentication", code: .clientSideUserInterruption)
      case NSURLErrorCancelled:
        return (summary: "Request Cancelled", code: .clientSideUserInterruption)
      case NSURLErrorTimedOut:
        return (summary: "Request Timeout", code: .clientSideTransientError)
      case NSURLErrorNetworkConnectionLost:
        return (summary: "Connection Lost/Severed", code: .clientSideTransientError)
      case NSURLErrorInternationalRoamingOff:
        fallthrough
      case NSURLErrorNotConnectedToInternet:
        return (summary: "No Internet Connection", code: .clientSideTransientError)
      case NSURLErrorCallIsActive:
        fallthrough
      case NSURLErrorDataNotAllowed:
        return (summary: "User Device Cannot Connect", code: .clientSideTransientError)
      default:
        break
      }

    case cfErrorDomainNetwork:
      let code = err.code

      if code == CFNetworkErrors.cfurlErrorUserCancelledAuthentication.rawValue {
        return (summary: "User Cancelled Authentication",
                code: .clientSideUserInterruption)

      } else if code == CFNetworkErrors.cfurlErrorCancelled.rawValue
        || code == CFNetworkErrors.cfNetServiceErrorCancel.rawValue {
        return (summary: "Request Cancelled",
                code: .clientSideUserInterruption)

      } else if code == CFNetworkErrors.cfurlErrorTimedOut.rawValue
        || code == CFNetworkErrors.cfNetServiceErrorTimeout.rawValue {
        return (summary: "Request Timeout",
                code: .clientSideTransientError)

      } else if code == CFNetworkErrors.cfurlErrorNetworkConnectionLost.rawValue {
        return (summary: "Connection Lost/Severed",
                code: .clientSideTransientError)

      } else if code == CFNetworkErrors.cfurlErrorNotConnectedToInternet.rawValue
        || code == CFNetworkErrors.cfurlErrorInternationalRoamingOff.rawValue {
        return (summary: "No Internet Connection",
                code: .clientSideTransientError)

      } else if code == CFNetworkErrors.cfurlErrorCallIsActive.rawValue
        || code == CFNetworkErrors.cfurlErrorDataNotAllowed.rawValue {
        return (summary: "User Device Cannot Connect", code: .clientSideTransientError)
      }

    default:
      break
    }

    return nil
  }

  /**
   Helper method for other logging functions that adds relevant library
   account info to our crash reports.
   - parameter metadata: report metadata dictionary
   */
  private class func addAccountInfoToMetadata(_ metadata: inout [String: Any]) {
    let currentLibrary = AccountsManager.shared.currentAccount
    metadata["currentAccountName"] = currentLibrary?.name ?? nullString
    metadata["currentAccountUUID"] = currentLibrary?.uuid ?? nullString
    metadata["currentAccountId (from UserDefaults)"] = AccountsManager.shared.currentAccountId ?? nullString
    metadata["currentAccountCatalogURL"] = currentLibrary?.catalogUrl ?? nullString
    metadata["currentAccountAuthDocURL"] = currentLibrary?.authenticationDocumentUrl ?? nullString
    metadata["currentAccountLoansURL"] = currentLibrary?.loansUrl ?? nullString
    metadata["currentAccountDetails"] = currentLibrary?.details?.debugDescription ?? nullString
    metadata["numAccounts"] = AccountsManager.shared.accounts().count
  }

  /// Creates a dictionary with information to be logged in relation to an event.
  /// - Parameters:
  ///   - severity: How severe the event is.
  ///   - message: An optional message.
  ///   - metadata: Any additional metadata.
  private class func additionalInfo(severity: TPPSeverity,
                                    message: String? = nil,
                                    metadata: [String: Any]? = nil) -> [String: Any] {
    var dict = metadata ?? [:]

    dict["severity"] = severity.stringValue()
    if let message = message {
      Log.error(#file, message)
      dict["message"] = message
    }

    return dict
  }
}
