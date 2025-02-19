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
    compactScrollEdgeAppearance = appearance
  }

  /// Updatign the appearance of the navbar, when presented, will not cause the changes to propogage.
  /// Calling this function will trigger the view to redraw itself, forcing an appearance update
  func forceUpdateAppearance(style: UIUserInterfaceStyle) {
    _ = UIApplication.shared.windows.compactMap { window in
      for view in window.subviews {
        view.removeFromSuperview()
        window.addSubview(view)
        window.overrideUserInterfaceStyle = style
      }
    }
  }
}
