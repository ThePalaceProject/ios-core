//
//  TPPPDFToolbarButton.swift
//  Palace
//
//  Created by Vladimir Fedorov on 04.07.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import PalaceUIKit
import SwiftUI

// MARK: - TPPPDFToolbarButton

/// Preconfigured toolbar button view
struct TPPPDFToolbarButton: View {
  let action: () -> Void
  let image: Image?
  let text: String?

  init(icon: String, action: @escaping () -> Void) {
    self.action = action
    image = Image(systemName: icon)
    text = nil
  }

  init(text: String, action: @escaping () -> Void) {
    self.action = action
    image = nil
    self.text = text
  }

  var body: some View {
    Button(action: action) {
      if let image = image {
        image
      }
      if let text = text {
        Text(text)
          .palaceFont(.body)
      }
    }
    .toolbarButtonSize()
  }
}

// MARK: - ToolbarButton_Previews

struct ToolbarButton_Previews: PreviewProvider {
  static var previews: some View {
    TPPPDFToolbarButton(text: "Hello") {
      //
    }
  }
}
