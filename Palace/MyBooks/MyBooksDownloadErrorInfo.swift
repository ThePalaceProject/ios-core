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

  /// Distinguishes the operation that produced the error so subscribers
  /// can filter out errors that don't apply to their current context.
  enum ErrorKind {
    /// Error occurred during the borrow (loan acquisition) phase.
    case borrow
    /// Error occurred during the file download phase.
    case download
    /// General error not tied to a specific phase (e.g. Wi-Fi restriction).
    case general
  }

  let bookId: String
  let title: String
  let message: String
  let kind: ErrorKind
  let retryAction: (() -> Void)?

  /// Convenience for non-retryable errors.
  init(bookId: String, title: String, message: String, kind: ErrorKind = .general) {
    self.bookId = bookId
    self.title = title
    self.message = message
    self.kind = kind
    self.retryAction = nil
  }

  /// Full initializer with optional retry action.
  init(bookId: String, title: String, message: String, kind: ErrorKind = .general, retryAction: (() -> Void)?) {
    self.bookId = bookId
    self.title = title
    self.message = message
    self.kind = kind
    self.retryAction = retryAction
  }
}
