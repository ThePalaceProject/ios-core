//
//  BookButtonType.swift
//  Palace
//
//  Created by Maurice Carrier on 2/17/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import SwiftUI

enum BookButtonType: String {
  case get
  case reserve
  case download
  case read
  case listen
  case retry
  case cancel
  case close
  case sample
  case audiobookSample
  case remove
  case cancelHold
  case manageHold
  case `return`
  case returning

  var localizedTitle: String {
    NSLocalizedString(self.rawValue, comment: "Book Action Button title")
  }
  
  var displaysIndicator: Bool {
    switch self {
    case .read, .remove, .get, .download, .listen:
      true
    default:
      false
    }
  }
  
  var isDisabled: Bool {
    switch self {
    case .read, .listen, .remove:
      false
    default:
      !Reachability.shared.isConnectedToNetwork()
    }
  }
}

fileprivate typealias DisplayStrings = Strings.BookButton

extension BookButtonType {
  var title: String {
    switch self {
    case .get: DisplayStrings.borrow
    case .reserve: DisplayStrings.placeHold
    case .download: DisplayStrings.download
    case .return: DisplayStrings.return
    case .remove: DisplayStrings.remove
    case .read: DisplayStrings.read
    case .listen: DisplayStrings.listen
    case .cancel: DisplayStrings.cancel
    case .retry: DisplayStrings.retry
    case .sample: DisplayStrings.preview
    case .audiobookSample: DisplayStrings.preview
    case .returning: DisplayStrings.returnLoan
    case .manageHold: DisplayStrings.manageHold
    case .cancelHold: DisplayStrings.cancelHold
    case .close: DisplayStrings.close
    }
  }
  
  @MainActor
  func title(for book: TPPBook) -> String {
    switch self {
    case .sample, .audiobookSample:
      return SamplePreviewManager.shared.isShowingPreview(for: book) ? DisplayStrings.close : DisplayStrings.preview
    default:
      return title
    }
  }

  var buttonStyle: ButtonStyleType {
    switch self {
    case .sample, .audiobookSample, .close:
      .tertiary
    case .get, .reserve, .download, .read, .listen, .retry, .returning, .manageHold:
      .primary
    case .return, .cancel, .remove:
      .secondary
    case .cancelHold:
      .destructive
    }
  }

  var isPrimary: Bool {
    buttonStyle == .primary
  }

  var hasBorder: Bool {
    buttonStyle == .secondary || buttonStyle == .destructive
  }

  func buttonBackgroundColor(_ isDarkBackground: Bool) -> Color {
    switch buttonStyle {
    case .primary:
      isDarkBackground ? .white : .black
    case .secondary, .tertiary, .destructive:
      .clear
    }
  }

  func buttonTextColor(_ isDarkBackground: Bool) -> Color {
    switch buttonStyle {
    case .primary:
      isDarkBackground ? .black : .white
    case .secondary, .tertiary:
      isDarkBackground ? .white : .black
    case .destructive:
        .palaceErrorBase

    }
  }

  func borderColor(_ isDarkBackground: Bool) -> Color {
    switch buttonStyle {
    case .secondary:
      (isDarkBackground ? .white : .black)
    case .destructive:
        .palaceErrorBase
    default:
        .clear
    }
  }
}

enum ButtonStyleType {
  case primary
  case secondary
  case tertiary
  case destructive
}
