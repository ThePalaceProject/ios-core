//
//  AdobeDRMAlerts.swift
//  Palace
//
//  Created by Vladimir Fedorov on 16.12.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation

extension TPPAlertUtils {
  @objc class func expiredAdobeDRMAlert() -> UIAlertController {
    return TPPAlertUtils.alert(
      title: NSLocalizedString("Something went wrong with the Adobe DRM system", comment: "Expired DRM certificate title"),
      message: NSLocalizedString("Some books will be unavailable in this version. Please try updating to the latest version of the application.", comment: "Expired DRM certificate message")
    )
  }
}
