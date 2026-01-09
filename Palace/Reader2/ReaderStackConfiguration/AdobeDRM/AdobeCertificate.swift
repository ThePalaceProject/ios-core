//
//  AdobeCertificate.swift
//  Palace
//
//  Created by Vladimir Fedorov on 04.08.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

#if FEATURE_DRM_CONNECTOR

import Foundation

/// Adobe DRM Certificate structure.
///
/// Includes only fields Palace checks to verify the certificate is not expired.
@objc class AdobeCertificate: NSObject, Codable {
  
  /// Certificate expiration date, seconds since UNIX epoch.
  ///
  /// This field is not present in production certificates.
  let expireson: UInt?
  
  /// Initializes certificate data
  init(expireson: UInt?) {
    self.expireson = expireson
  }
}

extension AdobeCertificate {
  
  /// Certificate expiration date.
  @objc var expirationDate: Date? {
    guard let expireson = expireson else {
      return nil
    }
    return Date(timeIntervalSince1970: Double(expireson))
  }
  
  /// Returns `true` if certificate has already expired.
  ///
  /// If expiration date is not present in certificate data, returns `false`
  @objc var hasExpired: Bool {
    guard let expirationDate = expirationDate else {
      return false
    }
    return expirationDate.timeIntervalSinceNow <= 0
  }
    
  /// Safely checks if DRM is available and certificate is valid.
  /// Use this before attempting any DRM operations.
  @objc static var isDRMAvailable: Bool {
    guard let cert = defaultCertificate else {
      return false
    }
    return !cert.hasExpired
  }
    
  /// Default certificate for Palace app.
  @objc static var defaultCertificate: AdobeCertificate? = {
    let bundle: Bundle = (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil) ? Bundle(for: TPPAppDelegate.self) : Bundle.main
    guard let adobeCertUrl = bundle.url(forResource: "ReaderClientCert", withExtension: "sig"),
          let adobeCertData = try? Data(contentsOf: adobeCertUrl),
          !adobeCertData.isEmpty else {
      return nil
    }
    return AdobeCertificate(data: adobeCertData)
  }()

  /// Initialise with Adobe DRM certificate data.
  /// - Parameter data: `ReaderClientCert.sig` data.
  @objc convenience init?(data: Data) {
    if let cert = try? JSONDecoder().decode(AdobeCertificate.self, from: data) {
      self.init(expireson: cert.expireson)
    } else {
      return nil
    }
  }
  
  /// Period of notification for expired Adobe DRM certificate
  fileprivate static let notificationPeriod: TimeInterval = 60 * 60
  
  /// Last expired DRM certificate notification date
  fileprivate static var notificationDate: Date?

  /// Returns true every `notificationPeriod` time interval.
  ///
  /// Used to avoid showing expiration message every time the user opens the app with expired certificate.
  @objc static var shouldNotifyAboutExpiration: Bool {
    if let notificationDate = notificationDate, -notificationDate.timeIntervalSinceNow < notificationPeriod {
      return false
    } else {
      notificationDate = Date()
      return true
    }
  }
  
}

// MARK: - Safe DRM Access

/// Provides thread-safe access to Adobe DRM functionality.
/// Wraps NYPLADEPT.sharedInstance() with defensive error handling to prevent crashes.
/// Note: Named AdobeDRMService to avoid conflict with Obj-C AdobeDRMContainer (the decryption container)
@objcMembers
class AdobeDRMService: NSObject {
  
  /// Singleton for safe DRM access
  static let shared = AdobeDRMService()
  
  /// Lock for thread-safe singleton access
  private let lock = NSLock()
  
  /// Cached reference to NYPLADEPT instance
  private var _adeptInstance: NYPLADEPT?
  
  /// Flag to track if initialization has been attempted
  private var initializationAttempted = false
  
  /// Flag to track if initialization failed
  private var initializationFailed = false
  
  private override init() {
    super.init()
  }
  
  /// Safely get the NYPLADEPT shared instance.
  /// Returns nil if DRM is not available or initialization fails.
  var adeptInstance: NYPLADEPT? {
    lock.lock()
    defer { lock.unlock() }
    
    // Return cached instance if available
    if let instance = _adeptInstance {
      return instance
    }
    
    // Don't retry if initialization already failed
    if initializationFailed {
      return nil
    }
    
    // Check DRM availability before attempting access
    guard AdobeCertificate.isDRMAvailable else {
      Log.info(#file, "Adobe DRM not available - certificate missing or expired")
      initializationFailed = true
      return nil
    }
    
    // Attempt to get the shared instance safely
    initializationAttempted = true
    
    // Access the shared instance - this can crash with EXC_BREAKPOINT
    // if the Adobe DRM library fails to initialize properly
    _adeptInstance = NYPLADEPT.sharedInstance()
    
    if _adeptInstance == nil {
      Log.error(#file, "Failed to initialize Adobe DRM - NYPLADEPT.sharedInstance() returned nil")
      initializationFailed = true
    }
    
    return _adeptInstance
  }
  
  /// Safely check if a user is authorized for DRM content.
  /// Returns false if DRM is not available.
  func isUserAuthorized(_ userID: String?, deviceID: String?) -> Bool {
    guard let adept = adeptInstance,
          let userID = userID,
          let deviceID = deviceID else {
      return false
    }
    return adept.isUserAuthorized(userID, withDevice: deviceID)
  }
  
  /// Safely set the delegate for DRM callbacks.
  func setDelegate(_ delegate: NYPLADEPTDelegate?) {
    guard let adept = adeptInstance else {
      Log.warn(#file, "Cannot set DRM delegate - Adobe DRM not available")
      return
    }
    adept.delegate = delegate
  }
  
  /// Check if DRM is ready for use
  var isReady: Bool {
    return adeptInstance != nil
  }
  
  /// Safely cancel a DRM fulfillment operation.
  func cancelFulfillment(withTag tag: String) {
    guard let adept = adeptInstance else {
      Log.warn(#file, "Cannot cancel DRM fulfillment - Adobe DRM not available")
      return
    }
    adept.cancelFulfillment(withTag: tag)
  }
  
  /// Safely return a DRM loan.
  func returnLoan(_ fulfillmentId: String?,
                        userID: String?,
                        deviceID: String?,
                        completion: @escaping (Bool, Error?) -> Void) {
    guard let adept = adeptInstance else {
      Log.warn(#file, "Cannot return DRM loan - Adobe DRM not available")
      completion(false, NSError(domain: "AdobeDRM", code: -1, userInfo: [NSLocalizedDescriptionKey: "Adobe DRM not available"]))
      return
    }
    adept.returnLoan(fulfillmentId, userID: userID, deviceID: deviceID, completion: completion)
  }
  
  /// Safely fulfill a DRM-protected download.
  func fulfill(withACSMData acsmData: Data,
                     tag: String,
                     userID: String?,
                     deviceID: String?) {
    guard let adept = adeptInstance else {
      Log.error(#file, "Cannot fulfill DRM content - Adobe DRM not available")
      return
    }
    adept.fulfill(withACSMData: acsmData, tag: tag, userID: userID, deviceID: deviceID)
  }
}

#endif
