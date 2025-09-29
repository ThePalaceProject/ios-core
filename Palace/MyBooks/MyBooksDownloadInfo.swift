//
//  MyBooksDownloadInfo.swift
//  Palace
//
//  Created by Maurice Carrier on 6/13/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

@objc class MyBooksDownloadInfo: NSObject {
  @objc enum MyBooksDownloadRightsManagement: Int {
    case unknown
    case none
    case adobe
    case simplifiedBearerTokenJSON
    case overdriveManifestJSON
    case lcp
  }

  var downloadProgress: CGFloat
  var downloadTask: URLSessionDownloadTask
  @objc var rightsManagement: MyBooksDownloadRightsManagement
  var bearerToken: MyBooksSimplifiedBearerToken?

  init(
    downloadProgress: CGFloat,
    downloadTask: URLSessionDownloadTask,
    rightsManagement: MyBooksDownloadRightsManagement,
    bearerToken: MyBooksSimplifiedBearerToken? = nil
  ) {
    self.downloadProgress = downloadProgress
    self.downloadTask = downloadTask
    self.rightsManagement = rightsManagement
    self.bearerToken = bearerToken
  }

  func withDownloadProgress(_ downloadProgress: CGFloat) -> MyBooksDownloadInfo {
    MyBooksDownloadInfo(
      downloadProgress: downloadProgress,
      downloadTask: downloadTask,
      rightsManagement: rightsManagement,
      bearerToken: bearerToken
    )
  }

  func withRightsManagement(_ rightsManagement: MyBooksDownloadRightsManagement) -> MyBooksDownloadInfo {
    MyBooksDownloadInfo(
      downloadProgress: downloadProgress,
      downloadTask: downloadTask,
      rightsManagement: rightsManagement,
      bearerToken: bearerToken
    )
  }

  var rightsManagementString: String {
    switch rightsManagement {
    case .unknown:
      "Unknown"
    case .none:
      "None"
    case .adobe:
      "Adobe"
    case .simplifiedBearerTokenJSON:
      "SimplifiedBearerTokenJSON"
    case .overdriveManifestJSON:
      "OverdriveManifestJSON"
    case .lcp:
      "TPPMyBooksDownloadRightsManagementLCP"
    }
  }
}
