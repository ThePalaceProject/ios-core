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
  /// The entry point to the regular card creation flow.
  /// - Parameters:
  ///   - completion: Always called whether the library supports
  ///   card creation or not. If it's possible, the handler returns
  ///   a navigation controller containing the VCs for the whole flow.
  ///   All the client has to do is to present this navigation controller
  ///   in whatever way it sees fit.
  @objc
  func startRegularCardCreation(completion: @escaping (UINavigationController?, Error?) -> Void) {
    // If the library does not have a sign-up url, there's nothing we can do
    guard let signUpURL = libraryAccount?.details?.signUpUrl else {
      let error = NSError(
        domain: TPPErrorLogger.clientDomain,
        code: TPPErrorCode.nilSignUpURL.rawValue,
        userInfo: [NSLocalizedDescriptionKey: Strings.Error.cardCreationError]
      )
      completion(nil, error)
      return
    }

    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
    
    switch CLLocationManager.authorizationStatus() {
    case .authorizedWhenInUse, .authorizedAlways:
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
      let webVC = RemoteHTMLViewController(URL: url,
                                           title: title,
                                           failureMessage: msg)
      completion(UINavigationController(rootViewController: webVC), nil)

    case .notDetermined:
      locationManager.requestWhenInUseAuthorization()
      locationManager.delegate = self
      self.onLocationAuthorizationCompletion = completion
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

  private func addLocationInformation(baseURL: String, locationManager: CLLocationManager) -> URL? {
    guard let userLocation = locationManager.location else {
      return nil
    }
  
    let latitude = userLocation.coordinate.latitude
    let longitude = userLocation.coordinate.longitude
    let urlString = "\(baseURL)/?lat=\(latitude)&long=\(longitude)"
    
    guard let url = URL(string: urlString) else {
      return nil
    }
  
    return url
  }
  
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    startRegularCardCreation(completion: onLocationAuthorizationCompletion)
  }
}
