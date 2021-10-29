//
//  View+Extensions.swift
//  Palace
//
//  Created by Maurice Work on 10/28/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import SwiftUI
import UIKit

extension View {
  func anyView() -> AnyView {
    AnyView(self)
  }

  func foregroundColor(_ color: UIColor) -> some View {
    foregroundColor(Color(color))
  }

  func asPlainButton(action: @escaping Action) -> some View {
    let button = Button(action: action) {
      self
    }
    .buttonStyle(PlainButtonStyle())
    
    return button.anyView()
  }
}

