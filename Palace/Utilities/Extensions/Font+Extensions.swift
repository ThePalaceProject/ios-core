//
//  Font+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 12/5/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation
import SwiftUI

extension Font {
  init(uiFont: UIFont) {
    self = Font(uiFont as CTFont)
  }
}

extension Font {
  static func palaceFont(size: CGFloat) -> Font {
    Font.custom(TPPConfiguration.systemFontName(), size: size)
  }

  static func semiBoldPalaceFont(size: CGFloat) -> Font {
    Font.custom(TPPConfiguration.semiBoldSystemFontName(), size: size)
  }

  static func boldPalaceFont(size: CGFloat) -> Font {
    Font.custom(TPPConfiguration.boldSystemFontName(), size: size)
  }
}
