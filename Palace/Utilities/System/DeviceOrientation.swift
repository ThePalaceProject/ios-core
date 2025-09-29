//
//  DeviceOrientation.swift
//  Palace
//
//  Created by Maurice Work on 2/21/25.
//  Copyright © 2025 The Palace Project. All rights reserved.
//

@MainActor
class DeviceOrientation: ObservableObject {
  @Published var isLandscape: Bool = {
    let screenWidth = UIScreen.main.bounds.width
    let screenHeight = UIScreen.main.bounds.height
    return screenWidth > screenHeight
  }()

  func startTracking() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(updateOrientation),
      name: UIApplication.didChangeStatusBarOrientationNotification,
      object: nil
    )
  }

  func stopTracking() {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func updateOrientation() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      let screenWidth = UIScreen.main.bounds.width
      let screenHeight = UIScreen.main.bounds.height
      let newIsLandscape = screenWidth > screenHeight

      if self.isLandscape != newIsLandscape {
        self.isLandscape = newIsLandscape
      }
    }
  }
}
