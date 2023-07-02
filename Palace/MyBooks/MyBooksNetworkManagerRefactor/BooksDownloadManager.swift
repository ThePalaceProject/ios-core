//
//  BooksDownloadManager.swift
//  Palace
//
//  Created by Maurice Carrier on 6/19/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

protocol BooksDownloadManager {
  var delegate: BooksNetworkManagerDelegate? { get set }
  
  func startDownload(for book: TPPBook)
  func pauseDownload(for book: TPPBook)
  func cancelDownload(for book: TPPBook)
  func resumeDownload(for book: TPPBook)
  func persistDownloadState()
  func restoreDownloadState()
}
