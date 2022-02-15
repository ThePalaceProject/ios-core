//
//  UINavigationBar+appearance.swift
//  Palace
//
//  Created by Vladimir Fedorov on 03.02.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import UIKit

extension UINavigationBar {
  /// Sets navigation bar appearance to all appearance properties
  /// - Parameter appearance: Navigation bar appearance
  func setAppearance(_ appearance: UINavigationBarAppearance) {
    standardAppearance = appearance
    scrollEdgeAppearance = appearance
    compactAppearance = appearance
    if #available(iOS 15.0, *) {
      compactScrollEdgeAppearance = appearance
    }
  }
}
