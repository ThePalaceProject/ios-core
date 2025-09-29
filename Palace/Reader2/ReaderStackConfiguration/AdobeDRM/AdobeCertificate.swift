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

  /// Default certificate for Palace app.
  @objc static var defaultCertificate: AdobeCertificate? = {
    let bundle: Bundle = (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil) ?
      Bundle(for: TPPAppDelegate.self) : Bundle.main
    guard let adobeCertUrl = bundle.url(forResource: "ReaderClientCert", withExtension: "sig"),
          let adobeCertData = try? Data(contentsOf: adobeCertUrl),
          !adobeCertData.isEmpty
    else {
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

#endif
