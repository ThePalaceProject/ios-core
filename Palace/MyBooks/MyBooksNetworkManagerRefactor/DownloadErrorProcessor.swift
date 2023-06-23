//
//  DownloadErrorProcessor.swift
//  Palace
//
//  Created by Maurice Carrier on 6/19/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

class DownloadErrorProcessor {
  func processError(_ error: BookDownloadError) {
    switch error {
    case .invalidURL:
      handleInvalidURLError()
    case .networkError(let underlyingError):
      handleNetworkError(underlyingError)
    case .fileSystemError(let underlyingError):
      handleFileSystemError(underlyingError)
    }
  }
  
  private func handleInvalidURLError() {
    // Handle the specific actions or UI updates for an invalid URL error
    print("Invalid URL error occurred")
  }
  
  private func handleNetworkError(_ error: Error) {
    // Handle the specific actions or UI updates for a network error
    print("Network error occurred: \(error.localizedDescription)")
  }
  
  private func handleFileSystemError(_ error: Error) {
    // Handle the specific actions or UI updates for a file system error
    print("File system error occurred: \(error.localizedDescription)")
  }
}
