//
//  BookDownloadTask.swift
//  Palace
//
//  Created by Maurice Carrier on 6/19/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

struct BookDownloadTask {
  let downloadTask: URLSessionDownloadTask
  var downloadProgress: Double
  var rightsManagement: TPPMyBooksDownloadRightsManagement
  var bearerToken: MyBooksSimplifiedBearerToken?
}
