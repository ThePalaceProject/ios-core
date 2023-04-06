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

//extension TPPSignInBusinessLogic {
//  /// The entry point to the regular card creation flow.
//  /// - Parameters:
//  ///   - completion: Always called whether the library supports
//  ///   card creation or not. If it's possible, the handler returns
//  ///   a navigation controller containing the VCs for the whole flow.
//  ///   All the client has to do is to present this navigation controller
//  ///   in whatever way it sees fit.
//  @objc
//  func startRegularCardCreation(completion: @escaping (UINavigationController?, Error?) -> Void) {
//      // If the library does not have a sign-up url, there's nothing we can do
//      guard let signUpURL = libraryAccount?.details?.signUpUrl else {
//          let description = Strings.Error.cardCreationError
//          let error = NSError(domain: TPPErrorLogger.clientDomain,
//                              code: TPPErrorCode.nilSignUpURL.rawValue,
//                              userInfo: [
//                                  NSLocalizedDescriptionKey: description
//                              ])
//          TPPErrorLogger.logError(withCode: .nilSignUpURL,
//                                  summary: "SignUp Error in Settings: nil signUp URL",
//                                  metadata: [
//                                      "libraryAccountUUID": libraryAccountID,
//                                      "libraryAccountName": libraryAccount?.name ?? "N/A"
//                                  ])
//          completion(nil, error)
//          return
//      }
//
//      let title = Strings.TPPSigninBusinessLogic.ecard
//      let msg = Strings.TPPSigninBusinessLogic.ecardErrorMessage
//
//      let locationManager = CLLocationManager()
//      locationManager.desiredAccuracy = kCLLocationAccuracyBest
//
//      switch CLLocationManager.authorizationStatus() {
//      case .authorizedWhenInUse, .authorizedAlways:
//          // Get the user's current location
//          if let urlWithLocation = addLocationInformation(baseURL: signUpURL.absoluteString, locationManager: locationManager) {
//              let webVC = SFSafariViewController(url: urlWithLocation)
//              webVC.preferredControlTintColor = UIColor.clear
//              webVC.modalPresentationCapturesStatusBarAppearance = true
//              completion(UINavigationController(rootViewController: webVC), nil)
//          } else {
//              let error = NSError(domain: TPPErrorLogger.clientDomain,
//                                  code: TPPErrorCode.failedToGetLocation.rawValue,
//                                  userInfo: [
//                                      NSLocalizedDescriptionKey: "Failed to get user location"
//                                  ])
//              completion(nil, error)
//          }
//      case .notDetermined:
//          locationManager.requestWhenInUseAuthorization()
//      case .restricted, .denied:
//          let error = NSError(domain: TPPErrorLogger.clientDomain,
//                              code: TPPErrorCode.locationAccessDenied.rawValue,
//                              userInfo: [
//                                  NSLocalizedDescriptionKey: "User denied location access"
//                              ])
//          completion(nil, error)
//      @unknown default:
//          let error = NSError(domain: TPPErrorLogger.clientDomain,
//                              code: TPPErrorCode.unknownLocationError.rawValue,
//                              userInfo: [
//                                  NSLocalizedDescriptionKey: "Unknown location error"
//                              ])
//          completion(nil, error)
//      }
//  }
//
//  private func addLocationInformation(baseURL: String, locationManager: CLLocationManager) -> URL? {
//      // Get the user's current location
//      guard let userLocation = locationManager.location else {
//          return nil
//      }
//
//      // Build the URL with the location information
//      let latitude = userLocation.coordinate.latitude
//      let longitude = userLocation.coordinate.longitude
//      let urlString = "\(baseURL)/?lat=\(latitude)&long=\(longitude)"
//
//      return URL(string: urlString)
//  }
//}
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
      let description = Strings.Error.cardCreationError
      let error = NSError(domain: TPPErrorLogger.clientDomain,
                          code: TPPErrorCode.nilSignUpURL.rawValue,
                          userInfo: [
                            NSLocalizedDescriptionKey: description
                          ])
      TPPErrorLogger.logError(withCode: .nilSignUpURL,
                              summary: "SignUp Error in Settings: nil signUp URL",
                              metadata: [
                                "libraryAccountUUID": libraryAccountID,
                                "libraryAccountName": libraryAccount?.name ?? "N/A"
                              ])
      completion(nil, error)
      return
    }

    let locationManager = CLLocationManager()
    locationManager.delegate = self
    locationManager.desiredAccuracy = kCLLocationAccuracyBest
    
    switch CLLocationManager.authorizationStatus() {
    case .authorizedWhenInUse, .authorizedAlways:
      // Get the user's current location
      addLocationInformation(baseURL: signUpURL.absoluteString, locationManager: locationManager) { result in
        switch result {
        case .success(let url):
          let webVC = SFSafariViewController(url: url)
          webVC.preferredControlTintColor = UIColor.clear
          webVC.modalPresentationCapturesStatusBarAppearance = true
          completion(UINavigationController(rootViewController: webVC), nil)
        case .failure(let error):
          completion(nil, error)
        }
      }
    case .notDetermined:
      locationManager.requestWhenInUseAuthorization()
      locationManager.delegate = self
      self.onLocationAuthorizationCompletion = completion
    case .restricted, .denied:
      let error = NSError(domain: TPPErrorLogger.clientDomain,
                          code: TPPErrorCode.locationAccessDenied.rawValue,
                          userInfo: [
                            NSLocalizedDescriptionKey: "User denied location access"
                          ])
      completion(nil, error)
    @unknown default:
      let error = NSError(domain: TPPErrorLogger.clientDomain,
                          code: TPPErrorCode.unknownLocationError.rawValue,
                          userInfo: [
                            NSLocalizedDescriptionKey: "Unknown location error"
                          ])
      completion(nil, error)
    }
  }

  private func addLocationInformation(baseURL: String, locationManager: CLLocationManager, completion: @escaping (Result<URL, Error>) -> Void) {
    guard let userLocation = locationManager.location else {
      let error = NSError(domain: TPPErrorLogger.clientDomain,
                          code: TPPErrorCode.locationAccessDenied.rawValue,
                          userInfo: [
                            NSLocalizedDescriptionKey: "Location services are disabled"
                          ])
      completion(.failure(error))
      return
    }
    
    let latitude = userLocation.coordinate.latitude
    let longitude = userLocation.coordinate.longitude
    let urlString = "\(baseURL)/?lat=\(latitude)&long=\(longitude)"
    
    guard let url = URL(string: urlString) else {
      let error = NSError(domain: TPPErrorLogger.clientDomain,
                          code: TPPErrorCode.responseFail.rawValue,
                          userInfo: [
                            NSLocalizedDescriptionKey: "Invalid URL"
                          ])
      completion(.failure(error))
      return
    }
    
    completion(.success(url))
  }
  
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    startRegularCardCreation(completion: onLocationAuthorizationCompletion)
  }
}
