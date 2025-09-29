//
//  LocationManager.swift
//  Palace
//
//  Created by Maurice Carrier on 6/6/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import CoreLocation

extension Notification.Name {
  static let locationAuthorizationDidChange = Notification.Name("LocationAuthorizationDidChange")
}

// MARK: - LocationManager

class LocationManager: NSObject, CLLocationManagerDelegate {
  static let shared = LocationManager()
  private let locationManager = CLLocationManager()

  override private init() {
    super.init()
    locationManager.delegate = self
  }

  var locationAccessAuthorized: Bool {
    let status = locationManager.authorizationStatus
    return status == .authorizedAlways || status == .authorizedWhenInUse
  }

  var locationAccessDenied: Bool {
    let status = locationManager.authorizationStatus
    return status == .denied
  }

  func locationManagerDidChangeAuthorization(_: CLLocationManager) {
    NotificationCenter.default.post(name: .locationAuthorizationDidChange, object: nil)
  }
}
