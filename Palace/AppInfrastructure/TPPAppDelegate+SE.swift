//
//  TPPAppDelegate+SE.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 9/17/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension TPPAppDelegate {
  @objc func setUpRootVC() {
    //    self.window.rootViewController = SETutorialViewController()
    window.rootViewController = TPPRootTabBarController.shared()
  }

  @objc func completeBecomingActive() {
  }

  /// Handle all custom URL schemes specific to SimplyE here.
  /// - Parameter url: The URL to process
  /// - Returns: `true` if the app should handle the URL because it matches a
  /// custom URL scheme we're registered to.
  @objc(shouldHandleAppSpecificCustomURLSchemesForURL:)
  func shouldHandleAppSpecificCustomURLSchemes(for url: URL) -> Bool {
    return false
  }
}
