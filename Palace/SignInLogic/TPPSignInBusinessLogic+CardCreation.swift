//
//  TPPSignInBusinessLogic+CardCreation.swift
//  Palace
//
//  Created by Vladimir Fedorov on 07.04.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import CoreLocation
import Foundation
import SafariServices

extension TPPSignInBusinessLogic: CLLocationManagerDelegate {
  @objc
  func startRegularCardCreation(completion: @escaping (UINavigationController?, Error?) -> Void) {
    // Ensure we have a sign-up URL to work with.
    guard let signUpURL = libraryAccount?.details?.signUpUrl else {
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
    guard let userLocation = locationManager.location else {
      return nil
    }

    let latitude = userLocation.coordinate.latitude
    let longitude = userLocation.coordinate.longitude
    let urlString = "\(baseURL)/?lat=\(latitude)&long=\(longitude)"
    return URL(string: urlString)
  }

  // This delegate method is called when the authorization status changes.
  func locationManagerDidChangeAuthorization(_: CLLocationManager) {
    let status = CLLocationManager.authorizationStatus()
    if status == .authorizedWhenInUse || status == .authorizedAlways {
      startRegularCardCreation(completion: onLocationAuthorizationCompletion)
    }
  }
}
