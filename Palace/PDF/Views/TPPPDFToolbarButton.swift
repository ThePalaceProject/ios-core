//
//  TPPPDFToolbarButton.swift
//  Palace
//
//  Created by Vladimir Fedorov on 04.07.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// Preconfigured toolbar button view
struct TPPPDFToolbarButton: View {

  let action: () -> Void
  let image: Image?
  let text: String?
  
  init(icon: String, action: @escaping () -> Void) {
    self.action = action
    self.image = Image(systemName: icon)
    self.text = nil
  }
  
  init(text: String, action: @escaping () -> Void) {
    self.action = action
    self.image = nil
    self.text = text
  }
  
  var body: some View {
    Button(action: action) {
      if let image = image {
        image
      }
      if let text = text {
        Text(text)
      }
    }
    .toolbarButtonSize()
  }
}

struct ToolbarButton_Previews: PreviewProvider {
  static var previews: some View {
    TPPPDFToolbarButton(text: "Hello") {
      //
    }
  }
}
