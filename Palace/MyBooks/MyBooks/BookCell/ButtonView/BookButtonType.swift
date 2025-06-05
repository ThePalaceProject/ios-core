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
      return true
    default:
      return false
    }
  }
  
  var isDisabled: Bool {
    switch self {
    case .read, .listen, .remove:
      return false
    default:
      return !Reachability.shared.isConnectedToNetwork()
    }
  }
}

fileprivate typealias DisplayStrings = Strings.BookButton

extension BookButtonType {
  var title: String {
    switch self {
    case .get: return DisplayStrings.borrow
    case .reserve: return DisplayStrings.placeHold
    case .download: return DisplayStrings.download
    case .return: return DisplayStrings.return
    case .remove: return DisplayStrings.remove
    case .read: return DisplayStrings.read
    case .listen: return DisplayStrings.listen
    case .cancel: return DisplayStrings.cancel
    case .retry: return DisplayStrings.retry
    case .sample, .audiobookSample: return DisplayStrings.preview
    case .returning: return DisplayStrings.returnLoan
    case .manageHold: return DisplayStrings.manageHold
    case .cancelHold: return DisplayStrings.cancelHold
    case .close: return DisplayStrings.close
    }
  }

  var buttonStyle: ButtonStyleType {
    switch self {
    case .sample, .audiobookSample, .close:
      return .tertiary
    case .get, .reserve, .download, .read, .listen, .retry, .returning, .manageHold:
      return .primary
    case .return, .cancel, .remove, .cancelHold:
      return .secondary
    }
  }

  var isPrimary: Bool {
    return buttonStyle == .primary
  }

  var hasBorder: Bool {
    return buttonStyle == .secondary
  }

  func buttonBackgroundColor(_ isDarkBackground: Bool) -> Color {
    switch buttonStyle {
    case .primary:
      return isDarkBackground ? .white : .black
    case .secondary, .tertiary:
      return .clear
    }
  }

  func buttonTextColor(_ isDarkBackground: Bool) -> Color {
    switch buttonStyle {
    case .primary:
      return isDarkBackground ? .black : .white
    case .secondary, .tertiary:
      return isDarkBackground ? .white : .black
    }
  }

  func borderColor(_ isDarkBackground: Bool) -> Color {
    return hasBorder ? (isDarkBackground ? .white : .black) : .clear
  }
}

enum ButtonStyleType {
  case primary
  case secondary
  case tertiary
}
