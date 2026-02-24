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

    /// Prepare for app termination by clearing cached references.
    /// This helps prevent "recursive_mutex lock failed" crashes on Mac Catalyst
    /// when the FinalTerminationWatchdog forces app exit and triggers C++ static
    /// destructors while Adobe DRM objects are in an inconsistent state.
    func prepareForTermination() {
        lock.lock()
        defer { lock.unlock() }

        // Clear delegate to prevent callbacks during shutdown
        _adeptInstance?.delegate = nil

        // Clear our cached reference (doesn't destroy the underlying C++ objects,
        // but helps avoid our code interacting with them during shutdown)
        _adeptInstance = nil

        Log.info(#file, "Adobe DRM prepared for termination")
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

    // MARK: - On-Demand Activation (PP-3649)

    /// Ensures the device is activated with Adobe DRM, performing on-demand
    /// activation if needed. This is called at borrow time for Adobe DRM content
    /// instead of at login, to avoid burning activations unnecessarily.
    ///
    /// - Throws: `PalaceError.drm` if activation fails or credentials are unavailable.
    func ensureDeviceActivated() async throws {
        let userAccount = TPPUserAccount.sharedAccount()

        if let userID = userAccount.userID,
           let deviceID = userAccount.deviceID,
           isUserAuthorized(userID, deviceID: deviceID) {
            Log.info(#file, "Adobe device already activated — skipping activation")
            return
        }

        guard AdobeCertificate.isDRMAvailable else {
            Log.error(#file, "Adobe DRM not available — certificate missing or expired")
            throw PalaceError.drm(.noActivation)
        }

        guard let licensor = userAccount.licensor,
              let vendor = licensor["vendor"] as? String, !vendor.isEmpty,
              let clientToken = licensor["clientToken"] as? String, !clientToken.isEmpty else {
            Log.error(#file, "No Adobe DRM licensor credentials stored — cannot activate")
            throw PalaceError.drm(.noActivation)
        }

        var items = clientToken
            .replacingOccurrences(of: "\n", with: "")
            .components(separatedBy: "|")
        let tokenPassword = items.last
        items.removeLast()
        let tokenUsername = (items as NSArray).componentsJoined(by: "|")

        Log.info(#file, "Performing on-demand Adobe device activation for borrow")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let adept = self.adeptInstance else {
                continuation.resume(throwing: PalaceError.drm(.noActivation))
                return
            }

            adept.authorize(withVendorID: vendor,
                            username: tokenUsername,
                            password: tokenPassword) { success, error, deviceID, userID in
                if success, let userID = userID, let deviceID = deviceID {
                    Log.info(#file, "On-demand Adobe activation succeeded")
                    TPPMainThreadRun.asyncIfNeeded {
                        userAccount.setUserID(userID)
                        userAccount.setDeviceID(deviceID)
                    }
                    continuation.resume()
                } else {
                    let activationError = error ?? NSError(
                        domain: "AdobeDRM",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Adobe device activation failed"]
                    )
                    Log.error(#file, "On-demand Adobe activation failed: \(activationError.localizedDescription)")
                    TPPErrorLogger.logError(
                        withCode: .invalidLicensor,
                        summary: "On-demand Adobe device activation failed (PP-3649)",
                        metadata: ["error": activationError.localizedDescription]
                    )
                    continuation.resume(throwing: PalaceError.drm(.authenticationFailed))
                }
            }
        }
    }
}

#endif
