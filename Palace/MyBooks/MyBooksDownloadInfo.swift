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
  
  init(downloadProgress: CGFloat, downloadTask: URLSessionDownloadTask, rightsManagement: MyBooksDownloadRightsManagement, bearerToken: MyBooksSimplifiedBearerToken? = nil) {
    self.downloadProgress = downloadProgress
    self.downloadTask = downloadTask
    self.rightsManagement = rightsManagement
    self.bearerToken = bearerToken
  }
  
  func withDownloadProgress(_ downloadProgress: CGFloat) -> MyBooksDownloadInfo {
    return MyBooksDownloadInfo(downloadProgress: downloadProgress, downloadTask: self.downloadTask, rightsManagement: self.rightsManagement, bearerToken: self.bearerToken)
  }
  
  func withRightsManagement(_ rightsManagement: MyBooksDownloadRightsManagement) -> MyBooksDownloadInfo {
    return MyBooksDownloadInfo(downloadProgress: self.downloadProgress, downloadTask: self.downloadTask, rightsManagement: rightsManagement, bearerToken: self.bearerToken)
  }
  
  var rightsManagementString: String {
    switch rightsManagement {
    case .unknown:
      return "Unknown"
    case .none:
      return "None"
    case .adobe:
      return "Adobe"
    case .simplifiedBearerTokenJSON:
      return "SimplifiedBearerTokenJSON"
    case .overdriveManifestJSON:
      return "OverdriveManifestJSON"
    case .lcp:
      return "TPPMyBooksDownloadRightsManagementLCP"
    }
  }
}
