//
//  TPPSignInBusinessLogic+CardCreation.swift
//  Palace
//
//  Created by Vladimir Fedorov on 07.04.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import CoreLocation
import SafariServices

extension TPPSignInBusinessLogic: CLLocationManagerDelegate {
    @objc
    func startRegularCardCreation(completion: @escaping (UINavigationController?, Error?) -> Void) {
        // Bucket A migration: card creation is user-initiated (Sign Up button
        // tap), so the await window is acceptable. Per contract: wrap in
        // `Task` because the enclosing `@objc` signature is sync. The await
        // blocks until details are loaded or the auth doc fetch fails; on
        // failure we surface the same `nilSignUpURL` error the legacy
        // `details?.signUpUrl == nil` path produced.
        guard let account = libraryAccount else {
            let error = NSError(
                domain: TPPErrorLogger.clientDomain,
                code: TPPErrorCode.nilSignUpURL.rawValue,
                userInfo: [NSLocalizedDescriptionKey: Strings.Error.cardCreationError]
            )
            completion(nil, error)
            return
        }
        Task {
            let details = try? await account.awaitReady()
            // Hop to main via the file's existing `TPPMainThreadRun.asyncIfNeeded`
            // (a plain, non-`@Sendable` closure) rather than `await MainActor.run
            // { … self … }`, which captures non-Sendable `self`/`details`/
            // `completion` in a `@Sendable` body and trips the `targeted`
            // concurrency diagnostic. This is the last statement in the Task, so
            // there is no ordering dependency on the hop completing.
            TPPMainThreadRun.asyncIfNeeded {
                self.continueRegularCardCreation(with: details, completion: completion)
            }
        }
    }

    /// Sync continuation of `startRegularCardCreation` invoked from a Task
    /// once `awaitReady()` resolves (or fails). Splitting the sync body
    /// out keeps the existing location-manager flow intact and isolated
    /// from the await boundary.
    private func continueRegularCardCreation(
        with details: AccountDetails?,
        completion: @escaping (UINavigationController?, Error?) -> Void
    ) {
        guard let signUpURL = details?.signUpUrl else {
            let error = NSError(
                domain: TPPErrorLogger.clientDomain,
                code: TPPErrorCode.nilSignUpURL.rawValue,
                userInfo: [NSLocalizedDescriptionKey: Strings.Error.cardCreationError]
            )
            completion(nil, error)
            return
        }

        // Configure location manager.
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest

        // Check the current authorization status.
        switch CLLocationManager.authorizationStatus() {
        case .authorizedWhenInUse, .authorizedAlways:
            createCard(with: signUpURL, completion: completion)
        case .notDetermined:
            // Store the completion to be used when the user grants permission.
            onLocationAuthorizationCompletion = completion
            locationManager.requestWhenInUseAuthorization()
        case .restricted, .denied:
            let error = NSError(
                domain: TPPErrorLogger.clientDomain,
                code: TPPErrorCode.locationAccessDenied.rawValue,
                userInfo: [NSLocalizedDescriptionKey: Strings.Error.userDeniedLocationAccess]
            )
            completion(nil, error)
        @unknown default:
            let error = NSError(
                domain: TPPErrorLogger.clientDomain,
                code: TPPErrorCode.unknownLocationError.rawValue,
                userInfo: [NSLocalizedDescriptionKey: Strings.Error.unknownRequestError]
            )
            completion(nil, error)
        }
    }

    // Helper method to create the card once a valid location is available.
    private func createCard(with signUpURL: URL, completion: @escaping (UINavigationController?, Error?) -> Void) {
        guard let url = addLocationInformation(baseURL: signUpURL.absoluteString, locationManager: locationManager) else {
            let error = NSError(
                domain: TPPErrorLogger.clientDomain,
                code: TPPErrorCode.failedToGetLocation.rawValue,
                userInfo: [NSLocalizedDescriptionKey: Strings.Error.locationFetchFailed]
            )
            completion(nil, error)
            return
        }

        let title = Strings.TPPSigninBusinessLogic.ecard
        let msg = Strings.TPPSigninBusinessLogic.ecardErrorMessage
        let webVC = RemoteHTMLViewController(URL: url, title: title, failureMessage: msg)
        completion(UINavigationController(rootViewController: webVC), nil)
    }

    // Adds latitude and longitude parameters to the URL.
    private func addLocationInformation(baseURL: String, locationManager: CLLocationManager) -> URL? {
        guard let userLocation = locationManager.location else { return nil }

        let latitude = userLocation.coordinate.latitude
        let longitude = userLocation.coordinate.longitude
        let urlString = "\(baseURL)/?lat=\(latitude)&long=\(longitude)"
        return URL(string: urlString)
    }

    // This delegate method is called when the authorization status changes.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = CLLocationManager.authorizationStatus()
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            startRegularCardCreation(completion: onLocationAuthorizationCompletion)
        }
    }
}
