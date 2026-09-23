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

// `@unchecked Sendable`: the type has no mutable stored state — `locationManager`
// is an immutable `let` set once in `init`; the computed properties only read
// `authorizationStatus`. Safe to share the `.shared` singleton across isolation
// domains.
final class LocationManager: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = LocationManager()
    private let locationManager = CLLocationManager()

    private override init() {
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

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        NotificationCenter.default.post(name: .locationAuthorizationDidChange, object: nil)
    }
}
