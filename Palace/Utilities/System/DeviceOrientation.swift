//
//  DeviceOrientation.swift
//  Palace
//
//  Created by Maurice Work on 2/21/25.
//  Copyright © 2025 The Palace Project. All rights reserved.
//


@MainActor
class DeviceOrientation: ObservableObject {
  @Published var isLandscape: Bool = UIDevice.current.orientation.isLandscape

  func startTracking() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(updateOrientation),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )
  }

  func stopTracking() {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func updateOrientation() {
    DispatchQueue.main.async {
      self.isLandscape = UIDevice.current.orientation.isLandscape
    }
  }
}
