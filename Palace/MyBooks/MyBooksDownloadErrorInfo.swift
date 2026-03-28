//
//  MyBooksDownloadErrorInfo.swift
//  Palace
//
//  Extracted from MyBooksDownloadCenter.swift — Phase 3 decomposition.
//  Provides the DownloadErrorInfo value type published when a download
//  or borrow error occurs.
//
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

/// Info published when a download or borrow error occurs.
/// Includes retry support so SwiftUI views can offer a "Retry" button.
struct DownloadErrorInfo {
  let bookId: String
  let title: String
  let message: String
  let retryAction: (() -> Void)?

  /// Convenience for non-retryable errors.
  init(bookId: String, title: String, message: String) {
    self.bookId = bookId
    self.title = title
    self.message = message
    self.retryAction = nil
  }

  /// Full initializer with optional retry action.
  init(bookId: String, title: String, message: String, retryAction: (() -> Void)?) {
    self.bookId = bookId
    self.title = title
    self.message = message
    self.retryAction = retryAction
  }
}
