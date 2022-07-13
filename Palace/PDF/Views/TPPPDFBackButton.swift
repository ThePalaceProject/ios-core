//
//  TPPPDFBackButton.swift
//  Palace
//
//  Created by Vladimir Fedorov on 04.07.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// Preconfigured back button view
struct TPPPDFBackButton: View {
  
  let action: () -> Void
  
  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.left")
        .font(.system(size: 20, weight: .medium))
    }
    .toolbarButtonSize()
  }
}

struct TPPPDFBackButton_Previews: PreviewProvider {
  static var previews: some View {
    TPPPDFBackButton {
      
    }
  }
}
